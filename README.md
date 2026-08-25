# 🪐 nvim-jupyter

An interactive, fully-featured Jupyter Notebook client for Neovim. Edit `.ipynb` files directly with seamless kernel integration, inline image rendering, local variable tracking, and built-in undo trees.

![Neovim Version](https://img.shields.io/badge/Neovim-0.10+-blueviolet.svg)
![Python](https://img.shields.io/badge/Python-3.9+-blue.svg)

---

## ⚡ Features

- **Native `.ipynb` Editing**: Work directly inside Jupyter Notebook files without messy conversions.
- **Inline Image Rendering**: View Matplotlib and Seaborn plots natively inside Neovim (powered by `image.nvim`).
- **Interactive Outputs**: Print pandas DataFrames and textual outputs directly below your code cells.
- **Variable Explorer**: A global sidebar to track your workspace variables in real-time.
- **Local Cell Variables**: Isolate and inspect variables specific to the current cell you are editing.
- **Notebook & Cell Undo Trees**: Never lose your work. Powerful undo branches for both the entire notebook and individual cells.
- **LSP Bridge**: Enjoy full Python autocomplete and diagnostics inside notebook cells.

## 📦 Requirements

- **Neovim** 0.10+
- **Python 3**
- `pip install jupyter_client tabulate`
- **ImageMagick** (Required for cropping and scaling plots)
- [image.nvim](https://github.com/3rd/image.nvim) (Optional, but highly recommended for inline graphics)

## 🚀 Installation

Install using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "abdelwahab-7/nvim-jupyter",
    ft = { "jupyter" },
    dependencies = {
        "3rd/image.nvim", -- Optional for inline images
    },
    config = function()
        require("nvim_jupyter").setup({
            -- Add your custom options here
        })
    end
}
```

## ⚙️ Configuration

`nvim-jupyter` works out of the box, but you can override the defaults in the `setup()` function:

```lua
require("nvim_jupyter").setup({
  -- Handle HTML outputs as Images (macOS only, requires qlmanage)
  render_html_as_image = false,

  -- Clean up temporary images in /tmp/ when closing Neovim
  clean_tmp_files_on_exit = true,

  -- Keybindings (these are the defaults)
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
})
```

## 📖 Usage

Simply open a `.ipynb` file in Neovim. The background Python kernel will start automatically.

- Press `<leader>rc` inside a cell to execute it.
- Press `<Esc>` to toggle between **Global Layout View** (navigating cells) and **Local Edit Mode** (editing code inside a cell).

Run `:checkhealth nvim_jupyter` to verify your installation!
