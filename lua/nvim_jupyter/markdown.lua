-- lua/nvim_jupyter/markdown.lua
--
-- Region scoped markdown highlighting for notebook markdown cells.
--
-- A notebook is edited as a single `filetype=python` buffer, so the python
-- parser also sees the raw markdown source. Depending on the cell it either
-- gives up (error recovery, so the text only shows up in a comment-ish colour)
-- or, as soon as the cell contains a ```python fence, locks onto that block and
-- highlights the rest of the cell as python code.
--
-- The buffer is therefore split between the two languages using region scoped
-- language trees:
--
--   * the python root tree is restricted to everything that is *not* a markdown
--     cell body, so it stops producing captures there.
--   * a markdown tree is attached as a child of the python tree and restricted
--     to the markdown cell bodies. Children are highlighted after their parent,
--     so their captures win wherever ranges overlap.
--   * ```python fences inside a markdown cell are handed to python by the
--     markdown injection query, which spawns a python grandchild tree.

local M = {}

local config = require("nvim_jupyter.config")

-- State per buffer: the parser and markdown tree we configured last, plus the
-- regions currently handed to them. Keyed weakly so recreated parsers do not
-- pile up.
local configured = setmetatable({}, { __mode = "k" })

local function line_len(lines, row)
    return #(lines[row + 1] or "")
end

--- A range must end *after* the newline of its last line. Otherwise tree-sitter
--- stitches two consecutive included ranges into a single virtual line, and a
--- trailing comment swallows the following (markdown) cells into one node.
---@param lines string[]
---@param first integer 0-indexed, inclusive
---@param last integer 0-indexed, inclusive
---@return table range
local function row_range(lines, first, last)
    local last_row = #lines - 1
    if last < last_row then
        return { first, 0, last + 1, 0 }
    end
    return { first, 0, last, line_len(lines, last) }
end

--- Compute the included regions for both languages.
---
--- Each markdown cell body is its own region so an unterminated construct (for
--- example a fence the user is still typing) cannot leak into the next cell.
--- The python side keeps the previous whole-buffer parse context with the
--- markdown bodies simply carved out of it.
---
---@param cells table[] Cells from ui.parse_cells()
---@param lines string[]
---@return table md_regions
---@return table py_regions
local function compute_regions(cells, lines)
    local last_row = #lines - 1
    local md_regions = {}
    local py_ranges = {}
    local cursor = 0

    for _, cell in ipairs(cells) do
        if cell.is_markdown then
            -- The `# %% [markdown]` header line stays python: it keeps its
            -- comment highlighting and is overlaid by the cell border anyway.
            local first, last = cell.start_line + 1, cell.end_line
            if first <= last then
                table.insert(md_regions, { row_range(lines, first, last) })
            end
            if first - 1 >= cursor then
                table.insert(py_ranges, row_range(lines, cursor, first - 1))
            end
            if last + 1 > cursor then
                cursor = last + 1
            end
        end
    end

    if cursor <= last_row then
        table.insert(py_ranges, row_range(lines, cursor, last_row))
    end

    -- One region holding every non-markdown range: the python code is still
    -- parsed in a single context, exactly as it was before.
    return md_regions, { py_ranges }
end

--- Keep the manually attached markdown child alive.
---
--- `LanguageTree:_add_injections()` removes every child that was not produced
--- by an injection query. Markdown cells cannot be expressed as an injection
--- (python cannot say "inject into the lines *after* this comment"), so the
--- child has to be declared as one on every parse. Feeding our regions through
--- that path also lets nvim manage the child regions for us.
---@param parser vim.treesitter.LanguageTree
local function keep_markdown_child(parser)
    local ctx = configured[parser]
    if ctx and ctx.wrapped then return end

    ctx = ctx or { regions = {} }
    ctx.wrapped = true
    ctx.original_add_injections = parser._add_injections
    configured[parser] = ctx

    parser._add_injections = function(self, injections_by_lang)
        injections_by_lang.markdown = ctx.regions
        return ctx.original_add_injections(self, injections_by_lang)
    end
end

--- Stop keeping the manually attached markdown child alive.
---@param parser vim.treesitter.LanguageTree
local function release_markdown_child(parser)
    local ctx = configured[parser]
    if not ctx or not ctx.wrapped then return end
    parser._add_injections = ctx.original_add_injections
    ctx.wrapped = false
    ctx.original_add_injections = nil
    ctx.regions = {}
end

--- Sync the language tree regions with the current cell layout.
---
--- Called from `ui.render_cells()` on every buffer change, so this runs a lot;
--- `set_included_regions()` is a no-op when the regions did not move.
---@param bufnr integer
---@param cells table[] Cells from ui.parse_cells()
function M.update(bufnr, cells)
    if not config.options.markdown_highlighting then return end
    if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.b[bufnr].is_jupyter then return end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local md_regions, py_regions = compute_regions(cells, lines)

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
    if not ok or not parser then return end

    local ctx = configured[parser]
    local had_markdown = ctx and ctx.md_tree
    if #md_regions == 0 and not had_markdown then
        -- No markdown cells: leave the buffer untouched.
        return
    end

    if #md_regions == 0 then
        -- All markdown cells were deleted: drop the child and hand the whole
        -- buffer back to python.
        release_markdown_child(parser)
        pcall(parser.remove_child, parser, "markdown")
        parser:set_included_regions(py_regions)
        configured[parser] = nil
        return
    end

    local md_tree = parser:children()["markdown"]
    if not md_tree then
        local created, child = pcall(parser.add_child, parser, "markdown")
        if not created or not child then
            -- markdown parser not installed; leave python highlighting alone.
            return
        end
        md_tree = child
    end

    ctx = configured[parser] or { regions = {} }
    ctx.md_tree = md_tree
    ctx.regions = md_regions
    configured[parser] = ctx
    keep_markdown_child(parser)

    md_tree:set_included_regions(md_regions)
    parser:set_included_regions(py_regions)
end

function M.setup()
    local group = vim.api.nvim_create_augroup("NvimJupyterMarkdown", { clear = true })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(args)
            for parser in pairs(configured) do
                if parser:source() == args.buf then
                    configured[parser] = nil
                end
            end
        end,
    })
end

return M
