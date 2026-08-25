local M = {}

-- Cleans terminal control sequences from text to make it suitable for a Neovim buffer
function M.clean_output_text(text)
    if not text then return "" end
    
    -- 1. Strip ANSI escape sequences (colors, cursor movements like \x1b[2K, \x1b[?25l)
    -- Pattern matches \x1b (27) followed by [ and any number of characters until a letter
    text = text:gsub("\27%[[%d;?]*[a-zA-Z]", "")
    
    -- 2. Process carriage returns (\r). Usually used for progress bars to overwrite the line.
    -- We can simulate this by taking the last segment after \r, unless \r is followed by \n.
    -- First, temporarily change \r\n to \n so we don't destroy real newlines
    text = text:gsub("\r\n", "\n")
    
    local lines = vim.split(text, "\n", { plain = true })
    local processed_lines = {}
    
    for _, line in ipairs(lines) do
        -- For each line, if it has \r, take the part after the last \r
        -- (This is a simplified emulation of carriage return for progress bars)
        if line:find("\r") then
            -- Find the last \r
            local parts = vim.split(line, "\r", { plain = true })
            line = parts[#parts]
        end
        
        -- 3. Process backspaces (\b). 
        -- Keep resolving 'char + \b' until no \b is left
        while line:find("\b") do
            -- Pattern: capture any single char (not \b) followed by \b, and remove both
            local prev = line
            line = line:gsub("[^\b]\b", "")
            if line == prev then
                -- if we have \b at the very start of line, just remove it
                line = line:gsub("^\b+", "")
                if line == prev then break end
            end
        end
        
        table.insert(processed_lines, line)
    end
    
    return table.concat(processed_lines, "\n")
end

function M.set_lines_no_undo(buf, start_idx, end_idx, strict, lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local old_ul = vim.bo[buf].undolevels
    vim.bo[buf].undolevels = -1
    vim.api.nvim_buf_set_lines(buf, start_idx, end_idx, strict, lines)
    vim.bo[buf].undolevels = old_ul
end

return M
