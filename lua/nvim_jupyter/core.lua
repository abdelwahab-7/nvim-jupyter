local M = {}
local rpc = require("nvim_jupyter.rpc")
local floating = require("nvim_jupyter.floating")
local utils = require("nvim_jupyter.utils")

local local_ns_id = vim.api.nvim_create_namespace("nvim_jupyter_local")
local cell_tracker_id = nil

function M.get_current_cell_bounds(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1] - 1
    
    local start_line = current_line
    while start_line >= 0 do
        local line_text = vim.api.nvim_buf_get_lines(buf, start_line, start_line + 1, false)[1]
        if line_text and line_text:match("^# %%%%") then
            break
        end
        start_line = start_line - 1
    end
    
    if start_line < 0 then
        start_line = 0
    end
    
    local end_line = current_line
    local total_lines = vim.api.nvim_buf_line_count(buf)
    while end_line < total_lines - 1 do
        local line_text = vim.api.nvim_buf_get_lines(buf, end_line + 1, end_line + 2, false)[1]
        if line_text and line_text:match("^# %%%%") then
            end_line = end_line
            break
        end
        end_line = end_line + 1
    end
    
    return buf, start_line, end_line
end

function M.is_in_output_block()
    local buf = vim.api.nvim_get_current_buf()
    local _, start_line, _ = M.get_current_cell_bounds()
    local line = vim.api.nvim_buf_get_lines(buf, start_line, start_line + 1, false)[1]
    return line and line:match("^# %%%% %[output%]") ~= nil
end

M.track_ns = vim.api.nvim_create_namespace("jupyter_tracker")
M.output_ns = vim.api.nvim_create_namespace("jupyter_output_blocks")
M.execution_timers = {}
M.execution_durations = {}

function M.update_cell_status(bufnr, cell_id, status)
    if not M.execution_timers[cell_id] then return end

    if status == "running" then
        M.execution_durations[cell_id] = nil
    else
        local duration = (vim.loop.now() - M.execution_timers[cell_id]) / 1000.0
        M.execution_durations[cell_id] = { status = status, duration = duration }
    end
    
    -- Tell the UI to dynamically redraw and attach this new duration
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            require("nvim_jupyter.ui").render_cells(bufnr)
        end
    end)
end

function M.remove_output_block_after(buf, end_line)
    local output_header = vim.api.nvim_buf_get_lines(buf, end_line + 1, end_line + 2, false)[1]
    if not output_header or not output_header:match("^# %%%% %[output%]") then
        return
    end

    local out_start = end_line + 1
    local out_end = out_start
    local total = vim.api.nvim_buf_line_count(buf)
    for line_number = out_start + 1, total - 1 do
        local line = vim.api.nvim_buf_get_lines(buf, line_number, line_number + 1, false)[1]
        if line and line:match("^# %%%%") then
            break
        end
        out_end = line_number
    end

    local marks = vim.api.nvim_buf_get_extmarks(buf, M.output_ns, { out_start, 0 }, { out_end + 1, 0 }, {})
    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_del_extmark(buf, M.output_ns, mark[1])
    end
    
    local ok, api = pcall(require, "image")
    if ok then
        for _, img in ipairs(api.get_images({buffer = buf}) or {}) do
            local y = -1
            if img.geometry and type(img.geometry.y) == "number" then y = img.geometry.y end
            if type(img.has_extmark_moved) == "function" then
                local moved, row, _ = img:has_extmark_moved()
                if moved and type(row) == "number" then 
                    y = row 
                elseif img.extmark and type(img.extmark.row) == "number" then 
                    y = img.extmark.row 
                end
            end
            
            if y >= out_start and y <= out_end then
                pcall(function() img:clear() end)
                img.buffer = -1 -- Orphan it to prevent re-rendering
                img.window = -1
            end
        end
    end
    
    utils.set_lines_no_undo(buf, out_start, out_end + 1, false, {})
end

function M.create_output_block(buf, line_number)
    utils.set_lines_no_undo(buf, line_number, line_number, false, { "# %% [output]" })
    return vim.api.nvim_buf_set_extmark(buf, M.output_ns, line_number, 0, { right_gravity = true })
end

function M.run_current_cell(target_line, bufnr)
    floating.close_all()

    local buf = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_get_option(buf, "modifiable") then
        vim.notify("Please return to the notebook buffer to run a cell.", vim.log.levels.WARN)
        M.is_executing_queue = false
        return
    end

    local _
    local start_line = target_line
    local end_line = target_line
    
    if target_line then
        -- Find end_line for the given target_line (start_line)
        local total_lines = vim.api.nvim_buf_line_count(buf)
        end_line = start_line
        while end_line < total_lines - 1 do
            local line_text = vim.api.nvim_buf_get_lines(buf, end_line + 1, end_line + 2, false)[1]
            if line_text and line_text:match("^# %%%%") then
                break
            end
            end_line = end_line + 1
        end
    else
        _, start_line, end_line = M.get_current_cell_bounds()
    end
    
    if M.is_in_output_block() and not target_line then
        vim.notify("Cannot run an output block.", vim.log.levels.WARN)
        M.on_cell_execution_finished(buf)
        return
    end
    
    local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)
    local is_markdown = false
    if lines[1] and lines[1]:match("^# %%%% %[markdown%]") then
        is_markdown = true
    end
    
    -- Clear any hidden outputs so the new one takes over
    local hidden_ns = vim.api.nvim_create_namespace("jupyter_hidden")
    local marks = vim.api.nvim_buf_get_extmarks(buf, hidden_ns, {start_line, 0}, {start_line, -1}, {})
    if #marks > 0 then
        local id = marks[1][1]
        vim.api.nvim_buf_del_extmark(buf, hidden_ns, id)
        if vim.b[buf].hidden_outputs then
            local ho = vim.b[buf].hidden_outputs
            ho[id] = nil
            vim.b[buf].hidden_outputs = ho
        end
    end
    
    M.remove_output_block_after(buf, end_line)
    local output_id = M.create_output_block(buf, end_line + 1)
    
    if is_markdown then
        local md_lines = {}
        for i = 2, #lines do
            table.insert(md_lines, lines[i])
        end
        
        local raw_html = table.concat(md_lines, "\n")
        
        -- macOS QuickLook restricts remote network requests for security.
        -- We must download remote images to local files first and rewrite the HTML!
        raw_html = raw_html:gsub('src=["\'](https?://[^"\']+)["\']', function(url)
            local ext = url:match("%.([^%.]+)$") or "png"
            ext = ext:gsub("%?.*$", "")
            local local_path = "/tmp/jupyter_img_" .. vim.fn.sha256(url):sub(1, 8) .. "." .. ext
            vim.fn.system({"curl", "-s", "-o", local_path, url})
            return 'src="' .. local_path .. '"'
        end)
        
        local filename = "markdown_" .. os.time()
        local html_path = "/tmp/" .. filename .. ".html"
        local png_path = "/tmp/" .. filename .. ".html.png"
        
        -- We construct a pure HTML file with a beautiful dark mode theme
        -- We use <pre> with a non-monospace font so the white-space is preserved 
        -- while allowing HTML tags to render naturally!
        local html_content = {
            "<html><body style='background: #1e1e2e; color: #cdd6f4; font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Helvetica, Arial, sans-serif; font-size: 24px; padding: 20px;'>",
            "<pre style='white-space: pre-wrap; font-family: inherit; margin: 0; padding: 0;'>",
            raw_html,
            "</pre></body></html>"
        }
        
        local f = io.open(html_path, "w")
        if f then
            f:write(table.concat(html_content, "\n"))
            f:close()
        end
        
        -- Run the massive WebKit conversion in the background to avoid freezing Neovim
        vim.notify("Rendering WebKit HTML to Image...", vim.log.levels.INFO)
        
        M.current_queue_cell_id = "markdown"
        
        vim.defer_fn(function()
            -- macOS qlmanage generates a flawless HTML thumbnail using Safari's engine!
            vim.fn.system({"qlmanage", "-t", "-s", "1200", "-o", "/tmp", html_path})
            
            -- Crop out the massive empty white space that qlmanage defaults to
            vim.fn.system({"magick", png_path, "-trim", "+repage", "-resize", "120%", png_path})
            
            -- We inject the beautifully rendered image into the output block 
            -- and let our `image.nvim` engine perfectly display it inline!
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(buf) then return end
                rpc.render_image_output(buf, output_id, png_path, "Markdown")
                require("nvim_jupyter.ui").render_cells(buf)
                M.on_cell_execution_finished(buf, "markdown")
            end)
        end, 10)
        
        return
    end
    
    local code = table.concat(lines, "\n")
    
    -- Create a robust invisible tracking extmark on the cell header
    vim.api.nvim_buf_clear_namespace(buf, M.track_ns, start_line, start_line + 1)
    local track_id = vim.api.nvim_buf_set_extmark(buf, M.track_ns, start_line, 0, { right_gravity = true })
    
    -- Reset any previous duration for this cell and record start time using track_id
    M.execution_durations[track_id] = nil
    M.execution_timers[track_id] = vim.loop.now()
    M.current_queue_cell_id = track_id
    
    -- Use the track_id as the cell_id so RPC output appending follows the cell if it moves
    pcall(function()
        rpc.send("execute", {
            bufnr = buf,
            cell_id = track_id,
            output_id = output_id,
            code = code
        })
    end)
    
    -- Force an immediate redraw to clear the output visually
    require("nvim_jupyter.ui").render_cells(buf)
end

local hidden_ns = vim.api.nvim_create_namespace("jupyter_hidden")

function M.toggle_output_visibility()
    local buf = vim.api.nvim_get_current_buf()
    local _, start_line, end_line = M.get_current_cell_bounds()
    
    if not vim.b[buf].hidden_outputs then vim.b[buf].hidden_outputs = {} end
    
    if M.is_in_output_block() then
        -- Find parent code cell
        local cursor = vim.api.nvim_win_get_cursor(0)
        vim.api.nvim_win_set_cursor(0, {start_line, 0})
        local _, parent_start, _ = M.get_current_cell_bounds()
        vim.api.nvim_win_set_cursor(0, cursor)
        
        -- Hide this output block
        local total = vim.api.nvim_buf_line_count(buf)
        local out_end = start_line
        for i = start_line + 1, total - 1 do
            local l = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1]
            if l and l:match("^# %%%%") then break end
            out_end = i
        end
        
        local hidden_images = {}
        local ok, api = pcall(require, "image")
        if ok then
            for _, img in ipairs(api.get_images({buffer = buf}) or {}) do
                local y = -1
                if img.geometry and type(img.geometry.y) == "number" then y = img.geometry.y end
                if type(img.has_extmark_moved) == "function" then
                    local moved, row, _ = img:has_extmark_moved()
                    if moved and type(row) == "number" then 
                        y = row 
                    elseif img.extmark and type(img.extmark.row) == "number" then 
                        y = img.extmark.row 
                    end
                end
                
                if y >= start_line and y <= out_end then
                    table.insert(hidden_images, { filepath = img.id, y_offset = y - start_line })
                    pcall(function() img:clear() end)
                    img.buffer = -1 -- Orphan it to prevent re-rendering
                    img.window = -1
                end
            end
        end
        
        local hidden_lines = vim.api.nvim_buf_get_lines(buf, start_line, out_end + 1, false)
        local id = vim.api.nvim_buf_set_extmark(buf, hidden_ns, parent_start, 0, {})
        local ho = vim.b[buf].hidden_outputs
        ho[id] = { lines = hidden_lines, images = hidden_images }
        vim.b[buf].hidden_outputs = ho
        
        utils.set_lines_no_undo(buf, start_line, out_end + 1, false, {})
        vim.api.nvim_win_set_cursor(0, {parent_start + 1, 0})
        return
    end
    
    -- In Code cell: Check if we have hidden outputs tracked by extmark
    local marks = vim.api.nvim_buf_get_extmarks(buf, hidden_ns, {start_line, 0}, {start_line, -1}, {})
    if #marks > 0 then
        local id = marks[1][1]
        local ho = vim.b[buf].hidden_outputs
        local hidden_data = ho[id]
        if hidden_data then
            local lines = hidden_data.lines or hidden_data
            utils.set_lines_no_undo(buf, end_line + 1, end_line + 1, false, lines)
            vim.api.nvim_buf_del_extmark(buf, hidden_ns, id)
            ho[id] = nil
            vim.b[buf].hidden_outputs = ho
            
            if hidden_data.images then
                local ok, api = pcall(require, "image")
                if ok then
                    local win = vim.fn.bufwinid(buf)
                    for _, img_data in ipairs(hidden_data.images) do
                        local y_pos = end_line + 1 + img_data.y_offset
                        local created, image = pcall(api.from_file, img_data.filepath, {
                            id = img_data.filepath,
                            window = win,
                            buffer = buf,
                            with_virtual_padding = false,
                            inline = true,
                            x = 1,
                            y = y_pos,
                            max_width_window_percentage = 90,
                            max_height_window_percentage = 60,
                        })
                        if created and image and image.render then image:render() end
                    end
                end
            end
        end
        return
    end
    
    -- In Code cell: Check if there's a physical output block below to hide
    local lines_after = vim.api.nvim_buf_get_lines(buf, end_line + 1, end_line + 2, false)
    if lines_after[1] and lines_after[1]:match("^# %%%% %[output%]") then
        local out_start = end_line + 1
        local out_end = out_start
        local total = vim.api.nvim_buf_line_count(buf)
        for i = out_start + 1, total - 1 do
            local l = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1]
            if l and l:match("^# %%%%") then break end
            out_end = i
        end
        
        local hidden_images = {}
        local ok, api = pcall(require, "image")
        if ok then
            for _, img in ipairs(api.get_images({buffer = buf}) or {}) do
                local y = -1
                if img.geometry and type(img.geometry.y) == "number" then y = img.geometry.y end
                if type(img.has_extmark_moved) == "function" then
                    local moved, row, _ = img:has_extmark_moved()
                    if moved and type(row) == "number" then 
                        y = row 
                    elseif img.extmark and type(img.extmark.row) == "number" then 
                        y = img.extmark.row 
                    end
                end
                
                if y >= out_start and y <= out_end then
                    table.insert(hidden_images, { filepath = img.id, y_offset = y - out_start })
                    pcall(function() img:clear() end)
                    img.buffer = -1 -- Orphan it to prevent re-rendering
                    img.window = -1
                end
            end
        end
        
        local hidden_lines = vim.api.nvim_buf_get_lines(buf, out_start, out_end + 1, false)
        local id = vim.api.nvim_buf_set_extmark(buf, hidden_ns, start_line, 0, {})
        local ho = vim.b[buf].hidden_outputs
        ho[id] = { lines = hidden_lines, images = hidden_images }
        vim.b[buf].hidden_outputs = ho
        
        utils.set_lines_no_undo(buf, out_start, out_end + 1, false, {})
    end
end

-- toggle_output is removed because we now use physical standard folding (zc/zo)
-- function M.toggle_output()

function M.add_cell_below()
    local buf, _, end_line = M.get_current_cell_bounds()
    
    -- If there's an output block attached below, skip past it so we don't steal it!
    local lines_after = vim.api.nvim_buf_get_lines(buf, end_line + 1, end_line + 2, false)
    if lines_after[1] and lines_after[1]:match("^# %%%% %[output%]") then
        local out_start = end_line + 1
        local out_end = out_start
        local total = vim.api.nvim_buf_line_count(buf)
        for i = out_start + 1, total - 1 do
            local l = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1]
            if l and l:match("^# %%%%") then break end
            out_end = i
        end
        end_line = out_end
    end
    
    vim.api.nvim_buf_set_lines(buf, end_line + 1, end_line + 1, false, {"", "# %%", ""})
    vim.api.nvim_win_set_cursor(0, {end_line + 3, 0})
end

function M.add_cell_above()
    local buf, start_line, _ = M.get_current_cell_bounds()
    vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, {"# %%", "", ""})
    vim.api.nvim_win_set_cursor(0, {start_line + 2, 0})
end

function M.delete_cell()
    local buf, start_line, end_line = M.get_current_cell_bounds()
    
    local clear_start = start_line
    local clear_end = end_line

    -- If an output block follows end_line, include it in deletion
    local lines_after = vim.api.nvim_buf_get_lines(buf, end_line + 1, end_line + 2, false)
    if lines_after[1] and lines_after[1]:match("^# %%%% %[output%]") then
        local out_start = end_line + 1
        local out_end = out_start
        local total = vim.api.nvim_buf_line_count(buf)
        for i = out_start + 1, total - 1 do
            local l = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1]
            if l and l:match("^# %%%%") then break end
            out_end = i
        end
        end_line = out_end
        clear_end = out_end
    end
    
    local ok, api = pcall(require, "image")
    if ok then
        for _, img in ipairs(api.get_images({buffer = buf}) or {}) do
            local y = -1
            if img.geometry and type(img.geometry.y) == "number" then y = img.geometry.y end
            if type(img.has_extmark_moved) == "function" then
                local moved, row, _ = img:has_extmark_moved()
                if moved and type(row) == "number" then 
                    y = row 
                elseif img.extmark and type(img.extmark.row) == "number" then 
                    y = img.extmark.row 
                end
            end
            
            if y >= clear_start and y <= clear_end then
                pcall(function() img:clear() end)
                img.buffer = -1 -- Orphan it to prevent re-rendering
                img.window = -1
            end
        end
    end

    local deleted_lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)
    require("nvim_jupyter.undo_tree").push_deleted_cell(buf, deleted_lines, start_line)

    -- If it's the only cell, don't delete the whole file, just clear it
    if start_line == 0 and end_line >= vim.api.nvim_buf_line_count(buf) - 1 then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"# %%", ""})
        return
    end
    vim.api.nvim_buf_set_lines(buf, start_line, end_line + 1, false, {})
end

local function get_all_cells(buf)
    local cells = {}
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local current_cell_start = 0
    for i, line in ipairs(lines) do
        if line:match("^# %%%%") and not line:match("^# %%%% %[output%]") then
            if i > 1 then
                table.insert(cells, current_cell_start)
            end
            current_cell_start = i - 1
        end
    end
    table.insert(cells, current_cell_start)
    return cells
end

M.execution_queue = {}
M.execution_buf = nil
M.current_queue_cell_id = nil
M.is_executing_queue = false
M.execution_queue_ns = vim.api.nvim_create_namespace("jupyter_execution_queue")

function M.run_next_in_queue()
    if #M.execution_queue == 0 then
        M.is_executing_queue = false
        M.current_queue_cell_id = nil
        if M.execution_buf and vim.api.nvim_buf_is_valid(M.execution_buf) then
            vim.api.nvim_buf_clear_namespace(M.execution_buf, M.execution_queue_ns, 0, -1)
        end
        M.execution_buf = nil
        return
    end
    
    local cell = table.remove(M.execution_queue, 1)
    local mark = vim.api.nvim_buf_get_extmark_by_id(M.execution_buf, M.execution_queue_ns, cell.mark_id, {})
    if not mark or #mark == 0 then
        M.run_next_in_queue()
        return
    end
    
    M.run_current_cell(mark[1], M.execution_buf)
end

function M.on_cell_execution_finished(buf, cell_id)
    if not M.is_executing_queue or buf ~= M.execution_buf then return end
    if cell_id and cell_id ~= M.current_queue_cell_id then return end
    
    vim.schedule(M.run_next_in_queue)
end

local function execute_cells_safely(buf, cells_to_run)
    if M.is_executing_queue then
        vim.notify("Already running a cell sequence...", vim.log.levels.WARN)
        return
    end
    
    vim.api.nvim_buf_clear_namespace(buf, M.execution_queue_ns, 0, -1)
    M.execution_queue = {}
    for _, start_line in ipairs(cells_to_run) do
        local mark_id = vim.api.nvim_buf_set_extmark(buf, M.execution_queue_ns, start_line, 0, {
            right_gravity = true,
        })
        table.insert(M.execution_queue, { mark_id = mark_id })
    end
    M.execution_buf = buf
    M.is_executing_queue = true
    
    M.run_next_in_queue()
end

function M.run_all()
    local buf = vim.api.nvim_get_current_buf()
    execute_cells_safely(buf, get_all_cells(buf))
end

function M.run_cells_above()
    local buf, current_start, _ = M.get_current_cell_bounds()
    local cells = get_all_cells(buf)
    local to_run = {}
    for _, start_line in ipairs(cells) do
        if start_line < current_start then
            table.insert(to_run, start_line)
        end
    end
    execute_cells_safely(buf, to_run)
end

function M.run_cells_below()
    local buf, current_start, _ = M.get_current_cell_bounds()
    local cells = get_all_cells(buf)
    local to_run = {}
    for _, start_line in ipairs(cells) do
        if start_line >= current_start then
            table.insert(to_run, start_line)
        end
    end
    execute_cells_safely(buf, to_run)
end

function M.interrupt_execution()
    M.execution_queue = {}
    M.is_executing_queue = false
    M.current_queue_cell_id = nil
    if M.execution_buf and vim.api.nvim_buf_is_valid(M.execution_buf) then
        vim.api.nvim_buf_clear_namespace(M.execution_buf, M.execution_queue_ns, 0, -1)
    end
    M.execution_buf = nil
    rpc.send("interrupt", {})
    vim.notify("Jupyter execution interrupted.", vim.log.levels.INFO)
end

local function get_cursor_code_cell_start()
    local buf, start_line = M.get_current_cell_bounds()
    local header = vim.api.nvim_buf_get_lines(buf, start_line, start_line + 1, false)[1]
    if not header or not header:match("^# %%%% %[output%]") then
        return buf, start_line
    end

    for line_number = start_line - 1, 0, -1 do
        local line = vim.api.nvim_buf_get_lines(buf, line_number, line_number + 1, false)[1]
        if line and line:match("^# %%%%") and not line:match("^# %%%% %[output%]") then
            return buf, line_number
        end
    end
end

local function is_running_cell(buf, start_line)
    local marks = vim.api.nvim_buf_get_extmarks(buf, M.track_ns, { start_line, 0 }, { start_line, -1 }, {})
    for _, mark in ipairs(marks) do
        local cell_id = mark[1]
        if M.execution_timers[cell_id] and not M.execution_durations[cell_id] then
            return true
        end
    end
    return false
end

local function remove_queued_cell(buf, start_line)
    if not M.is_executing_queue or M.execution_buf ~= buf then return false end

    for index, cell in ipairs(M.execution_queue) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.execution_queue_ns, cell.mark_id, {})
        if mark and #mark > 0 and mark[1] == start_line then
            table.remove(M.execution_queue, index)
            vim.api.nvim_buf_del_extmark(buf, M.execution_queue_ns, cell.mark_id)
            return true
        end
    end

    return false
end

function M.cancel_current_cell()
    local buf, start_line = get_cursor_code_cell_start()
    if not buf then
        vim.notify("No executable cell found at the cursor.", vim.log.levels.WARN)
        return
    end

    if is_running_cell(buf, start_line) then
        rpc.send("interrupt", {})
        vim.notify("Current Jupyter cell interrupted.", vim.log.levels.INFO)
    elseif remove_queued_cell(buf, start_line) then
        vim.notify("Current Jupyter cell removed from the queue.", vim.log.levels.INFO)
    else
        vim.notify("Current cell is not running or queued.", vim.log.levels.WARN)
    end
end

function M.jump_next_cell(count)
    count = count or 1
    local buf = vim.api.nvim_get_current_buf()
    while count > 0 do
        local _, _, end_line = M.get_current_cell_bounds()
        local total_lines = vim.api.nvim_buf_line_count(buf)
        if end_line + 1 < total_lines then
            vim.api.nvim_win_set_cursor(0, {end_line + 2, 0})
            if not M.is_in_output_block() then
                count = count - 1
            end
        else
            break
        end
    end
end

function M.jump_prev_cell(count)
    count = count or 1
    local buf = vim.api.nvim_get_current_buf()
    while count > 0 do
        local _, start_line, _ = M.get_current_cell_bounds()
        if start_line > 0 then
            vim.api.nvim_win_set_cursor(0, {start_line, 0})
            local _, prev_start, _ = M.get_current_cell_bounds()
            vim.api.nvim_win_set_cursor(0, {prev_start + 1, 0})
            
            if not M.is_in_output_block() then
                count = count - 1
            end
        else
            break
        end
    end
end

function M.view_full_output()
    local buf = vim.api.nvim_get_current_buf()
    local _, start_line, _ = M.get_current_cell_bounds()
    
    local marks = vim.api.nvim_buf_get_extmarks(buf, M.track_ns, {start_line, 0}, {start_line, -1}, {})
    if not marks or #marks == 0 then
        vim.notify("Could not identify the current cell for output viewing.", vim.log.levels.WARN)
        return
    end
    
    local cell_id = marks[1][1]
    local log_file = "/tmp/nvim_jupyter_output_" .. cell_id .. ".log"
    
    if vim.fn.filereadable(log_file) == 1 then
        vim.cmd("vsplit " .. log_file)
        local out_buf = vim.api.nvim_get_current_buf()
        pcall(vim.api.nvim_buf_set_option, out_buf, "buftype", "nofile")
        pcall(vim.api.nvim_buf_set_option, out_buf, "bufhidden", "wipe")
        pcall(vim.api.nvim_buf_set_option, out_buf, "swapfile", false)
        pcall(vim.api.nvim_buf_set_option, out_buf, "modifiable", false)
    else
        vim.notify("No full output log found for this cell.", vim.log.levels.INFO)
    end
end

function M.on_insert_leave()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.b[buf].is_jupyter then return end
    vim.b[buf].jupyter_state = "local"
    
    local _, start_line, end_line = M.get_current_cell_bounds()
    cell_tracker_id = vim.api.nvim_buf_set_extmark(buf, local_ns_id, start_line, 0, { id = 1 })
end

function M.on_cursor_moved()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.b[buf].is_jupyter then return end
    
    local state = vim.b[buf].jupyter_state or "global"
    if state == "global" then return end
    
    -- In Local Mode, find the tracked cell header
    if not cell_tracker_id then return end
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, local_ns_id, cell_tracker_id, {})
    if not mark or #mark == 0 then return end
    
    local cell_start = mark[1]
    
    -- Dynamically calculate end_line so it works even if lines are deleted
    local end_line = cell_start
    local total_lines = vim.api.nvim_buf_line_count(buf)
    while end_line < total_lines - 1 do
        local line_text = vim.api.nvim_buf_get_lines(buf, end_line + 1, end_line + 2, false)[1]
        if line_text and line_text:match("^# %%%%") then
            break
        end
        end_line = end_line + 1
    end
    
    if end_line == cell_start then
        -- Cell is totally empty, protect it by inserting a blank line
        vim.api.nvim_buf_set_lines(buf, cell_start + 1, cell_start + 1, false, {""})
        end_line = cell_start + 1
    end
    
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1] - 1
    local clamped = false
    
    if current_line <= cell_start then
        local target_row = cell_start + 2
        if target_row > total_lines then target_row = total_lines end
        vim.api.nvim_win_set_cursor(0, {target_row, cursor[2]})
        clamped = true
    elseif current_line > end_line then
        local target_row = end_line + 1
        if target_row > total_lines then target_row = total_lines end
        vim.api.nvim_win_set_cursor(0, {target_row, cursor[2]})
        clamped = true
    end
    
    if clamped then
        -- Force a UI redraw because nvim_win_set_cursor doesn't immediately re-trigger CursorMoved
        require("nvim_jupyter.ui").render_cells(buf)
        require("nvim_jupyter.local_undo").sync_with_cursor(buf)
    end
end

function M.setup()
    vim.api.nvim_create_user_command("JupyterStart", function()
        rpc.start()
    end, { desc = "Start the Jupyter background kernel" })

    vim.api.nvim_create_user_command("JupyterStop", function()
        rpc.stop()
    end, { desc = "Stop the Jupyter background kernel" })

    vim.api.nvim_create_user_command("JupyterInterrupt", function()
        M.interrupt_execution()
    end, { desc = "Interrupt all running and queued Jupyter cells" })

    vim.api.nvim_create_user_command("JupyterCancelCell", function()
        M.cancel_current_cell()
    end, { desc = "Interrupt or skip the Jupyter cell at the cursor" })
    
    -- Setup autocommands for Jupyter Command/Edit mode logic
    local group = vim.api.nvim_create_augroup("NvimJupyterMode", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "python",
        callback = function(args)
            if not vim.b[args.buf].is_jupyter then return end
            
            -- Initialize buffer-local user commands
            vim.api.nvim_buf_create_user_command(args.buf, "JupyterRunCell", function()
                M.run_current_cell()
            end, { desc = "Execute the current notebook cell" })
            
            vim.api.nvim_buf_create_user_command(args.buf, "JupyterAddCellBelow", function()
                M.add_cell_below()
            end, { desc = "Add a cell below" })
            
            vim.api.nvim_buf_create_user_command(args.buf, "JupyterAddCellAbove", function()
                M.add_cell_above()
            end, { desc = "Add a cell above" })
            
            vim.api.nvim_buf_create_user_command(args.buf, "JupyterDeleteCell", function()
                M.delete_cell()
            end, { desc = "Delete the current cell" })
            
            -- Buffer-local keymaps for execution/management
            local keymaps = require("nvim_jupyter.config").options.keymaps
            vim.keymap.set('n', keymaps.run_current_cell, M.run_current_cell, { buffer = args.buf, desc = "Run Jupyter cell" })
            vim.keymap.set('n', keymaps.run_all, M.run_all, { buffer = args.buf, desc = "Run all cells" })
            vim.keymap.set('n', keymaps.cancel_current_cell, M.cancel_current_cell, { buffer = args.buf, desc = "Interrupt or skip current Jupyter cell" })
            vim.keymap.set('n', keymaps.interrupt_execution, M.interrupt_execution, { buffer = args.buf, desc = "Interrupt all Jupyter cells" })
            vim.keymap.set('n', keymaps.run_cells_above, M.run_cells_above, { buffer = args.buf, desc = "Run cells above" })
            vim.keymap.set('n', keymaps.run_cells_below, M.run_cells_below, { buffer = args.buf, desc = "Run cells below" })
            vim.keymap.set('n', keymaps.add_cell_below, M.add_cell_below, { buffer = args.buf, desc = "Add Jupyter cell below" })
            vim.keymap.set('n', keymaps.toggle_variable_explorer, function() require("nvim_jupyter.variables").toggle_sidebar() end, { buffer = args.buf, desc = "Toggle Variable Explorer" })
            vim.keymap.set('n', keymaps.toggle_local_variables, function() require("nvim_jupyter.local_variables").toggle_sidebar() end, { buffer = args.buf, desc = "Toggle Local Variable Explorer" })
            vim.keymap.set('n', keymaps.toggle_undo_tree, function() require("nvim_jupyter.undo_tree").toggle_sidebar() end, { buffer = args.buf, desc = "Toggle Undo Tree Sidebar" })
            vim.keymap.set('n', keymaps.toggle_local_undo, function() require("nvim_jupyter.local_undo").toggle_sidebar() end, { buffer = args.buf, desc = "Toggle Local Cell Undo Tree" })
            vim.keymap.set('n', '<leader>vo', M.view_full_output, { buffer = args.buf, desc = "View full cell output" })
            
            -- Ensure state starts global
            vim.b[args.buf].jupyter_state = "global"
            
            -- Setup dynamic line numbers for Local Mode
            vim.opt_local.number = true
            vim.opt_local.statuscolumn = "%!v:lua.JupyterStatusColumn()"
            vim.opt_local.foldmethod = "manual"
            vim.opt_local.wrap = false
            
            vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
                buffer = args.buf,
                callback = function()
                    if vim.b[args.buf].jupyter_state == "local" then
                        local mark = vim.api.nvim_buf_get_extmark_by_id(args.buf, local_ns_id, 1, {})
                        if mark and #mark > 0 then
                            local start_line = mark[1]
                            local end_line = start_line
                            local total_lines = vim.api.nvim_buf_line_count(args.buf)
                            
                            -- Find end of cell dynamically
                            while end_line < total_lines - 1 do
                                local line_text = vim.api.nvim_buf_get_lines(args.buf, end_line + 1, end_line + 2, false)[1]
                                if line_text and line_text:match("^# %%%%") then
                                    break
                                end
                                end_line = end_line + 1
                            end
                            
                            -- If cell is emptied (no blank lines between markers), inject one standalone line
                            if start_line == end_line then
                                pcall(vim.api.nvim_buf_set_lines, args.buf, start_line + 1, start_line + 1, false, {""})
                                end_line = start_line + 1
                            end
                            
                            local cursor = vim.api.nvim_win_get_cursor(0)
                            local line = cursor[1] - 1
                            local function enforce_bounds(target_row)
                                local max_col = string.len(vim.api.nvim_buf_get_lines(args.buf, target_row - 1, target_row, false)[1] or "")
                                local col = math.min(cursor[2], max_col)
                                -- Note: nvim_win_set_cursor uses 0-indexed column, but math.min safely keeps it within bounds.
                                -- If line is empty, max_col is 0, so col is 0.
                                pcall(vim.api.nvim_win_set_cursor, 0, {target_row, col})
                            end
                            
                            -- Trap the cursor strictly inside the cell's code area
                            local top_line_text = vim.api.nvim_buf_get_lines(args.buf, start_line, start_line + 1, false)[1]
                            local top_code_line_idx = start_line
                            if top_line_text and top_line_text:match("^# %%%%") then
                                top_code_line_idx = start_line + 1
                            end
                            
                            if line < top_code_line_idx then
                                enforce_bounds(top_code_line_idx + 1)
                            elseif line > end_line then
                                enforce_bounds(end_line + 1)
                            end
                            
                            -- Keep active cell tracked for UI highlights
                            vim.b[args.buf].jupyter_active_cell = { start_line = start_line, end_line = end_line }
                        end
                    end
                end,
            })
            
            local opts = { expr = true, buffer = args.buf, silent = true }
            
            vim.keymap.set('n', 'j', function()
                if vim.b.jupyter_state == "global" then
                    local count = vim.v.count1
                    return "<cmd>lua require('nvim_jupyter.core').jump_next_cell(" .. count .. ")<CR>"
                end
                if vim.b.jupyter_state == "local" and vim.b.jupyter_active_cell then
                    local cell = vim.b.jupyter_active_cell
                    local cursor = vim.api.nvim_win_get_cursor(0)
                    if cursor[1] - 1 >= cell.end_line then
                        return "<Ignore>"
                    end
                end
                return "j"
            end, opts)
            
            vim.keymap.set('n', 'k', function()
                if vim.b.jupyter_state == "global" then
                    local count = vim.v.count1
                    return "<cmd>lua require('nvim_jupyter.core').jump_prev_cell(" .. count .. ")<CR>"
                end
                if vim.b.jupyter_state == "local" and vim.b.jupyter_active_cell then
                    local cell = vim.b.jupyter_active_cell
                    local cursor = vim.api.nvim_win_get_cursor(0)
                    if cursor[1] - 1 <= cell.start_line + 1 then
                        return "<Ignore>"
                    end
                end
                return "k"
            end, opts)
            
            vim.keymap.set('n', 'h', function()
                if vim.b.jupyter_state == "global" then return "<Ignore>" end
                return "h"
            end, opts)
            
            vim.keymap.set('n', 'l', function()
                if vim.b.jupyter_state == "global" then
                    vim.schedule(function() M.toggle_output_visibility() end)
                    return "<Ignore>"
                end
                return "l"
            end, opts)
            
            -- Prevent entering Insert mode while in Global mode
            local function ignore_insert(key)
                return function()
                    if vim.b.jupyter_state == "global" then
                        vim.notify("Press <Esc> to enter Local Mode before editing.", vim.log.levels.INFO)
                        return "<Ignore>"
                    end
                    if vim.b.jupyter_state == "local" and require("nvim_jupyter.core").is_in_output_block() then
                        vim.notify("Cannot edit output blocks.", vim.log.levels.INFO)
                        return "<Ignore>"
                    end
                    return key
                end
            end
            
            vim.keymap.set('n', 'i', ignore_insert("i"), opts)
            vim.keymap.set('n', 'I', ignore_insert("I"), opts)
            vim.keymap.set('n', 'a', ignore_insert("a"), opts)
            vim.keymap.set('n', 'A', ignore_insert("A"), opts)
            vim.keymap.set('n', 'o', ignore_insert("o"), opts)
            vim.keymap.set('n', 'O', ignore_insert("O"), opts)
            vim.keymap.set('n', 'c', ignore_insert("c"), opts)
            vim.keymap.set('n', 'C', ignore_insert("C"), opts)
            vim.keymap.set('n', 'x', ignore_insert("x"), opts)
            vim.keymap.set('n', 's', ignore_insert("s"), opts)
            vim.keymap.set('n', 'S', ignore_insert("S"), opts)
            vim.keymap.set('n', 'p', ignore_insert("p"), opts)
            vim.keymap.set('n', 'P', ignore_insert("P"), opts)
            vim.keymap.set('n', 'r', ignore_insert("r"), opts)
            vim.keymap.set('n', 'R', ignore_insert("R"), opts)
            
            -- Explicit dd mapping to delete cell in global mode, mimicking Jupyter
            vim.keymap.set('n', 'dd', function()
                if vim.b.jupyter_state == "global" then
                    return "<cmd>lua require('nvim_jupyter.core').delete_cell()<CR>"
                end
                if vim.b.jupyter_state == "local" and require("nvim_jupyter.core").is_in_output_block() then
                    vim.notify("Cannot edit output blocks.", vim.log.levels.INFO)
                    return "<Ignore>"
                end
                return "dd"
            end, opts)

            -- Ignore loose 'd' commands in global mode to prevent accidental structural damage
            vim.keymap.set('n', 'd', ignore_insert("d"), opts)
            
            -- Escape key returns to Global mode
            vim.keymap.set('n', '<Esc>', function()
                if vim.b.jupyter_state == "local" then
                    vim.b.jupyter_state = "global"
                    local buf, start_line = M.get_current_cell_bounds()
                    pcall(vim.api.nvim_win_set_cursor, 0, {start_line + 1, 0})
                    require("nvim_jupyter.ui").render_cells(args.buf)
                end
            end, opts)

            -- Enter key enters Local mode and insert mode
            vim.keymap.set('n', '<CR>', function()
                if vim.b.jupyter_state == "global" then
                    local buf, start_line, end_line = M.get_current_cell_bounds()
                    local cursor = vim.api.nvim_win_get_cursor(0)
                    local current_line = cursor[1] - 1
                    
                    if start_line == end_line then
                        -- Cell is completely empty (no lines between borders), protect it by inserting a blank line
                        pcall(vim.api.nvim_buf_set_lines, buf, start_line + 1, start_line + 1, false, {""})
                        end_line = start_line + 1
                    end
                    
                    vim.b.jupyter_state = "local"
                    cell_tracker_id = vim.api.nvim_buf_set_extmark(buf, local_ns_id, start_line, 0, { id = 1 })
                    
                    local top_line_text = vim.api.nvim_buf_get_lines(buf, start_line, start_line + 1, false)[1]
                    local target_row = start_line + 1
                    if top_line_text and top_line_text:match("^# %%%%") then
                        target_row = start_line + 2
                    end
                    
                    -- Unconditionally jump to the first line of the code cell
                    pcall(vim.api.nvim_win_set_cursor, 0, {target_row, 0})
                    
                    require("nvim_jupyter.ui").render_cells(args.buf)
                end
            end, opts)

            -- Forbid insert mode entering from global mode
            local insert_keys = {'i', 'I', 'a', 'A', 'o', 'O', 'c', 'C', 's', 'S'}
            for _, key in ipairs(insert_keys) do
                vim.keymap.set('n', key, function()
                    if vim.b.jupyter_state == "global" then
                        vim.notify("Insert mode is disabled in Global Mode. Press <CR> to enter a cell first.", vim.log.levels.WARN)
                        return "<Ignore>"
                    end
                    return key
                end, { expr = true, buffer = args.buf, silent = true })
            end
        end,
    })

    if require("nvim_jupyter.config").options.clean_tmp_files_on_exit then
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = vim.api.nvim_create_augroup("JupyterCleanup", { clear = true }),
            callback = function()
                vim.fn.system("rm -f /tmp/df_*.html /tmp/df_*.html.png /tmp/plot_*.png")
            end,
            desc = "Clean up generated Jupyter temporary files on exit"
        })
    end
end

return M
