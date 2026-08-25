local M = {}
local floating = require("nvim_jupyter.floating")
local core = require("nvim_jupyter.core")

local cell_histories = {} -- Map of uuid -> { { timestamp = "", lines = {}, id = 1, preview = "", cell_type = "" } }
local tracking_ns = vim.api.nvim_create_namespace("jupyter_cell_tracker")

local sidebar_win = nil
local sidebar_buf = nil
local current_target_buf = nil
local current_uuid = nil

local ns_id = vim.api.nvim_create_namespace("jupyter_local_undo_ui")
local line_to_node = {}

vim.cmd([[
    highlight JupyterLocalUndoBorder     guifg=#89B4FA gui=bold
    highlight JupyterLocalUndoTitle      guifg=#FAB387 gui=bold
    highlight JupyterLocalUndoHelp       guifg=#9399B2 gui=italic
    highlight JupyterLocalUndoNodeHeader guifg=#F9E2AF gui=bold
    highlight JupyterLocalUndoCode       guifg=#CDD6F4 gui=NONE
]])

local function get_cell_uuid(buf, start_line)
    local marks = vim.api.nvim_buf_get_extmarks(buf, tracking_ns, {start_line, 0}, {start_line, 0}, {details = false})
    if marks and #marks > 0 then
        return marks[1][1]
    else
        local id = vim.api.nvim_buf_set_extmark(buf, tracking_ns, start_line, 0, {})
        cell_histories[id] = {}
        return id
    end
end

function M.snapshot_all_cells(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.b[bufnr].is_jupyter then return end
    
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local i = 0
    while i < total_lines do
        local line_text = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
        
        -- Found a cell
        if line_text and line_text:match("^# %%%%") or i == 0 then
            local start_line = (i == 0 and not (line_text and line_text:match("^# %%%%"))) and 0 or i
            
            -- Find end of this cell
            local cell_end = start_line
            while cell_end < total_lines - 1 do
                local next_line = vim.api.nvim_buf_get_lines(bufnr, cell_end + 1, cell_end + 2, false)[1]
                if next_line and next_line:match("^# %%%%") then
                    break
                end
                cell_end = cell_end + 1
            end
            if cell_end >= total_lines then cell_end = total_lines - 1 end
            
            local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, cell_end + 1, false)
            if #lines > 0 then
                local is_markdown = lines[1] and lines[1]:match("^# %%%% %[markdown%]") ~= nil
                local cell_type = is_markdown and "markdown" or "code"
                
                local uuid = get_cell_uuid(bufnr, start_line)
                local history = cell_histories[uuid]
                
                -- Only snapshot if history is empty (this is the initial load)
                if #history == 0 then
                    local preview = "(empty cell)"
                    for j = 2, #lines do
                        local l = lines[j]
                        if l and not l:match("^# %%%%") and l:gsub("%s+", "") ~= "" then
                            preview = l:gsub("^%s+", "")
                            break
                        end
                    end
                    if #preview > 26 then
                        preview = preview:sub(1, 23) .. "..."
                    end
                    
                    table.insert(history, {
                        id = 1,
                        timestamp = os.date("%H:%M:%S"),
                        lines = lines,
                        preview = preview,
                        cell_type = cell_type,
                    })
                end
            end
            
            -- Advance to the next cell
            i = cell_end
        end
        i = i + 1
    end
end

function M.snapshot_current_cell()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.b[buf].is_jupyter then return end
    if core.is_in_output_block() then return end
    
    local _, start_line, end_line = core.get_current_cell_bounds(buf)
    if start_line < 0 or start_line >= vim.api.nvim_buf_line_count(buf) then return end
    
    local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)
    if #lines == 0 then return end
    
    local is_markdown = lines[1] and lines[1]:match("^# %%%% %[markdown%]") ~= nil
    local cell_type = is_markdown and "markdown" or "code"
    
    local uuid = get_cell_uuid(buf, start_line)
    local history = cell_histories[uuid]
    
    -- Check if lines differ from last snapshot
    if #history > 0 then
        local last_snapshot = history[#history].lines
        if #lines == #last_snapshot then
            local same = true
            for i, line in ipairs(lines) do
                if line ~= last_snapshot[i] then
                    same = false
                    break
                end
            end
            if same then return end
        end
    end
    
    local preview = "(empty cell)"
    for i = 2, #lines do
        local l = lines[i]
        if l and not l:match("^# %%%%") and l:gsub("%s+", "") ~= "" then
            preview = l:gsub("^%s+", "")
            break
        end
    end
    if #preview > 26 then
        preview = preview:sub(1, 23) .. "..."
    end
    
    table.insert(history, {
        id = #history + 1,
        timestamp = os.date("%H:%M:%S"),
        lines = lines,
        preview = preview,
        cell_type = cell_type,
    })
    
    if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) and current_target_buf == buf and current_uuid == uuid then
        vim.schedule(function()
            M.render()
        end)
    end
end

local function get_node_under_cursor()
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return nil end
    local cursor = vim.api.nvim_win_get_cursor(sidebar_win)
    local line_idx = cursor[1] - 1
    
    for offset = 0, -3, -1 do
        local node_idx = line_to_node[line_idx + offset]
        if node_idx then
            local history = cell_histories[current_uuid]
            if history then return history[node_idx] end
        end
    end
    for offset = 1, 3 do
        local node_idx = line_to_node[line_idx + offset]
        if node_idx then
            local history = cell_histories[current_uuid]
            if history then return history[node_idx] end
        end
    end
    return nil
end

function M.preview_code()
    local node = get_node_under_cursor()
    if not node then
        vim.notify("No snapshot selected under cursor.", vim.log.levels.WARN)
        return
    end

    if floating.has_active_windows() then
        floating.close_all()
        return
    end

    local lines_to_show = {}
    for _, line in ipairs(node.lines) do
        if not line:match("^# %%%%") then
            table.insert(lines_to_show, line)
        end
    end

    local filetype = node.cell_type == "markdown" and "markdown" or "python"
    floating.show_output(lines_to_show, { title = " Snapshot Preview ", filetype = filetype })
end

function M.restore_cell()
    local node = get_node_under_cursor()
    if not node then
        vim.notify("No snapshot selected under cursor.", vim.log.levels.WARN)
        return
    end
    
    local target_buf = current_target_buf
    if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
        vim.notify("Target notebook buffer is invalid.", vim.log.levels.ERROR)
        return
    end
    
    -- Find where the cell is currently located using the extmark
    local marks = vim.api.nvim_buf_get_extmarks(target_buf, tracking_ns, {0, 0}, {-1, -1}, {details = false})
    local cell_start = nil
    for _, mark in ipairs(marks) do
        if mark[1] == current_uuid then
            cell_start = mark[2]
            break
        end
    end
    
    if not cell_start then
        vim.notify("Could not locate original cell to restore.", vim.log.levels.ERROR)
        return
    end
    
    -- Find the end of that cell
    local total_lines = vim.api.nvim_buf_line_count(target_buf)
    local cell_end = cell_start
    while cell_end < total_lines - 1 do
        local line_text = vim.api.nvim_buf_get_lines(target_buf, cell_end + 1, cell_end + 2, false)[1]
        if line_text and line_text:match("^# %%%%") then
            break
        end
        cell_end = cell_end + 1
    end
    if cell_end >= total_lines then cell_end = total_lines - 1 end
    
    vim.api.nvim_buf_set_lines(target_buf, cell_start, cell_end + 1, false, node.lines)
    
    -- Re-apply the extmark to the exact start line because replacing lines might shift or delete it
    pcall(vim.api.nvim_buf_set_extmark, target_buf, tracking_ns, cell_start, 0, { id = current_uuid })
    
    require("nvim_jupyter.ui").render_cells(target_buf)
    
    vim.notify("Restored cell to snapshot #" .. node.id, vim.log.levels.INFO)
end

function M.jump_node(dir)
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end
    local cursor = vim.api.nvim_win_get_cursor(sidebar_win)
    local cur_line = cursor[1] - 1
    
    local lines = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
    if dir > 0 then
        for l = cur_line + 1, #lines - 1 do
            if line_to_node[l] then
                vim.api.nvim_win_set_cursor(sidebar_win, {l + 1, 2})
                return
            end
        end
    else
        for l = cur_line - 1, 0, -1 do
            if line_to_node[l] then
                vim.api.nvim_win_set_cursor(sidebar_win, {l + 1, 2})
                return
            end
        end
    end
end

function M.toggle_sidebar()
    if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
        vim.api.nvim_win_close(sidebar_win, true)
        sidebar_win = nil
        pcall(function() require("nvim_jupyter.floating").close_all() end)
        return
    end
    
    local current_win = vim.api.nvim_get_current_win()
    current_target_buf = vim.api.nvim_win_get_buf(current_win)
    
    if not vim.b[current_target_buf].is_jupyter then
        vim.notify("Local Cell Undo Tree is only available in Jupyter Notebook buffers.", vim.log.levels.WARN)
        return
    end
    
    if core.is_in_output_block() then
        vim.notify("Cannot open Local Undo Tree for an output block.", vim.log.levels.WARN)
        return
    end
    
    local _, start_line, _ = core.get_current_cell_bounds(current_target_buf)
    current_uuid = get_cell_uuid(current_target_buf, start_line)
    
    -- Force snapshot of current cell if it hasn't been saved yet
    M.snapshot_current_cell()
    
    -- Open vertical split on far right for local tree
    vim.cmd("botright vsplit")
    sidebar_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(sidebar_win, 44)
    
    if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then
        sidebar_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(sidebar_buf, "Jupyter Local Cell Tree")
    end
    
    vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
    
    vim.bo[sidebar_buf].buftype = "nofile"
    vim.bo[sidebar_buf].bufhidden = "hide"
    vim.bo[sidebar_buf].swapfile = false
    vim.bo[sidebar_buf].modifiable = false
    vim.wo[sidebar_win].wrap = false
    vim.wo[sidebar_win].number = false
    vim.wo[sidebar_win].relativenumber = false
    vim.wo[sidebar_win].signcolumn = "no"
    
    local opts = { buffer = sidebar_buf, silent = true, noremap = true }
    vim.keymap.set('n', 'l', function() M.preview_code() end, opts)
    vim.keymap.set('n', 'r', function() M.restore_cell() end, opts)
    vim.keymap.set('n', 'j', function() M.jump_node(1) end, opts)
    vim.keymap.set('n', 'k', function() M.jump_node(-1) end, opts)
    vim.keymap.set('n', 'q', function() M.toggle_sidebar() end, opts)
    vim.keymap.set('n', '<Esc>', function() M.toggle_sidebar() end, opts)
    vim.keymap.set('n', '<leader>lu', function() M.toggle_sidebar() end, opts)
    
    M.render()
end

function M.render()
    if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then return end
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end
    
    line_to_node = {}
    local lines = {}
    local highlights = {}
    
    table.insert(lines, "╭──────────────────────────────────────────╮")
    table.insert(lines, "│ LOCAL CELL HISTORY                       │")
    table.insert(lines, "├──────────────────────────────────────────┤")
    table.insert(lines, "│  l    : View Snapshot Preview            │")
    table.insert(lines, "│  r    : Restore to Snapshot              │")
    table.insert(lines, "│  j/k  : Navigate Snapshots               │")
    table.insert(lines, "│  q/Esc: Close Sidebar                    │")
    table.insert(lines, "╰──────────────────────────────────────────╯")
    
    table.insert(highlights, {1, 2, 22, "JupyterLocalUndoTitle"})
    for i = 0, 8 do
        table.insert(highlights, {i, 0, -1, "JupyterLocalUndoBorder"})
    end
    for i = 3, 7 do
        table.insert(highlights, {i, 2, 40, "JupyterLocalUndoHelp"})
    end
    
    table.insert(lines, "")
    
    local history = cell_histories[current_uuid]
    
    if not history or #history == 0 then
        table.insert(lines, "  (No history recorded for this cell)")
        table.insert(highlights, {#lines - 1, 2, -1, "JupyterLocalUndoHelp"})
    else
        -- Render latest first (reverse order)
        for i = #history, 1, -1 do
            local state = history[i]
            
            local type_str = "[" .. (state.cell_type == "markdown" and "MD" or "Code") .. "]"
            local title_line = string.format(" Snapshot #%d %s %s", state.id, type_str, state.timestamp)
            
            local box_width = 38
            if #title_line > box_width then title_line = title_line:sub(1, box_width) end
            local pad_len = box_width - #title_line
            if pad_len < 0 then pad_len = 0 end
            title_line = title_line .. string.rep(" ", pad_len)
            
            local box_top    = "┌────────────────────────────────────────┐"
            local box_mid    = "│" .. title_line .. " │"
            local prev_line  = string.format("│ %-38s │", state.preview)
            local box_bottom = "└────────────────────────────────────────┘"
            
            table.insert(lines, box_top)
            local top_line_idx = #lines - 1
            line_to_node[top_line_idx] = i
            table.insert(highlights, {top_line_idx, 0, -1, "JupyterLocalUndoBorder"})
            
            table.insert(lines, box_mid)
            local mid_line_idx = #lines - 1
            table.insert(highlights, {mid_line_idx, 0, -1, "JupyterLocalUndoBorder"})
            table.insert(highlights, {mid_line_idx, 2, 14, "JupyterLocalUndoNodeHeader"})
            
            table.insert(lines, prev_line)
            local prev_line_idx = #lines - 1
            table.insert(highlights, {prev_line_idx, 0, -1, "JupyterLocalUndoBorder"})
            table.insert(highlights, {prev_line_idx, 2, -3, "JupyterLocalUndoCode"})
            
            table.insert(lines, box_bottom)
            local bot_line_idx = #lines - 1
            table.insert(highlights, {bot_line_idx, 0, -1, "JupyterLocalUndoBorder"})
            
            if i > 1 then
                table.insert(lines, "                   │")
                table.insert(highlights, {#lines - 1, 0, -1, "JupyterLocalUndoBorder"})
            end
        end
    end
    
    vim.bo[sidebar_buf].modifiable = true
    vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
    vim.bo[sidebar_buf].modifiable = false
    
    vim.api.nvim_buf_clear_namespace(sidebar_buf, ns_id, 0, -1)
    for _, h in ipairs(highlights) do
        pcall(function()
            vim.api.nvim_buf_add_highlight(sidebar_buf, ns_id, h[4], h[1], h[2], h[3])
        end)
    end
    
    if #lines > 10 and line_to_node[10] then
        pcall(function()
            vim.api.nvim_win_set_cursor(sidebar_win, {11, 2})
        end)
    end
end

function M.sync_with_cursor(buf)
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end
    if buf == sidebar_buf then return end -- Don't sync when navigating inside the sidebar
    if core.is_in_output_block() then return end
    
    local _, start_line, _ = core.get_current_cell_bounds(buf)
    if start_line < 0 or start_line >= vim.api.nvim_buf_line_count(buf) then return end
    
    local uuid = get_cell_uuid(buf, start_line)
    
    if uuid ~= current_uuid then
        current_target_buf = buf
        current_uuid = uuid
        M.render()
    end
end

function M.setup()
    vim.api.nvim_create_user_command("JupyterLocalUndoTree", function()
        M.toggle_sidebar()
    end, { desc = "Toggle Jupyter Local Cell Undo Tree sidebar" })
    
    local debounce_timer = nil
    vim.api.nvim_create_autocmd({"InsertLeave", "TextChanged"}, {
        callback = function(args)
            if vim.b[args.buf].is_jupyter then
                if debounce_timer then
                    debounce_timer:stop()
                    debounce_timer:close()
                end
                debounce_timer = vim.loop.new_timer()
                debounce_timer:start(500, 0, vim.schedule_wrap(function()
                    if vim.api.nvim_buf_is_valid(args.buf) then
                        M.snapshot_current_cell()
                    end
                end))
            end
        end
    })
    
    vim.api.nvim_create_autocmd("CursorMoved", {
        callback = function(args)
            if vim.b[args.buf].is_jupyter then
                M.sync_with_cursor(args.buf)
            end
        end
    })
end

return M

