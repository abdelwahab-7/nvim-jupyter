-- lua/nvim_jupyter/config.lua

local M = {}

-- Default configuration values
M.defaults = {
  image = {
    max_width = 0.9,   -- proportion of window width
    max_height = 0.6,  -- proportion of window height
    upscale = true,    -- whether to upscale images (250% as before)
  },
  padding = {
    min_rows = 2,      -- minimum empty lines before/after image
  },
  ui = {
    theme = "dark",    -- "dark" or "light"
    themes = {
      dark = {},
      light = {},
    },
  },
  render_html_as_image = false,    -- use macOS qlmanage to render HTML as image
  clean_tmp_files_on_exit = true,  -- delete /tmp/*.html.png generated images on VimLeave
  lsp_bridge = true,               -- enable URI shim for Jupyter buffers only
  keymaps = {
    run_current_cell = "<leader>rc",
    run_all = "<leader>ra",
    cancel_current_cell = "<leader>kc",
    interrupt_execution = "<leader>ka",
    run_cells_above = "<leader>ru",
    run_cells_below = "<leader>rd",
    add_cell_below = "<leader>bt",
    toggle_variable_explorer = "<leader>ve",
    toggle_local_variables = "<leader>lv",
    toggle_undo_tree = "<leader>ut",
    toggle_local_undo = "<leader>lu",
  },
}

-- Current configuration (populated by setup)
M.options = vim.tbl_deep_extend("force", {}, M.defaults)

--- Merge user supplied options with defaults
function M.setup(user_opts)
  if user_opts == nil then
    return
  end
  -- Deep merge, preserving nested tables
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts)
end

return M

