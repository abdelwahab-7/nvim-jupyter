local M = {}

-- Store active windows so we can close them easily
local active_windows = {}

function M.close_all()
    for _, win in ipairs(active_windows) do
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    active_windows = {}
end

function M.has_active_windows()
	local active_count = 0
    for _, win in ipairs(active_windows) do
        if vim.api.nvim_win_is_valid(win) then
			active_count = active_count + 1
        end
    end
	return active_count > 0
end

-- Helper to create a centered, floating window for outputs
-- lines: table of strings
function M.show_output(lines, user_opts)
	user_opts = user_opts or {}
	local buf = vim.api.nvim_create_buf(false, true)

	-- Set the buffer content
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Optional: try to set filetype to something readable, e.g., output or python
	local filetype = user_opts.filetype or "markdown"
	vim.api.nvim_buf_set_option(buf, "filetype", filetype)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	local max_line_width = 0
	for _, line in ipairs(lines) do
		local line_len = vim.fn.strdisplaywidth(line)
		if line_len > max_line_width then max_line_width = line_len end
	end
	
	local content_width = math.max(20, max_line_width + 2) -- some padding
	local content_height = math.max(1, #lines)

	-- Calculate window size based on editor size
	local width = vim.api.nvim_get_option("columns")
	local height = vim.api.nvim_get_option("lines")
	local win_width = math.min(content_width, math.ceil(width * 0.8))
	local win_height = math.min(content_height, math.ceil(height * 0.8 - 4))

	-- Calculate starting position for centering
	local row = math.ceil((height - win_height) / 2 - 1)
	local col = math.ceil((width - win_width) / 2)

	local title = user_opts.title or " Jupyter Output "

	local opts = {
		style = "minimal",
		relative = "editor",
		width = win_width,
		height = win_height,
		row = row,
		col = col,
		border = "rounded",
		title = title,
		title_pos = "center",
	}

	local win = vim.api.nvim_open_win(buf, false, opts)

	-- Basic styling
	vim.api.nvim_win_set_option(win, "winblend", 0) -- fully opaque to prevent statusline bleeding through
	vim.api.nvim_win_set_option(win, "cursorline", true)
	
	-- Hide any statuslines or winbars that might say [Scratch]
	pcall(function() vim.wo[win].winbar = "" end)
	pcall(function() vim.wo[win].statusline = "" end)

	-- Keymap to close the window easily
	vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<CR>", { noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "<cmd>close<CR>", { noremap = true, silent = true })

	table.insert(active_windows, win)
	return win, buf
end

return M
