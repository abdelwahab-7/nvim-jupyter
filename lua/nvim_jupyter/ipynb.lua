local M = {}
local utils = require("nvim_jupyter.utils")

-- Store the original notebook metadata and structure per buffer
local notebook_state = {}

function M.read_ipynb(file_path, bufnr)
    local nb = {}
    local f = io.open(file_path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        
        local ok, decoded = pcall(vim.json.decode, content)
        if not ok or type(decoded) ~= "table" then
            vim.notify("Invalid ipynb format in " .. file_path, vim.log.levels.ERROR)
            return
        end
        nb = decoded
    end
    
    notebook_state[bufnr] = {
        metadata = nb.metadata or {},
        nbformat = nb.nbformat or 4,
        nbformat_minor = nb.nbformat_minor or 5,
        original_cells = nb.cells or {}
    }
    
    local lines = {}
    local hidden_outputs_to_set = {}
    
    for i, cell in ipairs(nb.cells or {}) do
        local start_line = #lines
        
        local cell_type = cell.cell_type or "code"
        if cell_type == "markdown" then
            table.insert(lines, "# %% [markdown]")
        else
            table.insert(lines, "# %%")
        end
        
        local source = type(cell.source) == "table" and table.concat(cell.source, "") or (cell.source or "")
        local source_lines = vim.split(source, "\n")
        
        for _, line in ipairs(source_lines) do
            -- Avoid appending an extra empty line if the source ended with a newline
            -- string split leaves a trailing empty string
            table.insert(lines, line)
        end
        
        -- Remove trailing empty line caused by vim.split on strings ending in \n
        if lines[#lines] == "" then
            table.remove(lines)
        end
        
        -- Load outputs as physical lines
        local is_hidden = false
        if cell.metadata and (cell.metadata.collapsed or (cell.metadata.jupyter and cell.metadata.jupyter.outputs_hidden)) then
            is_hidden = true
        end
        
        if cell.outputs and #cell.outputs > 0 then
            local out_lines = {"# %% [output]"}
            for _, output in ipairs(cell.outputs) do
                if output.text then
                    local text = type(output.text) == "table" and table.concat(output.text, "") or output.text
                    text = utils.clean_output_text(text)
                    local text_lines = vim.split(text, "\n")
                    if #text_lines > 0 and text_lines[#text_lines] == "" then table.remove(text_lines) end
                    for _, line in ipairs(text_lines) do
                        table.insert(out_lines, line)
                    end
                elseif output.data and output.data["text/plain"] then
                    local text = type(output.data["text/plain"]) == "table" and table.concat(output.data["text/plain"], "") or output.data["text/plain"]
                    text = utils.clean_output_text(text)
                    local text_lines = vim.split(text, "\n")
                    if #text_lines > 0 and text_lines[#text_lines] == "" then table.remove(text_lines) end
                    for _, line in ipairs(text_lines) do
                        table.insert(out_lines, line)
                    end
                end
            end
            
            if is_hidden then
                table.insert(hidden_outputs_to_set, {
                    code_start_line = start_line,
                    out_lines = out_lines
                })
            else
                for _, line in ipairs(out_lines) do
                    table.insert(lines, line)
                end
            end
        end
    end
    
    if #lines == 0 then
        lines = {"# %%", ""}
    end
    
    local old_ul = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    
    vim.bo[bufnr].undolevels = old_ul
    -- Create extmarks for hidden outputs
    if #hidden_outputs_to_set > 0 then
        local hidden_ns = vim.api.nvim_create_namespace("jupyter_hidden")
        if not vim.b[bufnr].hidden_outputs then vim.b[bufnr].hidden_outputs = {} end
        local ho = vim.b[bufnr].hidden_outputs
        
        for _, hidden in ipairs(hidden_outputs_to_set) do
            local id = vim.api.nvim_buf_set_extmark(bufnr, hidden_ns, hidden.code_start_line, 0, {})
            ho[id] = hidden.out_lines
        end
        vim.b[bufnr].hidden_outputs = ho
    end
    
    vim.b[bufnr].is_jupyter = true
    vim.b[bufnr].jupyter_state = "global"
    vim.api.nvim_buf_set_option(bufnr, "filetype", "python")
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
    
    -- Initialize starting snapshot for all cells
    require("nvim_jupyter.local_undo").snapshot_all_cells(bufnr)
end

function M.write_ipynb(file_path, bufnr)
    local state = notebook_state[bufnr] or {
        metadata = {},
        nbformat = 4,
        nbformat_minor = 5,
        original_cells = {}
    }
    
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cells = {}
    
    local current_cell = nil
    local collecting_output = false
    
    for i, line in ipairs(lines) do
        local lnum = i - 1
        if line:match("^# %%%%") then
            if line:match("^# %%%% %[output%]") then
                collecting_output = true
                if current_cell and not current_cell.outputs then
                    current_cell.outputs = {}
                end
            else
                -- Start of a new code/markdown cell
                if current_cell then
                    table.insert(cells, current_cell)
                end
                
                collecting_output = false
                local is_markdown = line:match("%[markdown%]") ~= nil
                current_cell = {
                    cell_type = is_markdown and "markdown" or "code",
                    metadata = {},
                    source = {},
                    start_line = lnum
                }
                if not is_markdown then
                    current_cell.outputs = {}
                    current_cell.execution_count = vim.NIL
                end
            end
        else
            -- If we haven't hit a marker yet, treat the top of the file as a code cell
            if not current_cell then
                current_cell = {
                    cell_type = "code",
                    metadata = {},
                    source = {},
                    outputs = {},
                    execution_count = vim.NIL,
                    start_line = 0
                }
            end
            
            if collecting_output then
                if #current_cell.outputs == 0 then
                    table.insert(current_cell.outputs, {
                        output_type = "stream",
                        name = "stdout",
                        text = {}
                    })
                end
                table.insert(current_cell.outputs[1].text, line .. "\n")
            else
                table.insert(current_cell.source, line .. "\n")
            end
        end
    end
    
    if current_cell then
        current_cell.start_line = nil
        table.insert(cells, current_cell)
    end
    
    -- Cleanup trailing newlines in cell sources to exactly match jupyter's format
    for _, cell in ipairs(cells) do
        if #cell.source > 0 then
            local last_idx = #cell.source
            cell.source[last_idx] = cell.source[last_idx]:gsub("\n$", "")
        end
        
        if cell.cell_type == "code" and cell.start_line then
            local hidden_ns = vim.api.nvim_create_namespace("jupyter_hidden")
            local hidden_marks = vim.api.nvim_buf_get_extmarks(bufnr, hidden_ns, {cell.start_line, 0}, {cell.start_line, -1}, {})
            if #hidden_marks > 0 then
                -- Output is hidden
                if not cell.metadata then cell.metadata = {} end
                cell.metadata.collapsed = true
                if not cell.metadata.jupyter then cell.metadata.jupyter = {} end
                cell.metadata.jupyter.outputs_hidden = true
                
                local id = hidden_marks[1][1]
                local hidden = vim.b[bufnr].hidden_outputs and vim.b[bufnr].hidden_outputs[id]
                if hidden then
                    local out_lines = {}
                    for j, l in ipairs(hidden) do
                        if j > 1 then table.insert(out_lines, l .. "\n") end
                    end
                    if #out_lines > 0 then
                        out_lines[#out_lines] = out_lines[#out_lines]:gsub("\n$", "")
                    end
                    table.insert(cell.outputs, {
                        output_type = "stream",
                        name = "stdout",
                        text = out_lines
                    })
                end
            else
                -- Output is not hidden
                if cell.metadata then
                    cell.metadata.collapsed = false
                    if cell.metadata.jupyter then
                        cell.metadata.jupyter.outputs_hidden = false
                    end
                end
            end
            cell.start_line = nil
        end
    end
    
    local nb = {
        cells = cells,
        metadata = state.metadata,
        nbformat = state.nbformat,
        nbformat_minor = state.nbformat_minor
    }
    
    local ok, json_str = pcall(vim.json.encode, nb)
    if not ok then
        error("Nvim-Jupyter: Failed to encode notebook to JSON! File not saved.")
    end
    
    local f = io.open(file_path, "w")
    if not f then
        error("Nvim-Jupyter: Could not open file for writing: " .. file_path)
    end
    f:write(json_str)
    f:close()
    
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
    vim.notify("Notebook saved: " .. file_path, vim.log.levels.INFO)
end

function M.setup()
    local group = vim.api.nvim_create_augroup("NvimJupyterIPYNB", { clear = true })
    
    vim.api.nvim_create_autocmd("BufReadCmd", {
        group = group,
        pattern = "*.ipynb",
        callback = function(args)
            M.read_ipynb(args.file, args.buf)
        end
    })
    
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        pattern = "*.ipynb",
        callback = function(args)
            M.write_ipynb(args.file, args.buf)
        end
    })
end

return M
