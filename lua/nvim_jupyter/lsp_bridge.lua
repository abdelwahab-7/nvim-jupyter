local M = {}

function M.setup()
    -- Intercept Neovim's internal URI generation to seamlessly trick Python LSPs
    local orig_uri_from_bufnr = vim.uri_from_bufnr
    vim.uri_from_bufnr = function(bufnr)
        local uri = orig_uri_from_bufnr(bufnr)
        if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].is_jupyter then
            -- Pretend the notebook is actually a python script so Pyright parses it fully without JSON errors
            if uri:match("%.ipynb$") then
                return uri:gsub("%.ipynb$", ".py")
            end
        end
        return uri
    end
    
    local orig_uri_to_bufnr = vim.uri_to_bufnr
    vim.uri_to_bufnr = function(uri)
        if type(uri) == "string" and uri:match("%.py$") then
            -- If the LSP sends a request/diagnostic for the fake .py file, map it back to the real notebook buffer
            local ipynb_uri = uri:gsub("%.py$", ".ipynb")
            local bufnr = orig_uri_to_bufnr(ipynb_uri)
            if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].is_jupyter then
                return bufnr
            end
        end
        return orig_uri_to_bufnr(uri)
    end
end

return M

