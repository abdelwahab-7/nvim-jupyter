local health = vim.health or require("health")

local M = {}

function M.check()
    health.start("nvim-jupyter-plugin environment")
    
    -- Check Python3
    if vim.fn.executable("python3") == 1 then
        health.ok("python3 is installed")
    else
        health.error("python3 is not installed. Required to run the background kernel.")
    end
    
    -- Check jupyter_client
    vim.fn.system({"python3", "-c", "import jupyter_client"})
    if vim.v.shell_error == 0 then
        health.ok("jupyter_client is installed")
    else
        health.error("jupyter_client Python package is not installed.", {"Run: pip install jupyter_client"})
    end

    -- Check pandas & tabulate (optional but recommended for table rendering)
    vim.fn.system({"python3", "-c", "import pandas; import tabulate"})
    if vim.v.shell_error == 0 then
        health.ok("pandas & tabulate are installed for dataframe rendering")
    else
        health.warn("pandas or tabulate are missing. DataFrame rendering might fallback to raw text.", {"Run: pip install pandas tabulate"})
    end

    -- Check ImageMagick
    if vim.fn.executable("magick") == 1 then
        health.ok("ImageMagick (magick) is installed")
    else
        health.warn("ImageMagick (magick) not found.", {"Required to perfectly crop and scale matplotlib plots.", "Install via Homebrew: brew install imagemagick"})
    end

    -- Check image.nvim
    local has_image, _ = pcall(require, "image")
    if has_image then
        health.ok("3rd/image.nvim is installed")
    else
        health.warn("3rd/image.nvim is not installed.", {"Install image.nvim to enable rich inline plots and graphics inside Neovim."})
    end
end

return M
