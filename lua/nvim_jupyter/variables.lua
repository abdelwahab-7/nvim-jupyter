local M = {}

local sidebar_win = nil
local sidebar_buf = nil
local current_vars = {}

local ns_id = vim.api.nvim_create_namespace("jupyter_variables")

vim.cmd([[
    highlight JupyterVarBorder guifg=#89B4FA
    highlight JupyterVarName guifg=#89B4FA gui=bold
    highlight JupyterVarType guifg=#F9E2AF
    highlight JupyterVarDetails guifg=#A6E3A1
]])

function M.toggle_sidebar()
    if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
        vim.api.nvim_win_close(sidebar_win, true)
        sidebar_win = nil
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
        vim.api.nvim_buf_set_name(sidebar_buf, "Jupyter Variable Explorer")
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
    
    M.render()
    
    vim.api.nvim_set_current_win(current_win)
    require("nvim_jupyter.ui").render_cells(main_buf)
end

function M.update(vars)
    current_vars = vars or {}
    vim.schedule(function()
        M.render()
    end)
end

function M.render()
    if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then return end
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end

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
    
    local title = "Variable Explorer"
    local title_pad = total_w - #title
    if title_pad < 0 then title_pad = 0 end
    
    table.insert(lines, "╭" .. string.rep("─", total_w) .. "╮")
    table.insert(lines, "│ " .. title .. string.rep(" ", title_pad - 1) .. " │")
    table.insert(lines, "├" .. string.rep("─", max_name + 2) .. "┬" .. string.rep("─", max_type + 2) .. "┬" .. string.rep("─", max_details + 2) .. "┤")
    
    local header = string.format("│ %-"..max_name.."s │ %-"..max_type.."s │ %-"..max_details.."s │", "Name", "Type", "Details")
    table.insert(lines, header)
    table.insert(lines, "├" .. string.rep("─", max_name + 2) .. "┼" .. string.rep("─", max_type + 2) .. "┼" .. string.rep("─", max_details + 2) .. "┤")
    
    for i, v in ipairs(current_vars) do
        local name = v.name or ""
        local vtype = v.type or ""
        local details = v.details or ""
        
        local line = string.format("│ %-"..max_name.."s │ %-"..max_type.."s │ %-"..max_details.."s │", name, vtype, details)
        table.insert(lines, line)
        
        local line_idx = #lines - 1
        -- Name hl (Pipe=3, Space=1 -> 4)
        table.insert(highlights, {line_idx, 4, 4 + max_name, "JupyterVarName"})
        -- Type hl (4 + max_name + 1 + 3 + 1 = max_name + 9)
        local type_start = max_name + 9
        table.insert(highlights, {line_idx, type_start, type_start + max_type, "JupyterVarType"})
        -- Details hl (type_start + max_type + 1 + 3 + 1 = type_start + max_type + 5)
        local details_start = type_start + max_type + 5
        table.insert(highlights, {line_idx, details_start, details_start + max_details, "JupyterVarDetails"})
    end
    
    if #current_vars == 0 then
        local msg = "(No active variables)"
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
        vim.api.nvim_buf_add_highlight(sidebar_buf, ns_id, "JupyterVarBorder", i, 0, -1)
    end
    
    -- Apply item highlights
    for _, h in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(sidebar_buf, ns_id, h[4], h[1], h[2], h[3])
    end
end

return M

