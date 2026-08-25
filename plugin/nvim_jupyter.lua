if vim.g.loaded_nvim_jupyter == 1 then
    return
end
vim.g.loaded_nvim_jupyter = 1

-- Expose some basic commands for testing the UI
vim.api.nvim_create_user_command("JupyterTestStatus", function(opts)
    require("nvim_jupyter.ui").test_status(opts.args)
end, { nargs = "?" })

vim.api.nvim_create_user_command("JupyterTestFloat", function(opts)
    require("nvim_jupyter.floating").show_output({"Output from jupyter:", "Line 2", opts.args})
end, { nargs = "?" })
