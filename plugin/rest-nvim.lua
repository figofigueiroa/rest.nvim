---@diagnostic disable: invisible
if vim.fn.has("nvim-0.10.1") ~= 1 then
    vim.notify_once("[rest.nvim] rest.nvim requires at least Neovim >= 0.10.1 in order to work")
    return
end

if vim.g.loaded_rest_nvim then
    return
end

require("rest-nvim.autocmds").setup()
require("rest-nvim.commands").setup()
vim.treesitter.language.register("http", "rest_nvim_result")

-- setup highlight groups
require("rest-nvim.ui.highlights")

vim.g.loaded_rest_nvim = true
