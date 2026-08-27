local M = {}
local ns_id = vim.api.nvim_create_namespace("nvim_jupyter_ui")

_G.JupyterStatusColumn = function()
    -- Do not print line numbers for virtual lines (wrapped lines or bottom borders)
    if vim.v.virtnum ~= 0 then
        return "%s  "
    end

    local buf = vim.api.nvim_get_current_buf()
    if not vim.b[buf].is_jupyter then
        return "%s%=%l "
    end
    
    local state = vim.b[buf].jupyter_state or "global"
    if state == "global" then
        return "%s  "
    end
    
    local active_cell = vim.b[buf].jupyter_active_cell
    if not active_cell then return "%s  " end
    
    local lnum = vim.v.lnum - 1
    -- Inside local cell, print 1-indexed relative line number
    if lnum > active_cell.start_line and lnum <= active_cell.end_line then
        local cell_line = lnum - active_cell.start_line
        return "%s%=" .. cell_line .. " "
    end
    
    return "%s  "
end

-- Setup highlight groups
vim.cmd([[
    highlight JupyterBorderActive guifg=#89B4FA gui=bold
    highlight JupyterBorderInactive guifg=#45475A
    
    highlight JupyterStatusPending guifg=#F5C2E7
    highlight JupyterStatusRunning guifg=#89B4FA gui=bold
    highlight JupyterStatusSuccess guifg=#A6E3A1
    highlight JupyterStatusError   guifg=#F38BA8 gui=bold
    
    highlight JupyterOutput        guifg=#A6ADC8 gui=NONE
    highlight JupyterActiveCell    guibg=#2A2B3D
]])

local spinners = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_frame = 1
local spinner_timer = nil

function M.start_spinner()
    if spinner_timer then return end
    spinner_timer = vim.loop.new_timer()
    spinner_timer:start(0, 80, vim.schedule_wrap(function()
        spinner_frame = (spinner_frame % #spinners) + 1
        local has_running = false
        local core = require("nvim_jupyter.core")
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].is_jupyter then
                local found = false
                for track_id, _ in pairs(core.execution_timers) do
                    if not core.execution_durations[track_id] then
                        found = true
                        break
                    end
                end
                if found then
                    has_running = true
                    M.render_cells(buf)
                end
            end
        end
        if not has_running then
            M.stop_spinner()
        end
    end))
end

function M.stop_spinner()
    if spinner_timer then
        spinner_timer:stop()
        spinner_timer:close()
        spinner_timer = nil
    end
end

function M.render_cells(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].is_jupyter then return end

    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cells = {}
    local current_cell = nil
    
    for i, line in ipairs(lines) do
        if line:match("^# %%%%") then
            if current_cell then
                current_cell.end_line = i - 2
                table.insert(cells, current_cell)
            end
            local is_markdown = line:match("^# %%%% %[markdown%]") ~= nil
            local is_output = line:match("^# %%%% %[output%]") ~= nil
            
            current_cell = {
                start_line = i - 1,
                is_markdown = is_markdown,
                is_output = is_output
            }
            
            if is_output and #cells > 0 then
                current_cell.parent_start = cells[#cells].start_line
            end
        elseif i == 1 and not line:match("^# %%%%") then
            -- Implicit first cell
            current_cell = {
                start_line = 0,
                implicit = true,
                is_markdown = false,
                is_output = false
            }
        end
    end
    
    if current_cell then
        current_cell.end_line = #lines - 1
        table.insert(cells, current_cell)
    end
    
    local ui_state = {}
    local active_line = -1
    local width = vim.api.nvim_get_option("columns") - 5 -- Default fallback width
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then
            local wininfo = vim.fn.getwininfo(w)[1]
            width = wininfo.width - wininfo.textoff
            if vim.api.nvim_get_current_win() == w then
                active_line = vim.api.nvim_win_get_cursor(w)[1] - 1
            end
            break
        end
    end
    
    local cell_index = 1
    
    for i, cell in ipairs(cells) do
        local is_active = (active_line >= cell.start_line and active_line <= cell.end_line)
        local hl = is_active and "JupyterBorderActive" or "JupyterBorderInactive"
        
        if is_active then
            vim.b[bufnr].jupyter_active_cell = { start_line = cell.start_line, end_line = cell.end_line }
        end
        
        if not cell.implicit and not cell.is_output then
            cell.index = cell_index
            cell_index = cell_index + 1
        elseif cell.is_output then
            cell.index = cell_index - 1
        end
        
        local core = require("nvim_jupyter.core")
        local track_id = nil
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, core.track_ns, {cell.start_line, 0}, {cell.start_line, -1}, {})
        if marks and #marks > 0 then
            track_id = marks[1][1]
        end
        
        -- Execution status
        local stat = "pending"
        if track_id then
            if core.execution_timers[track_id] and not core.execution_durations[track_id] then
                stat = "running"
            elseif core.execution_durations[track_id] then
                stat = core.execution_durations[track_id].status
            end
        end
        
        local stat_icon = ""
        local stat_hl = "JupyterStatusPending"
        if stat == "running" then
            stat_icon = " " .. spinners[spinner_frame] .. " "
            stat_hl = "JupyterStatusRunning"
            M.start_spinner()
        end
        
        -- Style output borders dynamically
        if cell.is_output then
            local parent_stat = stat
            if cell.parent_start and cell.parent_start ~= cell.start_line then
                parent_stat = "pending"
                local p_marks = vim.api.nvim_buf_get_extmarks(bufnr, core.track_ns, {cell.parent_start, 0}, {cell.parent_start, -1}, {})
                if p_marks and #p_marks > 0 then
                    local pid = p_marks[1][1]
                    if core.execution_timers[pid] and not core.execution_durations[pid] then
                        parent_stat = "running"
                    elseif core.execution_durations[pid] then
                        parent_stat = core.execution_durations[pid].status
                    end
                end
            end
            
            if parent_stat == "success" then
                hl = "JupyterStatusSuccess"
            elseif parent_stat == "error" then
                hl = "JupyterStatusError"
            elseif parent_stat == "running" then
                hl = "JupyterStatusRunning"
            end
        end

        local title = ""
        if not cell.implicit then
            if cell.is_output then
                title = " [" .. cell.index .. "] Output "
            else
                title = cell.is_markdown and (" [" .. cell.index .. "] Markdown ") or (" [" .. cell.index .. "] Code ")
            end
        end
        
        local target_width = width - 1
        
        -- Build the top border explicitly as chunks to prevent right_align overlap
        local virt_chunks = {}
        if not cell.implicit then
            local title_len = vim.fn.strdisplaywidth(title)
            local stat_len = cell.is_output and 0 or vim.fn.strdisplaywidth(stat_icon)
            
            local padding_len = target_width - 6 - title_len - stat_len
            if padding_len < 0 then padding_len = 0 end
            
            if cell.is_output then
                virt_chunks = {
                    {"╰─▶" .. title .. string.rep("─", padding_len) .. "─", hl},
                    {"─╮", hl}
                }
            else
                virt_chunks = {
                    {"╭──" .. title .. string.rep("─", padding_len) .. "─", hl},
                    {stat_icon, stat_hl},
                    {"─╮", hl}
                }
            end
        end
        
        -- Top Border (overlay the # %%)
        if not cell.implicit then
            local extmark_opts = {
                virt_text = virt_chunks,
                virt_text_pos = "overlay",
            }
            if not cell.is_output then
                extmark_opts.sign_text = "│ "
                extmark_opts.sign_hl_group = hl
            end
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, cell.start_line, 0, extmark_opts)
        end
        
        -- Left borders for contents
        local content_start = cell.implicit and cell.start_line or (cell.start_line + 1)
        for l = content_start, cell.end_line do
            if not cell.is_output then
                vim.api.nvim_buf_set_extmark(bufnr, ns_id, l, 0, {
                    sign_text = "│ ",
                    sign_hl_group = hl,
                    hl_group = is_active and "JupyterActiveCell" or nil,
                    hl_eol = true,
                })
            else
                vim.api.nvim_buf_add_highlight(bufnr, ns_id, "JupyterOutput", l, 0, -1)
            end
        end
        
        -- Bottom Border (virt_lines below the last line)
        local bottom_border_char = "╰"
        if not cell.is_output and i < #cells and cells[i+1].is_output then
            bottom_border_char = "├"
        end
        local bottom_border = bottom_border_char .. string.rep("─", target_width - 2) .. "╯"
        
        local virt_lines_chunks = {{ bottom_border, hl }}
        
        if cell.is_output then
            local parent_is_active = (active_line >= cell.parent_start and active_line <= cell.end_line)
            
            if parent_is_active then
                local core = require("nvim_jupyter.core")
                local start_time = nil
                local duration_data = nil
                
                local marks = vim.api.nvim_buf_get_extmarks(bufnr, core.track_ns, {cell.parent_start, 0}, {cell.parent_start, -1}, {})
                if marks and #marks > 0 then
                    local track_id = marks[1][1]
                    start_time = core.execution_timers[track_id]
                    duration_data = core.execution_durations[track_id]
                end
                
                local tag = nil
                local tag_hl = "String"
                
                if start_time and not duration_data then
                    tag = " In [*] "
                    tag_hl = "WarningMsg"
                elseif duration_data then
                    local dur = duration_data.duration or duration_data.time or 0
                    if duration_data.status == "error" then
                        tag = string.format(" In [✗] (%.1fs) ", dur)
                        tag_hl = "ErrorMsg"
                    else
                        tag = string.format(" In [✓] (%.1fs) ", dur)
                        tag_hl = "String"
                    end
                end
                
                if tag then
                    local tag_len = vim.fn.strdisplaywidth(tag)
                    local base_len = target_width - 1 - tag_len
                    if base_len > 0 then
                        local left_part = bottom_border_char .. string.rep("─", base_len - 1)
                        virt_lines_chunks = {
                            { left_part, hl },
                            { tag, tag_hl },
                            { "╯", hl }
                        }
                    end
                end
            end
        end
        
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, cell.end_line, 0, {
            virt_lines = { virt_lines_chunks },
            virt_lines_above = false,
        })
    end
end

function M.setup()
    local group = vim.api.nvim_create_augroup("NvimJupyterUIRender", { clear = true })
    
    -- Auto-render when text changes or cursor moves
    vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI", "CursorMoved", "CursorMovedI", "BufEnter"}, {
        group = group,
        pattern = "*",
        callback = function(args)
            M.render_cells(args.buf)
        end
    })
end

-- A dummy function to test the UI easily
function M.test_status(status)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1] - 1
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_cell_status(bufnr, line_num, status or "running", "1")
end

return M

