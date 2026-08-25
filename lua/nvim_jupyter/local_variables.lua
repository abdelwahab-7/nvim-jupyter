local M = {}

local sidebar_win = nil
local sidebar_buf = nil
M.cell_local_vars = {} -- keyed by track_id

local ns_id = vim.api.nvim_create_namespace("jupyter_local_variables")
local group = vim.api.nvim_create_augroup("JupyterLocalVars", { clear = true })

vim.cmd([[
    highlight JupyterLocalVarBorder guifg=#F38BA8
    highlight JupyterLocalVarName guifg=#F38BA8 gui=bold
    highlight JupyterLocalVarType guifg=#F9E2AF
    highlight JupyterLocalVarDetails guifg=#A6E3A1
    highlight JupyterLocalVarActive guibg=#45475a guifg=#cdd6f4 gui=bold
]])

function M.toggle_sidebar()
    if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
        vim.api.nvim_win_close(sidebar_win, true)
        sidebar_win = nil
        pcall(vim.api.nvim_clear_autocmds, { group = group })
        local current_win = vim.api.nvim_get_current_win()
        local main_buf = vim.api.nvim_win_get_buf(current_win)
        require("nvim_jupyter.ui").render_cells(main_buf)
        return
    end

    local current_win = vim.api.nvim_get_current_win()
    local main_buf = vim.api.nvim_win_get_buf(current_win)

    -- Create vertical split on the far right
    vim.cmd("botright vsplit")
    sidebar_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(sidebar_win, 45)
    
    if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then
        sidebar_buf = vim.api.nvim_create_buf(false, true) -- nofile, scratch
        vim.api.nvim_buf_set_name(sidebar_buf, "Jupyter Local Variables")
    end
    
    vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
    
    -- Buffer options
    vim.bo[sidebar_buf].buftype = "nofile"
    vim.bo[sidebar_buf].bufhidden = "hide"
    vim.bo[sidebar_buf].swapfile = false
    vim.bo[sidebar_buf].modifiable = false
    vim.wo[sidebar_win].wrap = false
    vim.wo[sidebar_win].number = false
    vim.wo[sidebar_win].relativenumber = false
    vim.wo[sidebar_win].signcolumn = "no"
    
    -- Setup autocmd to refresh the sidebar as the user moves cursor
    vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI", "BufEnter"}, {
        group = group,
        pattern = "*",
        callback = function(args)
            -- Only trigger if the buffer is a jupyter buffer
            if not vim.b[args.buf].is_jupyter then return end
            M.render()
        end
    })
    
    M.render()
    
    vim.api.nvim_set_current_win(current_win)
    require("nvim_jupyter.ui").render_cells(main_buf)
end

function M.update(track_id, vars)
    M.cell_local_vars[track_id] = vars or {}
    vim.schedule(function()
        M.render()
    end)
end

function M.render()
    if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then return end
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end

    -- Find the active cell's track_id
    local main_buf = -1
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.b[b].is_jupyter and vim.api.nvim_get_current_win() == w then
            main_buf = b
            break
        end
    end
    
    local current_vars = {}
    if main_buf ~= -1 then
        local core = require("nvim_jupyter.core")
        local _, start_line, _ = core.get_current_cell_bounds(main_buf)
        if start_line then
            local marks = vim.api.nvim_buf_get_extmarks(main_buf, core.track_ns, {start_line, 0}, {start_line, -1}, {})
            if marks and #marks > 0 then
                local track_id = marks[1][1]
                current_vars = M.cell_local_vars[track_id] or {}
            end
        end
    end

    local lines = {}
    local highlights = {} -- list of {line, col_start, col_end, hl_group}
    
    local max_name = 10
    local max_type = 11
    local max_details = 12
    
    for _, v in ipairs(current_vars) do
        local name = v.name or ""
        local vtype = v.type or ""
        local details = v.details or ""
        if #name > max_name then max_name = #name end
        if #vtype > max_type then max_type = #vtype end
        if #details > max_details then max_details = #details end
    end
    
    local total_w = max_name + max_type + max_details + 8
    
    local title = "Local Cell Variables"
    local title_pad = total_w - #title
    if title_pad < 0 then title_pad = 0 end
    
    table.insert(lines, "╭" .. string.rep("─", total_w) .. "╮")
    table.insert(lines, "│ " .. title .. string.rep(" ", title_pad - 1) .. " │")
    table.insert(lines, "├" .. string.rep("─", max_name + 2) .. "┬" .. string.rep("─", max_type + 2) .. "┬" .. string.rep("─", max_details + 2) .. "┤")
    
    local header = string.format("│ %-"..max_name.."s │ %-"..max_type.."s │ %-"..max_details.."s │", "Name", "Type", "Details")
    table.insert(lines, header)
    table.insert(lines, "├" .. string.rep("─", max_name + 2) .. "┼" .. string.rep("─", max_type + 2) .. "┼" .. string.rep("─", max_details + 2) .. "┤")
    
    local current_word = vim.fn.expand("<cword>")
    
    for i, v in ipairs(current_vars) do
        local name = v.name or ""
        local vtype = v.type or ""
        local details = v.details or ""
        
        local line = string.format("│ %-"..max_name.."s │ %-"..max_type.."s │ %-"..max_details.."s │", name, vtype, details)
        table.insert(lines, line)
        
        local line_idx = #lines - 1
        
        -- Highlight active row if cursor is on this variable
        if v.name == current_word then
            -- highlight entire row
            table.insert(highlights, {line_idx, 3, total_w + 3, "JupyterLocalVarActive"})
        end
        
        -- Name hl (Pipe=3, Space=1 -> 4)
        table.insert(highlights, {line_idx, 4, 4 + max_name, "JupyterLocalVarName"})
        -- Type hl (4 + max_name + 1 + 3 + 1 = max_name + 9)
        local type_start = max_name + 9
        table.insert(highlights, {line_idx, type_start, type_start + max_type, "JupyterLocalVarType"})
        -- Details hl (type_start + max_type + 1 + 3 + 1 = type_start + max_type + 5)
        local details_start = type_start + max_type + 5
        table.insert(highlights, {line_idx, details_start, details_start + max_details, "JupyterLocalVarDetails"})
    end
    
    if #current_vars == 0 then
        local msg = "(No local variables)"
        local msg_pad = total_w - #msg
        if msg_pad < 0 then msg_pad = 0 end
        table.insert(lines, "│ " .. msg .. string.rep(" ", msg_pad - 1) .. " │")
    end
    
    table.insert(lines, "╰" .. string.rep("─", max_name + 2) .. "┴" .. string.rep("─", max_type + 2) .. "┴" .. string.rep("─", max_details + 2) .. "╯")
    
    vim.bo[sidebar_buf].modifiable = true
    vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
    vim.bo[sidebar_buf].modifiable = false
    
    vim.api.nvim_buf_clear_namespace(sidebar_buf, ns_id, 0, -1)
    
    if vim.api.nvim_win_is_valid(sidebar_win) then
        local target_width = math.max(45, total_w + 2)
        vim.api.nvim_win_set_width(sidebar_win, target_width)
    end
    
    -- Highlight borders
    for i=0, #lines-1 do
        vim.api.nvim_buf_add_highlight(sidebar_buf, ns_id, "JupyterLocalVarBorder", i, 0, -1)
    end
    
    -- Apply item highlights
    for _, h in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(sidebar_buf, ns_id, h[4], h[1], h[2], h[3])
    end
end

return M

