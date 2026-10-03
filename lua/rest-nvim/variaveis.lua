---@mod rest-nvim.variaveis rest.nvim variaveis (environment variables from `variaveis.json`)
---
---@brief [[
---
--- Environment variables selected from `variaveis.json` in Neovim's config
--- directory. Selected values win over dotenv files and |vim.env| when
--- resolving `{{variables}}` in `.http` files and persist between sessions.
---
---@brief ]]

local M = {}

---Special variables shown in the lualine `rest_vars` component
M.ESPECIAIS = { "usuario", "senha", "baseUrl" }

---Currently selected values (`variable -> value`), persisted between sessions
M.selected = {}

---@return string path of the `variaveis.json` source file
function M.json_path()
    return vim.fs.joinpath(vim.fn.stdpath("config") --[[@as string]], "variaveis.json")
end

---@return string path of the persisted selection state file
function M.state_path()
    return vim.fs.joinpath(vim.fn.stdpath("data") --[[@as string]], "rest-nvim.variaveis.json")
end

local function notify_warn(msg)
    vim.notify(msg, vim.log.levels.WARN, { title = "rest.nvim" })
end

---Read and parse the `variaveis.json` source file
---@return table|nil vars parsed variables, `nil` on error
---@return string|nil err error reason: `"missing"`, `"empty"` or `"invalid"`
function M.read()
    local f = io.open(M.json_path(), "r")
    if not f then
        return nil, "missing"
    end
    local content = f:read("*a") or ""
    f:close()
    if not content:match("%S") then
        return nil, "empty"
    end
    local ok, vars = pcall(vim.json.decode, content)
    if not ok or type(vars) ~= "table" then
        return nil, "invalid"
    end
    if vim.tbl_isempty(vars) then
        return nil, "empty"
    end
    return vars, nil
end

---Load the persisted selection into `M.selected`
---Does nothing if the state file does not exist or is invalid
function M.load()
    local f = io.open(M.state_path(), "r")
    if not f then
        return
    end
    local content = f:read("*a") or ""
    f:close()
    if not content:match("%S") then
        return
    end
    local ok, state = pcall(vim.json.decode, content)
    if ok and type(state) == "table" then
        M.selected = state
    end
end

---Persist the current selection to disk
function M.save()
    local f = io.open(M.state_path(), "w")
    if not f then
        notify_warn("Falha ao salvar seleção de variáveis em " .. M.state_path())
        return
    end
    f:write(vim.json.encode(M.selected))
    f:close()
end

---Select a variable with |vim.ui.select()| then one of its values with the
---snacks.nvim picker. Selected values are persisted and win over dotenv
---files and |vim.env| when resolving variables in `.http` files
function M.select()
    local vars, err = M.read()
    if not vars then
        if err == "missing" then
            notify_warn("variaveis.json não encontrado em " .. M.json_path())
        elseif err == "empty" then
            notify_warn("variaveis.json está vazio")
        else
            notify_warn("variaveis.json inválido")
        end
        return
    end
    vim.ui.select(vim.tbl_keys(vars), {
        prompt = "Selecione a variável",
    }, function(name)
        if not name then
            return
        end
        local entries = vars[name]
        if type(entries) ~= "table" or vim.tbl_isempty(entries) then
            notify_warn("Sem valores para a variável '" .. name .. "'")
            return
        end
        local snacks_ok, snacks = pcall(require, "snacks")
        if not snacks_ok or type(snacks) ~= "table" or type(snacks.picker) ~= "table" then
            notify_warn("snacks.nvim é necessário para selecionar valores")
            return
        end
        local items = {}
        for k, v in pairs(entries) do
            table.insert(items, { key = tostring(k), value = tostring(v) })
        end
        table.sort(items, function(a, b)
            return a.key < b.key
        end)
        snacks.picker.select(items, {
            prompt = "Valor para '" .. name .. "'",
            format_item = function(e)
                return e.key .. ": " .. e.value
            end,
        }, function(choice)
            if not choice then
                return
            end
            M.selected[name] = choice.value
            M.save()
            pcall(function()
                require("lualine").refresh()
            end)
        end)
    end)
end

---Show the currently selected variables in a notification
function M.list()
    if vim.tbl_isempty(M.selected) then
        notify_warn("Nenhuma variável selecionada")
        return
    end
    local names = vim.tbl_keys(M.selected)
    table.sort(names)
    vim.notify(
        table.concat(
            vim.tbl_map(function(k)
                return k .. "=" .. tostring(M.selected[k])
            end, names),
            "\n"
        ),
        vim.log.levels.INFO,
        { title = "rest.nvim" }
    )
end

M.load()

return M
