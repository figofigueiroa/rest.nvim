---@mod rest-nvim.health rest.nvim healthcheck
---
---@brief [[
---
---Healthcheck module for rest.nvim
---
---@brief ]]

local health = {}

local function formatter_health()
    vim.health.start("Response body formatters")

    -- Formatter checking
    for _, ft in ipairs({ "json", "xml", "html" }) do
        local formatexpr = vim.api.nvim_get_option_value("formatexpr", { filetype = ft })
        local formatprg = vim.api.nvim_get_option_value("formatprg", { filetype = ft })
        if formatexpr == "" and formatprg == "" then
            vim.health.warn("Options 'formatexpr' or 'formatprg' are not set for " .. ft .. " filetype")
        else
            if formatexpr ~= "" then
                vim.health.ok(("Option 'formatexpr' is set to `%s` for %s filetype"):format(formatexpr, ft))
            else
                vim.health.ok(("Option 'formatprg' is set to `%s` for %s filetype"):format(formatexpr, ft))
            end
        end
    end
    vim.health.info("You can set formatter for each filetype via 'formatexpr' or 'formatprg' option")
end

local function variaveis_health()
    vim.health.start("Environment variables (`variaveis.json`)")

    -- snacks.nvim is needed by `:Rest vars select`
    local snacks_ok, snacks = pcall(require, "snacks")
    if snacks_ok and type(snacks) == "table" and type(snacks.picker) == "table" then
        vim.health.ok("snacks.nvim found, `:Rest vars select` picker available")
    else
        vim.health.warn("snacks.nvim not found, `:Rest vars select` needs it to pick values")
    end

    local variaveis = require("rest-nvim.variaveis")
    local _, err = variaveis.read()
    if err == nil then
        vim.health.ok("variaveis.json found at " .. variaveis.json_path())
    elseif err == "missing" then
        vim.health.info("variaveis.json not found at " .. variaveis.json_path() .. " (optional)")
    elseif err == "empty" then
        vim.health.warn("variaveis.json is empty")
    else
        vim.health.warn("variaveis.json is not valid JSON")
    end
end

function health.check()
    formatter_health()
    variaveis_health()
end

return health
