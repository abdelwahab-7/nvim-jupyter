local M = {}
local floating = require("nvim_jupyter.floating")

-- Undo tree state per buffer
-- undo_trees[bufnr] = {
--   nodes = { [id] = node },
--   root_ids = { id1, id2, ... },
--   last_node_id = nil,
--   node_counter = 0,
-- }
local undo_trees = {}

local sidebar_win = nil
local sidebar_buf = nil
local current_target_buf = nil

-- Highlight namespace
local ns_id = vim.api.nvim_create_namespace("jupyter_undo_tree")

-- Line to node map for the sidebar buffer: line_to_node[line_idx] = node_id
local line_to_node = {}

-- Highlights setup
vim.cmd([[
    highlight JupyterUndoBorder     guifg=#89B4FA gui=bold
    highlight JupyterUndoTitle      guifg=#FAB387 gui=bold
    highlight JupyterUndoHelp       guifg=#9399B2 gui=italic
    highlight JupyterUndoNodeHeader guifg=#F9E2AF gui=bold
    highlight JupyterUndoSelected   guifg=#A6E3A1 gui=bold
    highlight JupyterUndoRestored   guifg=#6C7086 gui=strikethrough
    highlight JupyterUndoCode       guifg=#CDD6F4 gui=NONE
]])

-- Get or initialize tree data for a buffer
local function get_tree(bufnr)
    if not undo_trees[bufnr] then
        undo_trees[bufnr] = {
            nodes = {},
            root_ids = {},
            last_node_id = nil,
            node_counter = 0,
        }
    end
    return undo_trees[bufnr]
end

-- Push a deleted cell into the undo tree for bufnr
function M.push_deleted_cell(bufnr, lines, start_line)
    if not bufnr or not lines or #lines == 0 then return end
    
    local tree = get_tree(bufnr)
    tree.node_counter = tree.node_counter + 1
    local new_id = tree.node_counter
    
    local is_markdown = lines[1] and lines[1]:match("^# %%%% %[markdown%]") ~= nil
    local cell_type = is_markdown and "markdown" or "code"
    
    -- Extract first non-header code/text line for preview
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
    
    local node = {
        id = new_id,
        parent_id = tree.last_node_id,
        children = {},
        lines = lines,
        start_line = start_line or 0,
        cell_type = cell_type,
        preview = preview,
        timestamp = os.date("%H:%M:%S"),
        restored = false,
        selected = false,
        undo_seq = vim.fn.undotree().seq_cur,
    }
    
    tree.nodes[new_id] = node
    
    if tree.last_node_id and tree.nodes[tree.last_node_id] then
        table.insert(tree.nodes[tree.last_node_id].children, new_id)
    else
        table.insert(tree.root_ids, new_id)
    end
    
    tree.last_node_id = new_id
    
    -- If sidebar is open for this buffer, re-render
    if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) and current_target_buf == bufnr then
        vim.schedule(function()
            M.render()
        end)
    end
end

-- Get node under cursor in sidebar
local function get_node_under_cursor()
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return nil end
    local cursor = vim.api.nvim_win_get_cursor(sidebar_win)
    local line_idx = cursor[1] - 1
    
    -- Search nearby lines in map if cursor is inside box
    for offset = 0, -3, -1 do
        local node_id = line_to_node[line_idx + offset]
        if node_id then
            local tree = undo_trees[current_target_buf]
            if tree then return tree.nodes[node_id] end
        end
    end
    for offset = 1, 3 do
        local node_id = line_to_node[line_idx + offset]
        if node_id then
            local tree = undo_trees[current_target_buf]
            if tree then return tree.nodes[node_id] end
        end
    end
    return nil
end

-- Keymap handler: Preview code (l)
function M.preview_code()
    local node = get_node_under_cursor()
    if not node then
        vim.notify("No deleted cell selected under cursor.", vim.log.levels.WARN)
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
    floating.show_output(lines_to_show, { title = " Cell Preview ", filetype = filetype })
end

-- Remove a node from the tree completely
local function remove_node_from_tree(tree, node_id)
    local node = tree.nodes[node_id]
    if not node then return end
    
    local parent_id = node.parent_id
    local parent_children_list = nil
    
    if parent_id and tree.nodes[parent_id] then
        parent_children_list = tree.nodes[parent_id].children
    else
        parent_children_list = tree.root_ids
    end
    
    -- Find node in parent_children_list
    local idx = nil
    for i, id in ipairs(parent_children_list) do
        if id == node_id then
            idx = i
            break
        end
    end
    
    if idx then
        table.remove(parent_children_list, idx)
        -- Insert children at the same position
        for i = #node.children, 1, -1 do
            local child_id = node.children[i]
            table.insert(parent_children_list, idx, child_id)
            -- update parent_id of the child
            if tree.nodes[child_id] then
                tree.nodes[child_id].parent_id = parent_id
            end
        end
    end
    
    tree.nodes[node_id] = nil
    
    -- update last_node_id if needed
    if tree.last_node_id == node_id then
        tree.last_node_id = parent_id
    end
end

-- Keymap handler: Restore single cell (r)
function M.restore_cell()
    local node = get_node_under_cursor()
    if not node then
        vim.notify("No deleted cell selected under cursor.", vim.log.levels.WARN)
        return
    end
    
    if node.restored then
        vim.notify("Cell Node #" .. node.id .. " has already been restored.", vim.log.levels.INFO)
        return
    end
    
    local target_buf = current_target_buf
    if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
        vim.notify("Target notebook buffer is invalid.", vim.log.levels.ERROR)
        return
    end
    
    local total_lines = vim.api.nvim_buf_line_count(target_buf)
    local insert_at = math.min(node.start_line, total_lines)
    
    vim.api.nvim_buf_set_lines(target_buf, insert_at, insert_at, false, node.lines)
    local tree = undo_trees[target_buf]
    if tree then
        remove_node_from_tree(tree, node.id)
    end
    
    require("nvim_jupyter.ui").render_cells(target_buf)
    M.render()
    
    vim.notify("Restored cell Node #" .. node.id .. " at line " .. (insert_at + 1), vim.log.levels.INFO)
end

-- Keymap handler: Toggle selection checkbox (s)
function M.toggle_selection()
    local node = get_node_under_cursor()
    if not node then
        vim.notify("No deleted cell selected under cursor.", vim.log.levels.WARN)
        return
    end
    
    node.selected = not node.selected
    M.render()
end

-- Keymap handler: Apply restoration for all selected nodes (<CR> / Enter)
function M.apply_selection()
    local tree = undo_trees[current_target_buf]
    if not tree then return end
    
    local selected_nodes = {}
    for _, node in pairs(tree.nodes) do
        if node.selected and not node.restored then
            table.insert(selected_nodes, node)
        end
    end
    
    if #selected_nodes == 0 then
        vim.notify("No unrestored nodes selected. Press 's' on nodes to select them.", vim.log.levels.WARN)
        return
    end
    
    -- Sort by insertion position so inserting doesn't offset subsequent lines wrong
    table.sort(selected_nodes, function(a, b)
        return a.start_line < b.start_line
    end)
    
    local target_buf = current_target_buf
    local count = 0
    local offset = 0
    
    for _, node in ipairs(selected_nodes) do
        local total_lines = vim.api.nvim_buf_line_count(target_buf)
        local insert_at = math.min(node.start_line + offset, total_lines)
        
        vim.api.nvim_buf_set_lines(target_buf, insert_at, insert_at, false, node.lines)
        if tree then
            remove_node_from_tree(tree, node.id)
        end
        offset = offset + #node.lines
        count = count + 1
    end
    
    require("nvim_jupyter.ui").render_cells(target_buf)
    M.render()
    
    vim.notify("Successfully restored " .. count .. " selected cell(s)!", vim.log.levels.INFO)
end

-- Move cursor to next/previous node in sidebar
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

-- Toggle sidebar window
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
        vim.notify("Undo Tree is only available in Jupyter Notebook buffers.", vim.log.levels.WARN)
        return
    end
    
    -- Open vertical split on far left
    vim.cmd("topleft vsplit")
    sidebar_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(sidebar_win, 44)
    
    if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then
        sidebar_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(sidebar_buf, "Jupyter Undo Tree")
    end
    
    vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
    
    -- Configure sidebar buffer options
    vim.bo[sidebar_buf].buftype = "nofile"
    vim.bo[sidebar_buf].bufhidden = "hide"
    vim.bo[sidebar_buf].swapfile = false
    vim.bo[sidebar_buf].modifiable = false
    vim.wo[sidebar_win].wrap = false
    vim.wo[sidebar_win].number = false
    vim.wo[sidebar_win].relativenumber = false
    vim.wo[sidebar_win].signcolumn = "no"
    
    -- Set buffer keymaps inside sidebar
    local opts = { buffer = sidebar_buf, silent = true, noremap = true }
    vim.keymap.set('n', 'l', function() M.preview_code() end, opts)
    vim.keymap.set('n', 'r', function() M.restore_cell() end, opts)
    vim.keymap.set('n', 's', function() M.toggle_selection() end, opts)
    vim.keymap.set('n', '<CR>', function() M.apply_selection() end, opts)
    vim.keymap.set('n', 'j', function() M.jump_node(1) end, opts)
    vim.keymap.set('n', 'k', function() M.jump_node(-1) end, opts)
    vim.keymap.set('n', 'q', function() M.toggle_sidebar() end, opts)
    vim.keymap.set('n', '<Esc>', function() M.toggle_sidebar() end, opts)
    vim.keymap.set('n', '<leader>ut', function() M.toggle_sidebar() end, opts)
    
    M.render()
end

-- Render the sidebar content
function M.render()
    if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then return end
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end
    
    line_to_node = {}
    local lines = {}
    local highlights = {} -- table of { line_idx, col_start, col_end, hl_group }
    
    -- Header & Help Section
    table.insert(lines, "╭──────────────────────────────────────────╮")
    table.insert(lines, "│ CELL UNDO TREE                           │")
    table.insert(lines, "├──────────────────────────────────────────┤")
    table.insert(lines, "│  l    : View Code Preview                │")
    table.insert(lines, "│  r    : Restore Cell                     │")
    table.insert(lines, "│  s    : Toggle Selection Checkbox        │")
    table.insert(lines, "│  Enter: Apply Restoration (Selected)     │")
    table.insert(lines, "│  j/k  : Navigate Nodes                   │")
    table.insert(lines, "│  q/Esc: Close Sidebar                    │")
    table.insert(lines, "╰──────────────────────────────────────────╯")
    
    table.insert(highlights, {1, 2, 22, "JupyterUndoTitle"})
    for i = 0, 7 do
        table.insert(highlights, {i, 0, -1, "JupyterUndoBorder"})
    end
    for i = 3, 7 do
        table.insert(highlights, {i, 2, 40, "JupyterUndoHelp"})
    end
    
    table.insert(lines, "")
    
    local tree = get_tree(current_target_buf)
    
    if not tree or vim.tbl_isempty(tree.nodes) then
        table.insert(lines, "  (No deleted cells in history)")
        table.insert(highlights, {#lines - 1, 2, -1, "JupyterUndoHelp"})
    else
        -- Traverse and render tree nodes
        local function render_node(node_id, depth, prefix, is_last)
            local node = tree.nodes[node_id]
            if not node then return end
            
            local chk = node.selected and "[✓]" or "[ ]"
            local type_str = "[" .. (node.cell_type == "markdown" and "MD" or "Code") .. "]"
            local status_str = node.restored and "[Restored]" or ""
            local title_line = string.format("%s Node #%d %s %s %s", chk, node.id, type_str, status_str, node.timestamp)
            
            -- Padding for box line
            local box_width = 38
            if #title_line > box_width then title_line = title_line:sub(1, box_width) end
            local pad_len = box_width - #title_line
            if pad_len < 0 then pad_len = 0 end
            title_line = title_line .. string.rep(" ", pad_len)
            
            local box_top    = "┌────────────────────────────────────────┐"
            local box_mid    = "│ " .. title_line .. " │"
            local prev_line  = string.format("└─> %-34s │", node.preview)
            local box_bottom = "└────────────────────────────────────────┘"
            
            local box_connect_down = "                   │"
            
            -- Line 1: Top border
            table.insert(lines, box_top)
            local top_line_idx = #lines - 1
            line_to_node[top_line_idx] = node.id
            table.insert(highlights, {top_line_idx, 0, -1, "JupyterUndoBorder"})
            
            -- Line 2: Mid title line
            table.insert(lines, box_mid)
            local mid_line_idx = #lines - 1
            table.insert(highlights, {mid_line_idx, 0, -1, "JupyterUndoBorder"})
            
            -- Checkbox highlight
            if node.selected then
                table.insert(highlights, {mid_line_idx, 2, 5, "JupyterUndoSelected"})
            end
            -- Node header highlight
            table.insert(highlights, {mid_line_idx, 6, 14, "JupyterUndoNodeHeader"})
            -- Restored highlight
            if node.restored then
                table.insert(highlights, {mid_line_idx, 20, 30, "JupyterUndoRestored"})
            end
            
            -- Line 3: Code preview line
            table.insert(lines, "│ " .. prev_line)
            local prev_line_idx = #lines - 1
            table.insert(highlights, {prev_line_idx, 0, -1, "JupyterUndoBorder"})
            table.insert(highlights, {prev_line_idx, 6, -3, "JupyterUndoCode"})
            
            -- Line 4: Bottom border
            table.insert(lines, box_bottom)
            local bot_line_idx = #lines - 1
            table.insert(highlights, {bot_line_idx, 0, -1, "JupyterUndoBorder"})
            
            -- Render child nodes with connector lines
            if #node.children > 0 then
                table.insert(lines, box_connect_down)
                table.insert(highlights, {#lines - 1, 0, -1, "JupyterUndoBorder"})
                
                for idx, child_id in ipairs(node.children) do
                    local child_is_last = (idx == #node.children)
                    render_node(child_id, depth + 1, prefix, child_is_last)
                end
            end
        end
        
        for idx, root_id in ipairs(tree.root_ids) do
            render_node(root_id, 0, "", idx == #tree.root_ids)
        end
    end
    
    vim.bo[sidebar_buf].modifiable = true
    vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
    vim.bo[sidebar_buf].modifiable = false
    
    vim.api.nvim_buf_clear_namespace(sidebar_buf, ns_id, 0, -1)
    
    -- Apply highlights
    for _, h in ipairs(highlights) do
        pcall(function()
            vim.api.nvim_buf_add_highlight(sidebar_buf, ns_id, h[4], h[1], h[2], h[3])
        end)
    end
    
    -- Place cursor on first node if not already set
    if #lines > 9 and line_to_node[9] then
        pcall(function()
            vim.api.nvim_win_set_cursor(sidebar_win, {10, 2})
        end)
    end
end

function M.sync_native_undo(bufnr)
    local tree = undo_trees[bufnr]
    if not tree then return end
    
    local current_seq = vim.fn.undotree().seq_cur
    local removed_any = false
    
    -- We need to gather all nodes that need removal first
    local to_remove = {}
    for id, node in pairs(tree.nodes) do
        if node.undo_seq and node.undo_seq >= current_seq then
            table.insert(to_remove, id)
        end
    end
    
    for _, id in ipairs(to_remove) do
        remove_node_from_tree(tree, id)
        removed_any = true
    end
    
    if removed_any and sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) and current_target_buf == bufnr then
        vim.schedule(function()
            M.render()
        end)
    end
end

function M.setup()
    -- Create user command to toggle Undo Tree
    vim.api.nvim_create_user_command("JupyterUndoTree", function()
        M.toggle_sidebar()
    end, { desc = "Toggle Jupyter Cell Undo Tree sidebar" })
    
    -- Autocmd to sync with native undo
    vim.api.nvim_create_autocmd("TextChanged", {
        callback = function(args)
            if vim.b[args.buf].is_jupyter then
                M.sync_native_undo(args.buf)
            end
        end
    })
end

return M

