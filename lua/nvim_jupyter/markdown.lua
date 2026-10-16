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

-- Safeguard for Neovim 0.12+ tree-sitter queries where match captures can be
-- passed as a table { TSNode } rather than a bare TSNode, which breaks query
-- directives like set-lang-from-info-string!.
if vim.treesitter and vim.treesitter.get_node_text then
    local orig_get_node_text = vim.treesitter.get_node_text
    vim.treesitter.get_node_text = function(node, source, opts)
        if type(node) == "table" and not node.range then
            node = node[1]
        end
        if not node then return "" end
        return orig_get_node_text(node, source, opts)
    end
end

-- State per buffer: the parser and markdown tree we configured last, plus the
-- regions currently handed to them. Keyed weakly so recreated parsers do not
-- pile up.
local configured = setmetatable({}, { __mode = "k" })

local function range_coordinates(range)
    if #range >= 6 then
        -- Range6 is {start_row, start_col, start_byte, end_row, end_col,
        -- end_byte}; the byte offsets are not part of the logical region.
        return range[1], range[2], range[4], range[5]
    end
    return range[1], range[2], range[3], range[4]
end

local function same_regions(left, right)
    if not left or #left ~= #right then
        return false
    end

    for index, left_region in ipairs(left) do
        local right_region = right[index]
        if not right_region or #left_region ~= #right_region then
            return false
        end
        for range_index, left_range in ipairs(left_region) do
            local right_range = right_region[range_index]
            if not right_range then
                return false
            end
            local left_start_row, left_start_col, left_end_row, left_end_col = range_coordinates(left_range)
            local right_start_row, right_start_col, right_end_row, right_end_col = range_coordinates(right_range)
            if left_start_row ~= right_start_row
                or left_start_col ~= right_start_col
                or left_end_row ~= right_end_row
                or left_end_col ~= right_end_col then
                return false
            end
        end
    end

    return true
end

local function position_leq(left_row, left_col, right_row, right_col)
    return left_row < right_row or (left_row == right_row and left_col <= right_col)
end

local function range_bounds(range)
    return range_coordinates(range)
end

local function range_inside(outer, inner)
    local outer_start_row, outer_start_col, outer_end_row, outer_end_col = range_bounds(outer)
    local inner_start_row, inner_start_col, inner_end_row, inner_end_col = range_bounds(inner)

    return position_leq(outer_start_row, outer_start_col, inner_start_row, inner_start_col)
        and position_leq(inner_end_row, inner_end_col, outer_end_row, outer_end_col)
end

local function injection_inside_cell(injection_region, cell_regions)
    for _, injection_range in ipairs(injection_region) do
        local contained = false
        for _, cell_region in ipairs(cell_regions) do
            for _, cell_range in ipairs(cell_region) do
                if range_inside(cell_range, injection_range) then
                    contained = true
                    break
                end
            end
            if contained then break end
        end
        if not contained then
            return false
        end
    end
    return true
end

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

local function markdown_fences_balanced(lines, first, last)
    local fence_open = false

    for row = first, last do
        local line = lines[row + 1] or ""
        local marker_count = 0
        if line:match("^%s*\x60\x60\x60+") then
            for _ in line:gmatch("\x60\x60\x60+") do
                marker_count = marker_count + 1
            end
        elseif line:match("^%s*~~~+") then
            for _ in line:gmatch("~~~+") do
                marker_count = marker_count + 1
            end
        end

        if marker_count % 2 == 1 then
            fence_open = not fence_open
        end
    end

    return not fence_open
end

--- Compute the included regions for both languages.
---
--- One region per cell, for both languages: cells are independent documents in
--- a notebook, so a construct left open in one of them cannot leak into the
--- next one (or into the markdown cells in between).
---
--- The `# %%` header line is a notebook marker rather than cell content, so it
--- is left out of both trees (it is overlaid by the cell border anyway).
---
---@param cells table[] Cells from ui.parse_cells()
---@param lines string[]
---@return table md_regions
---@return table py_regions
local function compute_regions(cells, lines)
    local md_regions = {}
    local py_regions = {}

    for _, cell in ipairs(cells) do
        local first = cell.implicit and cell.start_line or (cell.start_line + 1)
        local last = cell.end_line
        local safe_markdown = not cell.is_markdown
            or markdown_fences_balanced(lines, first, last)
        -- Never give an unfinished markdown fence to Tree-sitter. Its
        -- injected language can otherwise consume the next notebook cell
        -- while the document is being edited.
        if first <= last and safe_markdown then
            local region = { row_range(lines, first, last) }
            if cell.is_markdown then
                table.insert(md_regions, region)
            else
                table.insert(py_regions, region)
            end
        end
    end

    return md_regions, py_regions
end

local function keep_cell_scoped_injections(parser, md_tree)
    local ctx = configured[parser]
    if not ctx or ctx.injections_wrapped then return end

    ctx.injections_wrapped = true
    ctx.original_markdown_add_injections = md_tree._add_injections
    md_tree._add_injections = function(self, injections_by_lang)
        local cell_regions = self:included_regions()
        local filtered = {}

        for language, injection_regions in pairs(injections_by_lang) do
            filtered[language] = {}
            for _, injection_region in ipairs(injection_regions) do
                if injection_inside_cell(injection_region, cell_regions) then
                    table.insert(filtered[language], injection_region)
                end
            end
        end

        return ctx.original_markdown_add_injections(self, filtered)
    end
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
    if not config.options.markdown_highlighting then return false end
    if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.b[bufnr].is_jupyter then return false end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local md_regions, py_regions = compute_regions(cells, lines)

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
    if not ok or not parser then return false end

    local ctx = configured[parser]
    local had_markdown = ctx and ctx.md_tree
    if #md_regions == 0 and not had_markdown then
        -- No markdown cells: leave the buffer untouched.
        return false
    end

    if #md_regions == 0 then
        -- All markdown cells were deleted: drop the child and hand the whole
        -- buffer back to python.
        release_markdown_child(parser)
        pcall(parser.remove_child, parser, "markdown")
        parser:set_included_regions(py_regions)
        configured[parser] = nil
        pcall(parser.parse, parser, true)
        return true
    end

    local markdown_regions_changed = not (ctx and same_regions(ctx.regions, md_regions))
    local python_regions_changed = not same_regions(parser:included_regions(), py_regions)
    local regions_changed = markdown_regions_changed or python_regions_changed

    local hl = vim.treesitter.highlighter.active[bufnr]
    if hl then
        -- Neovim's built-in TSHighlighter only sets _conceal_line from root tree
        -- language ("python"), which lacks conceal_lines queries. Enable it so
        -- on_bytes dynamically invalidates conceal marks on buffer edits instead
        -- of leaving inverted/stale extmarks that conceal newly typed code.
        hl._conceal_line = true
    end

    -- Recreate the markdown child after a structural edit. Updating a child
    -- in place can leave its old injected Python tree alive for one parser
    -- pass, which is enough to decorate the following code-cell header.
    if regions_changed and ctx and ctx.md_tree then
        release_markdown_child(parser)
        pcall(parser.remove_child, parser, "markdown")
        configured[parser] = nil
        ctx = nil
    end

    if regions_changed then
        local hl_ns = vim.api.nvim_create_namespace("nvim.treesitter.highlighter")
        vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
        if hl then
            hl._conceal_checked = {}
        end
    end

    local md_tree = parser:children()["markdown"]
    if not md_tree then
        local created, child = pcall(parser.add_child, parser, "markdown")
        if not created or not child then
            -- markdown parser not installed; leave python highlighting alone.
            return false
        end
        md_tree = child
    end

    ctx = configured[parser] or { regions = {} }
    ctx.md_tree = md_tree
    ctx.regions = md_regions
    configured[parser] = ctx
    keep_markdown_child(parser)
    keep_cell_scoped_injections(parser, md_tree)

    md_tree:set_included_regions(md_regions)
    parser:set_included_regions(py_regions)

    if regions_changed then
        -- Force the old injection tree out before the UI paints its new
        -- borders. The normal parser callback may still run later, but it
        -- can no longer use the deleted cell's range.
        pcall(parser.parse, parser, true)
    end

    return regions_changed
end

--- Preview in Global Mode, source in Local Mode.
---
--- Global Mode keeps the markdown preview look (concealed fences, inline code
--- backticks, link targets). Local Mode sets conceallevel=0 for the window so
--- the complete cell can be edited immediately in both Normal and Insert mode.

--- Sync conceal settings for the notebook buffer.
--- In Global Mode: conceallevel = 2 and concealcursor = "nvic" (pure preview look).
--- In Local Mode: conceallevel = 0 and concealcursor = "".
---@param bufnr integer
---@param _active_cell table|nil Cell under the cursor, from ui.parse_cells()
function M.sync_conceal(bufnr, _active_cell)
    local local_mode = vim.b[bufnr].jupyter_state == "local"
    local conceallevel = local_mode and 0 or 2
    local concealcursor = local_mode and "" or "nvic"

    if not local_mode then
        -- Clear stale treesitter highlighter conceal marks so they are cleanly
        -- regenerated at correct rows when entering Global Mode preview.
        local hl_ns = vim.api.nvim_create_namespace("nvim.treesitter.highlighter")
        vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
        local hl = vim.treesitter.highlighter.active[bufnr]
        if hl then
            hl._conceal_checked = {}
            hl._conceal_line = true
        end
    end

    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_get_option_value("conceallevel", { win = win }) ~= conceallevel then
            vim.api.nvim_set_option_value("conceallevel", conceallevel, { win = win })
        end
        if vim.api.nvim_get_option_value("concealcursor", { win = win }) ~= concealcursor then
            vim.api.nvim_set_option_value("concealcursor", concealcursor, { win = win })
        end
    end
    vim.cmd("redraw!")
end

function M.setup()
    -- Compatibility with nvim-treesitter directive on Neovim 0.12+ where
    -- match captures can be passed as tables of nodes rather than single nodes.
    local ok_query, query = pcall(require, "vim.treesitter.query")
    if ok_query and query.add_directive then
        query.add_directive("set-lang-from-info-string!", function(match, _, bufnr, pred, metadata)
            local capture_id = pred[2]
            local node = match[capture_id]
            if type(node) == "table" and not node.range then
                node = node[1]
            end
            if not node then return end
            local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
            if ok_text and text then
                metadata["injection.language"] = text:lower()
            end
        end, { force = true, all = true })
    end

    local group = vim.api.nvim_create_augroup("NvimJupyterMarkdown", { clear = true })
    vim.api.nvim_create_autocmd({"BufEnter", "FileType"}, {
        group = group,
        pattern = "*",
        callback = function(args)
            if vim.b[args.buf] and vim.b[args.buf].is_jupyter then
                local hl = vim.treesitter.highlighter.active[args.buf]
                if hl then
                    hl._conceal_line = true
                end
            end
        end,
    })
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
