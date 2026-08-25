local M = {}
local ui = require("nvim_jupyter.ui")
local floating = require("nvim_jupyter.floating")
local utils = require("nvim_jupyter.utils")

local job_id = nil
local output_ns = vim.api.nvim_create_namespace("jupyter_output_blocks")
local image_ns = vim.api.nvim_create_namespace("jupyter_images")
M.kernel_state = "idle"

function M.status()
    return M.kernel_state
end

local function get_output_bounds(buf, output_id)
    if not output_id then return end

    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, output_ns, output_id, {})
    if not mark or #mark == 0 then return end

    local out_start = mark[1]
    local header = vim.api.nvim_buf_get_lines(buf, out_start, out_start + 1, false)[1]
    if not header or not header:match("^# %%%% %[output%]") then return end

    local out_end = out_start
    local total = vim.api.nvim_buf_line_count(buf)
    for line_number = out_start + 1, total - 1 do
        local line = vim.api.nvim_buf_get_lines(buf, line_number, line_number + 1, false)[1]
        if line and line:match("^# %%%%") then
            break
        end
        out_end = line_number
    end

    return out_start, out_end
end

local function append_to_output(buf, output_id, text_lines, keep_trailing_blank_lines)
    local _, out_end = get_output_bounds(buf, output_id)
    if not out_end then return end

    local cleaned = {}
    for _, line in ipairs(text_lines) do
        if type(line) == "string" then
            for _, subline in ipairs(vim.split(line, "\n")) do
                table.insert(cleaned, subline)
            end
        end
    end

    if not keep_trailing_blank_lines and #cleaned > 0 and cleaned[#cleaned] == "" then
        table.remove(cleaned)
    end
    if #cleaned == 0 then return end

    local insert_at = out_end + 1
    utils.set_lines_no_undo(buf, insert_at, insert_at, false, cleaned)
    return insert_at
end

local function image_padding_rows(buf, filepath)
    local win = vim.fn.bufwinid(buf)
    if win == -1 then return 16 end
    
    local win_height = vim.api.nvim_win_get_height(win)
    local win_width = vim.api.nvim_win_get_width(win)
    local max_padding = math.ceil(win_height * 0.60)
    
    local ok, api = pcall(require, "image")
    if ok and filepath then
        local created, img = pcall(api.from_file, filepath, { id = filepath .. "_dim_check" })
        if created and img and img.image_height and img.image_width then
            local cell_height = 22
            local cell_width = 10
            
            local ok_utils, utils = pcall(require, "image.utils")
            if ok_utils and utils.term then
                local term_size = utils.term.get_size()
                if term_size and term_size.cell_height and term_size.cell_width then
                    cell_height = term_size.cell_height
                    cell_width = term_size.cell_width
                end
            end
            
            local img_w = img.image_width
            local img_h = img.image_height
            
            local max_width_px = math.floor(win_width * 0.90 * cell_width)
            local max_height_px = math.floor(win_height * 0.60 * cell_height)
            
            if img_w > max_width_px then
                local scale = max_width_px / img_w
                img_w = img_w * scale
                img_h = img_h * scale
            end
            
            if img_h > max_height_px then
                local scale = max_height_px / img_h
                img_w = img_w * scale
                img_h = img_h * scale
            end
            
            local img_rows = math.ceil(img_h / cell_height)
            return math.max(2, img_rows)
        end
    end
    
    return max_padding
end

local function render_anchored_image(buf, output_id, image_mark_id, filepath)
    vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end

        local out_start, out_end = get_output_bounds(buf, output_id)
        local image_mark = vim.api.nvim_buf_get_extmark_by_id(buf, image_ns, image_mark_id, {})
        if not out_start or not image_mark or #image_mark == 0 then return end

        local image_line = image_mark[1]
        if image_line <= out_start or image_line > out_end then return end

        local win = vim.fn.bufwinid(buf)
        if win == -1 then return end

        local ok, api = pcall(require, "image")
        if not ok then return end

        local created, image = pcall(api.from_file, filepath, {
            id = filepath,
            window = win,
            buffer = buf,
            with_virtual_padding = false,
            inline = true,
            x = 1,
            y = image_line,
            max_width_window_percentage = 90,
            max_height_window_percentage = 60,
        })
        if created and image and image.render then
            image:render()
        end
    end, 50)
end

function M.render_image_output(buf, output_id, filepath, label)
    local lines = { "", "[" .. label .. "]" }
    for _ = 1, image_padding_rows(buf, filepath) do
        table.insert(lines, "")
    end

    local insert_at = append_to_output(buf, output_id, lines, true)
    if not insert_at then return end

    local image_mark_id = vim.api.nvim_buf_set_extmark(buf, image_ns, insert_at + 1, 0, {
        right_gravity = true,
    })
    render_anchored_image(buf, output_id, image_mark_id, filepath)
end

local function handle_message(msg)
    if msg.method == "kernel_status" then
        M.kernel_state = msg.params.state
    elseif msg.method == "status" then
        local cell_id = msg.params.cell_id
        local bufnr = msg.params.bufnr
        local status = msg.params.status
        require("nvim_jupyter.core").update_cell_status(bufnr, cell_id, status)
        
        if status == "success" or status == "error" then
            require("nvim_jupyter.core").on_cell_execution_finished(bufnr, cell_id)
        end
    elseif msg.method == "variables" then
        require("nvim_jupyter.variables").update(msg.params.variables)
    elseif msg.method == "local_variables" then
        require("nvim_jupyter.local_variables").update(msg.params.cell_id, msg.params.variables)
    elseif msg.method == "output" then
        local p = msg.params
        
        if not vim.api.nvim_buf_is_valid(p.bufnr) then return end
        
        local function append_to_buffer(text_lines)
            append_to_output(p.bufnr, p.output_id, text_lines)
        end
        
        -- Output handling
        if p.type == "stream" then
            append_to_buffer(vim.split(utils.clean_output_text(p.text or ""), "\n"))
        elseif p.type == "error" then
            local t = type(p.traceback) == "table" and table.concat(p.traceback, "\n") or (p.traceback or "")
            append_to_buffer(vim.split(utils.clean_output_text(t), "\n"))
        elseif p.type == "data" then
            if p.data["text/plain"] then
                local t = type(p.data["text/plain"]) == "table" and table.concat(p.data["text/plain"], "\n") or (p.data["text/plain"] or "")
                append_to_buffer(vim.split(utils.clean_output_text(t), "\n"))
            end
        elseif p.type == "image" then
            -- Forcibly upscale the physical resolution of the image BEFORE we insert it into the buffer.
            -- This prevents image.nvim from caching the original tiny dimensions of the file.
            vim.fn.system({"magick", p.filepath, "-trim", "+repage", "-resize", "250%", p.filepath})
            
            M.render_image_output(p.bufnr, p.output_id, p.filepath, "Plot")
        elseif p.type == "html" then
            local raw_html = type(p.html) == "table" and table.concat(p.html, "\n") or p.html
            local config = require("nvim_jupyter.config").options
            
            if config.render_html_as_image then
                local filename = "df_" .. os.time() .. "_" .. math.random(1000, 9999)
                local html_path = "/tmp/" .. filename .. ".html"
                local png_path = "/tmp/" .. filename .. ".html.png"
                
                local html_content = {
                    "<html><head><style>",
                    "body { background: #1e1e2e; color: #cdd6f4; font-family: -apple-system, sans-serif; font-size: 20px; padding: 20px; }",
                    "table { border-collapse: collapse; width: 100%; }",
                    "th, td { border: 1px solid #45475a; padding: 12px; text-align: left; }",
                    "th { background-color: #313244; color: #89b4fa; font-weight: bold; }",
                    "tr:nth-child(even) { background-color: #181825; }",
                    "</style></head><body>",
                    raw_html,
                    "</body></html>"
                }
                
                local f = io.open(html_path, "w")
                if f then
                    f:write(table.concat(html_content, "\n"))
                    f:close()
                end
                
                vim.defer_fn(function()
                    vim.fn.system({"qlmanage", "-t", "-s", "1200", "-o", "/tmp", html_path})
                    vim.fn.system({"magick", png_path, "-trim", "+repage", "-resize", "120%", png_path})
                    
                    M.render_image_output(p.bufnr, p.output_id, png_path, "DataFrame")
                end, 10)
            else
                -- Fallback to plain text, strip basic tags for readability
                local text_content = raw_html:gsub("<[^>]+>", " ")
                text_content = text_content:gsub("%s+", " ")
                append_to_buffer(vim.split(utils.clean_output_text(text_content), "\n"))
            end
        end
        
        vim.schedule(function()
            ui.render_cells(p.bufnr)
        end)
    elseif msg.method == "input_request" then
        local prompt = msg.params.prompt or "Input: "
        vim.schedule(function()
            vim.ui.input({ prompt = prompt }, function(input)
                -- If user cancels (ESC), input is nil. We should send an empty string to unblock the kernel.
                if input == nil then
                    input = ""
                end
                M.send("input_reply", { value = input })
            end)
        end)
    elseif msg.method == "log" then
        vim.notify("Nvim-Jupyter: " .. msg.params.msg, vim.log.levels.INFO)
    end
end

local function on_stdout(_, data, _)
    for _, line in ipairs(data) do
        if line and line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and msg.jsonrpc then
                handle_message(msg)
            else
                -- It might be python printing errors or non-json logs
                -- print("Jupyter Backend: " .. line)
            end
        end
    end
end

function M.start()
    if job_id then
        vim.notify("Jupyter backend is already running.", vim.log.levels.WARN)
        return
    end

    -- Find the python script using Neovim's runtimepath
    local server_path = vim.api.nvim_get_runtime_file("python/server.py", false)[1]
    if not server_path then
        vim.notify("Could not find python/server.py in runtime path. Ensure 'set rtp+=.' is active.", vim.log.levels.ERROR)
        return
    end

    job_id = vim.fn.jobstart({"python3", server_path}, {
        on_stdout = on_stdout,
        on_stderr = function(_, data)
            -- For simplicity we don't spam stderr to the user directly unless needed
        end,
        on_exit = function()
            job_id = nil
            vim.notify("Jupyter backend exited.", vim.log.levels.WARN)
        end,
        stdout_buffered = false,
        stderr_buffered = false,
    })

    if job_id <= 0 then
        vim.notify("Failed to start Jupyter backend.", vim.log.levels.ERROR)
        job_id = nil
    end
end

function M.send(method, params)
    if not job_id then
        M.start()
        -- Brief delay might be needed for the kernel to spin up, but we will send it anyway.
        -- jupyter_client handles queuing messages if the kernel is booting.
    end
    
    if job_id then
        local msg = vim.json.encode({
            jsonrpc = "2.0",
            method = method,
            params = params or {}
        })
        vim.fn.chansend(job_id, msg .. "\n")
    end
end

function M.stop()
    if job_id then
        M.send("stop", {})
        vim.fn.jobstop(job_id)
        job_id = nil
    end
end

return M

