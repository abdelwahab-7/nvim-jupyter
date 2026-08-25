local M = {}

-- Main setup function that the user can call in their init.lua
function M.setup(opts)
    opts = opts or {}
    require("nvim_jupyter.config").setup(opts)
    require("nvim_jupyter.core").setup()
    require("nvim_jupyter.ipynb").setup()
    require("nvim_jupyter.ui").setup()
    require("nvim_jupyter.undo_tree").setup()
    require("nvim_jupyter.local_undo").setup()
    require("nvim_jupyter.lsp_bridge").setup()
    -- Auto-quit if the only remaining normal windows are Jupyter sidebars
    vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
            local wins = vim.api.nvim_list_wins()
            local only_sidebars = true
            local has_normal_win = false
            
            for _, w in ipairs(wins) do
                local config = vim.api.nvim_win_get_config(w)
                if config.relative == "" then -- It's a normal window (not floating)
                    has_normal_win = true
                    local buf = vim.api.nvim_win_get_buf(w)
                    local name = vim.api.nvim_buf_get_name(buf)
                    local is_sidebar = name:match("Jupyter Undo Tree") or 
                                       name:match("Jupyter Local Cell Tree") or
                                       name:match("Jupyter Variable Explorer") or
                                       name:match("Jupyter Local Variables")
                                       
                    if not is_sidebar then
                        only_sidebars = false
                        break
                    end
                end
            end
            
            if has_normal_win and only_sidebars then
                vim.cmd("qa!")
            end
        end,
    })
end

return M

