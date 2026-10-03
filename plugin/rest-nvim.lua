---@diagnostic disable: invisible
if vim.fn.has("nvim-0.10.1") ~= 1 then
    vim.notify_once("[rest.nvim] rest.nvim requires at least Neovim >= 0.10.1 in order to work")
    return
end

if vim.g.loaded_rest_nvim then
    return
end

--- Dependencies management ---
-------------------------------
-- This variable is going to hold the dependencies state (whether they are found or not),
-- to be used later by the `health.lua` module
local rest_nvim_deps = {}

-- Locate dependencies
local dependencies = {
    ["fidget.nvim"] = "rest.nvim will be completely unable to show request progress messages",
}
for dep, err in pairs(dependencies) do
    local found_dep2 = pcall(require, "fidget")

    rest_nvim_deps[dep] = {
        found = found_dep2,
        error = err,
    }
    if not found_dep2 then
        vim.notify(
            "WARN: Dependency '" .. dep .. "' was not found. " .. err,
            vim.log.levels.ERROR,
            { title = "rest.nvim" }
        )
    end
end
vim.g.rest_nvim_deps = rest_nvim_deps

require("rest-nvim.autocmds").setup()
require("rest-nvim.commands").setup()
vim.treesitter.language.register("http", "rest_nvim_result")

-- setup highlight groups
require("rest-nvim.ui.highlights")

vim.g.loaded_rest_nvim = true
require("rest-nvim.autocmds").setup()
require("rest-nvim.commands").setup()
vim.treesitter.language.register("http", "rest_nvim_result")

-- setup highlight groups
require("rest-nvim.ui.highlights")

vim.g.loaded_rest_nvim = true
