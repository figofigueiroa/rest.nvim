---@mod rest-nvim.client.curl.cli rest.nvim cURL cli client
---
---@brief [[
---
--- rest.nvim cURL cli client implementation
--- heavily inspired by plenary.nvim
---
---@brief ]]

local curl = {}

local log = require("rest-nvim.logger")
local curl_utils = require("rest-nvim.client.curl.utils")
local utils = require("rest-nvim.utils")
local config = require("rest-nvim.config")
local async = vim.async or require("async")

-- Progress reporting.
-- noice.nvim does not provide a public progress API, but its `mini` view
-- renders `lsp`/`progress` messages (the same view noice uses for LSP
-- progress, similar to fidget.nvim). When noice is available and running, we
-- create such messages directly and keep them visible while the request is
-- running, following the same `opts.keep` + `Manager` pattern used by noice's
-- own `lsp/docs.lua`. Otherwise falls back to `vim.notify` (which noice
-- itself renders when installed).
local progress

---@param msg string|{message:string}
---@return string?
local function msgstr(msg)
    if type(msg) == "table" then
        return msg.message
    end
    return msg
end

local ok, Message, Manager, Router, Format, Config = pcall(function()
    return require("noice.message"), require("noice.message.manager"), require("noice.message.router"),
        require("noice.text.format"), require("noice.config")
end)

---@param opts {title?: string, message?: string}
---@return {report: fun(_, string|table), finish: fun(), cancel: fun()}
local function create_noice(opts)
    local running = true
    local message = Message("lsp", "progress")
    message.opts.progress = {
        client = "rest.nvim",
        title = opts.title or "Executing",
        message = opts.message or "Executing request...",
    }
    message.opts.keep = function()
        return running
    end
    local function push(format)
        format = format
            or vim.tbl_get(Config, "options", "lsp", "progress", "format")
            or "lsp_progress"
        pcall(function()
            Manager.add(Format.format(message, format))
        end)
    end
    push()
    return {
        report = function(_, msg)
            msg = msgstr(msg)
            if msg then
                message.opts.progress.message = msg
                push()
            end
        end,
        finish = function(_)
            message.opts.progress.message = nil
            running = false
            push(vim.tbl_get(Config, "options", "lsp", "progress", "format_done") or "lsp_progress_done")
            pcall(Router.update)
            pcall(Manager.remove, message)
        end,
        cancel = function(_)
            running = false
            pcall(Manager.remove, message)
        end,
    }
end

progress = {
    ---Create a progress message, displayed by noice's `mini` view when noice
    ---is running, or through `vim.notify` otherwise
    ---@param opts? {title?: string, message?: string}
    ---@return {report: fun(_, string|table), finish: fun(), cancel: fun()}
    create = function(opts)
        opts = opts or {}
        if ok and Config.is_running() then
            local noice_ok, handle = pcall(create_noice, opts)
            if noice_ok then
                return handle
            end
            log.warn("failed to create noice progress message:", handle)
        end
        local title = opts.title or "rest.nvim"
        local function notify(msg)
            msg = msgstr(msg)
            if msg then
                vim.notify(msg, vim.log.levels.INFO, { title = title })
            end
        end
        notify(opts.message)
        return {
            report = function(_, msg)
                notify(msg)
            end,
            finish = function() end,
            cancel = function() end,
        }
    end,
}

---@type fun(cmd: string[], opts, vim.SystemOpts?): vim.SystemCompleted
local system = async.wrap(3, vim.system)
---@type fun()
local schedule = async.wrap(1, vim.schedule)

---@async
---@see vim.system
---@param args string[] curl CLI arguments
---@param opts? vim.SystemOpts
---@return vim.SystemCompleted
---@package
function curl.cli(args, opts)
    opts = opts or {}
    opts.detach = false
    opts.text = true
    -- TODO(boltless): parse by chunk using `--trace-ascii %`
    local curl_cmd = { "curl", "-sL", "-v" }
    curl_cmd = vim.list_extend(curl_cmd, args)
    log.info(curl_cmd)
    opts.detach = false
    local ok, out_or_err = pcall(system, curl_cmd, opts)
    if not ok then
        ---@type vim.SystemCompleted
        local out = {
            code = 99999,
            signal = 0,
            stderr = "Failed to invoke curl: " .. out_or_err,
        }
        return out
    end

    -- TODO(TheLeoP): probably should left this to the caller just like `vim.system`
    schedule()
    return out_or_err
end

---@private
local parser = {}

---@package
---@param str string
---@return rest.Response.status
function parser.parse_verbose_status(str)
    local version, code, text = str:match("^(%S+) (%d+) ?(.*)")
    return {
        version = version,
        code = tonumber(code),
        text = text,
    }
end

---@package
---@param str string
---@return string? key
---@return string? value
function parser.parse_header_pair(str)
    local key, value = str:match("(%S+):(.*)")
    if not key then
        return
    end
    return key:lower(), vim.trim(value)
end

---@package
---@param line string
---@return {prefix:string,str:string?}|nil
function parser.parse_verbose_line(line)
    local prefix, str = line:match("(.) ?(.*)")
    if not prefix then
        log.error("Error while parsing verbose curl output:\n" .. line)
        return
    end
    return {
        prefix = prefix,
        str = str,
    }
end

local _VERBOSE_PREFIX_META = "*"
local _VERBOSE_PREFIX_REQ_HEADER = ">"
local _VERBOSE_PREFIX_REQ_BODY = "}"
local VERBOSE_PREFIX_RES_HEADER = "<"
-- NOTE: we don't parse response body with trace output. response body will
-- be sent to `stdout` instead of `stderr`
local _VERBOSE_PREFIX_RES_BODY = "{"
---custom prefix for statistics
local VERBOSE_PREFIX_STAT = "?"

---@package
---@param str string
function parser.parse_stat_pair(str)
    local key, value = str:match("(%S+):(.*)")
    if not key then
        return
    end
    value = vim.trim(value)
    if key:find("size") and tonumber(value) then
        log.debug("transforming stat pair as size:", key, value)
        value = utils.transform_size(value)
    elseif key:find("time") and tonumber(value) then
        log.debug("transforming stat pair as time:", key, value)
        value = utils.transform_time(value)
    end
    return key, value
end

---@param lines string[]
---@return rest.Response
function parser.parse_verbose(lines)
    ---@type rest.Response[]
    local list = {}
    ---@type rest.Response
    local response
    vim.iter(lines):map(parser.parse_verbose_line):each(function(ln)
        if ln.prefix == VERBOSE_PREFIX_RES_HEADER then
            if vim.startswith(ln.str, "HTTP/") then
                response = {
                    status = parser.parse_verbose_status(ln.str),
                    headers = {},
                    statistics = {},
                }
                table.insert(list, response)
            else
                -- response header
                local key, value = parser.parse_header_pair(ln.str)
                if key then
                    if not response.headers[key] then
                        response.headers[key] = {}
                    end
                    table.insert(response.headers[key], value)
                end
            end
        elseif response and ln.prefix == VERBOSE_PREFIX_STAT then
            local key, value = parser.parse_stat_pair(ln.str)
            if key then
                response.statistics[key] = value
            end
        end
    end)
    -- TODO: return all response history
    return list[#list]
end

--- Builder ---

---@param kv table<string,string>
---@return string[]
local function kv_to_list(kv, prefix, sep)
    local tbl = {}
    for key, value in pairs(kv) do
        table.insert(tbl, prefix)
        table.insert(tbl, key .. sep .. value)
    end
    return tbl
end

---@private
local builder = {}

---@param req rest.Request
---@return string[] args
function builder.extras(req)
    local args = {}
    if config.clients.curl.opts.set_compressed then
        if
            vim.iter(req.headers):any(function(key, values)
                return key == "accept-encoding"
                    and vim.iter(values):any(function(value)
                        return value:find("gzip")
                    end)
            end)
        then
            vim.list_extend(args, { "--compressed" })
        end
    end
    --
    for domain, _ in pairs(config.clients.curl.opts.certificates) do
        local target = req.url

        -- TODO(boltless): this is temporary solution. use same logic from cookie_jar instead
        local s, _ = string.find(target, domain, 1, true)

        if s ~= nil then
            vim.list_extend(args, { "--cert", config.clients.curl.opts.certificates[domain].set_certificate_crt })
            vim.list_extend(args, { "--key", config.clients.curl.opts.certificates[domain].set_certificate_key })
            break
        end
    end

    return args
end

---@param method string
---@return string[] args
function builder.method(method)
    if method ~= "head" then
        return { "-X", string.upper(method) }
    else
        return { "-I" }
    end
end

---@package
---@param header table<string,string[]>
---@return string[] args
function builder.headers(header)
    local args = {}
    local upper = function(str)
        return string.gsub(" " .. str, "%W%l", string.upper):sub(2)
    end
    for key, values in pairs(header) do
        for _, value in ipairs(values) do
            vim.list_extend(args, { "-H", upper(key) .. ": " .. value })
        end
    end
    return args
end

---@param cookies rest.Cookie[]
---@return string[] args
function builder.cookies(cookies)
    return vim.iter(cookies)
        :map(function(cookie)
            return { "-b", cookie.name .. "=" .. cookie.value }
        end)
        :totable()
end

---@param body string?
---@return string[]? args
function builder.raw_body(body)
    if not body then
        return
    end
    return { "--data-raw", body }
end

---@package
---@param body table<string,string>?
---@return string[]? args
function builder.data_body(body)
    if not body then
        return
    end
    return kv_to_list(body, "-d", "=")
end

function builder.file(file)
    if not file then
        return
    end
    -- FIXME: should normalize/expand the file path
    return { "--data-binary", "@" .. file }
end

---@package
---@param version string
---@return string[]? args
function builder.http_version(version)
    vim.validate({
        version = {
            version,
            function(v)
                return not v or vim.list_contains({ "HTTP/0.9", "HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/3" }, v)
            end,
        },
    })
    if not version then
        return
    end
    return { "--" .. version:lower():gsub("/", "") }
end

---@return string[]? args
function builder.statistics()
    if vim.tbl_isempty(config.clients.curl.statistics) then
        return
    end
    local format = vim.iter(config.clients.curl.statistics)
        :map(function(style)
            return ("? %s:%%{%s}\n"):format(style.id, style.id)
        end)
        :join("")
    return { "-w", "%{stderr}" .. format }
end

---@package
builder.STAT_ARGS = builder.statistics()

---build curl request arguments based on Request object
---@param req rest.Request
---@param ignore_stats? boolean
---@return string[] args
function builder.build(req, ignore_stats)
    local args = {}
    ---@param list table
    ---@param value any
    local function insert(list, value)
        if value then
            table.insert(list, value)
        end
    end
    insert(args, req.url)
    insert(args, builder.extras(req))
    insert(args, builder.method(req.method))
    insert(args, builder.headers(req.headers))
    insert(args, builder.cookies(req.cookies))
    if req.body then
        if req.body.__TYPE == "external" then
            if req.body.data.content then
                insert(args, builder.raw_body(req.body.data.content))
            else
                insert(args, builder.file(req.body.data.path))
            end
        elseif req.body.__TYPE == "multipart_form_data" then
            log.error("multipart-form-data body is not supportted yet")
        elseif vim.list_contains({ "json", "xml", "raw", "graphql" }, req.body.__TYPE) then
            insert(args, builder.raw_body(req.body.data))
        else
            log.error(("unkown body type: '%s'"):format(req.body.__TYPE))
        end
    end
    if config.request.skip_ssl_verification then
        insert(args, "-k")
    end
    -- TODO: auth?
    insert(args, builder.http_version(req.http_version) or {})
    if not ignore_stats then
        insert(args, builder.STAT_ARGS)
    end
    return vim.iter(args):flatten(math.huge):totable()
end

---Generate curl command equivelant to given request.
---This command doesn't include verbose/trace options
---@param req rest.Request
function builder.build_command(req)
    local base_cmd = "curl -sL"
    local args = vim.iter(builder.build(req, true)):map(function(a)
        return vim.fn.shellescape(a)
    end)
    return base_cmd .. " " .. args:join(" ")
end

---@async
---Send request via `curl` cli
---@param request rest.Request Request data to be passed to cURL
---@return rest.Response
function curl.request(request)
    local progress_handle = progress.create({
        title = "Executing",
        message = "Executing request...",
    })
    local args = builder.build(request)
    local sc = curl.cli(args)
    if sc.code ~= 0 then
        local message = "Something went wrong when making the request with cURL:\n" .. curl_utils.curl_error(sc.code)
        progress_handle:cancel()
        log.error(message)
        error(message)
    end

    progress_handle:report({ message = "Parsing response..." })
    local response = parser.parse_verbose(vim.split(sc.stderr, "\n", { trimempty = true }))
    response.body = sc.stdout
    progress_handle:report({ message = "Success" })
    progress_handle:finish()
    return response
end

curl.builder = builder
curl.parser = parser

return curl
