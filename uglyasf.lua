local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")

local genv = (getgenv and getgenv()) or _G

local Gecko = {}
Gecko.__index = Gecko

Gecko.sessionId    = HttpService:GenerateGUID(false)
Gecko.state        = { client_status = "running" }
Gecko.coordination = nil
Gecko.handlers     = {}
Gecko.token        = nil
Gecko.interval     = 5
Gecko.config       = nil
Gecko._running     = false
Gecko._loopThread  = nil
Gecko._http        = nil

local DEFAULT_TOKEN_DIR = "gecko"

local function resolvePlayer()
    local player = Players.LocalPlayer
    while not player do
        task.wait(0.25)
        player = Players.LocalPlayer
    end
    return player
end

local function encodeBody(value)
    if value == nil or (type(value) == "table" and next(value) == nil) then
        return "{}"
    end
    return HttpService:JSONEncode(value)
end

local function resolveHttp(fn)
    if fn then return fn end
    return (syn and syn.request)
        or http_request
        or request
        or (http and http.request)
        or (fluxus and fluxus.request)
        or (krnl and krnl.request)
end

local function defaultLog(...)
    print("[Gecko]", ...)
end

local function validateConfig(cfg)
    assert(type(cfg) == "table", "Gecko.start: config table required")

    local apiUrl = cfg.apiUrl
    assert(type(apiUrl) == "string" and apiUrl ~= "", "Gecko.start: apiUrl is required")
    if apiUrl:sub(-1) == "/" then
        apiUrl = apiUrl:sub(1, -2)
    end
    assert(apiUrl:match("^https?://"), "Gecko.start: apiUrl must start with http:// or https://")

    local token         = cfg.token
    local enrollmentKey = cfg.enrollmentKey
    if token ~= nil and token ~= "" then
        assert(type(token) == "string", "Gecko.start: token must be a string")
    else
        token = nil
    end
    if enrollmentKey ~= nil and enrollmentKey ~= "" then
        assert(type(enrollmentKey) == "string", "Gecko.start: enrollmentKey must be a string")
    else
        enrollmentKey = nil
    end
    if not token and not enrollmentKey then
        error("Gecko.start: need either 'token' or 'enrollmentKey'", 2)
    end

    return {
        apiUrl          = apiUrl,
        token           = token,
        enrollmentKey   = enrollmentKey,
        groupId         = cfg.groupId,
        defaultInterval = tonumber(cfg.defaultInterval) or 5,
        tokenDir        = type(cfg.tokenDir) == "string" and cfg.tokenDir or DEFAULT_TOKEN_DIR,
        httpFn          = cfg.httpFn,
        logFn           = cfg.logFn or defaultLog,
        reconfigure     = cfg.reconfigure == true,
    }
end

function Gecko:_httpCall(method, path, token, body)
    local http = self._http
    if not http then return nil, "no http function" end
    local ok, res = pcall(http, {
        Url = self.config.apiUrl .. path,
        Method = method,
        Headers = {
            ["Content-Type"]  = "application/json",
            ["Authorization"] = token and ("Bearer " .. token) or nil,
        },
        Body = (method ~= "GET") and encodeBody(body) or nil,
    })
    if not ok or type(res) ~= "table" then
        return nil, "network error: " .. tostring(res)
    end
    local decoded
    if res.Body and #res.Body > 0 then
        pcall(function() decoded = HttpService:JSONDecode(res.Body) end)
    end
    return res.StatusCode, decoded
end

function Gecko:_tokenFilePath()
    local player = resolvePlayer()
    return self.config.tokenDir .. "/" .. tostring(player.UserId) .. ".token"
end

function Gecko:_readSavedToken()
    local path = self:_tokenFilePath()
    if isfile and isfile(path) then
        local saved = readfile(path):gsub("%s+", "")
        if saved ~= "" then return saved end
    end
    return nil
end

function Gecko:_saveToken(token)
    if not writefile then return end
    local dir = self.config.tokenDir
    if makefolder and isfolder and not isfolder(dir) then
        pcall(makefolder, dir)
    end
    pcall(writefile, self:_tokenFilePath(), token)
end

function Gecko:_register()
    local player = resolvePlayer()
    if not self.config.enrollmentKey then
        self:_log("No saved token and no enrollmentKey; cannot register " .. player.Name)
        return nil
    end
    local status, data = self:_httpCall("POST", "/accounts/register", self.config.enrollmentKey, {
        username       = player.Name,
        roblox_user_id = player.UserId,
        group_id       = self.config.groupId,
    })
    if status == 201 and data and data.token then
        self:_saveToken(data.token)
        self:_log("Registered " .. player.Name .. " as account " .. tostring(data.account and data.account.id))
        return data.token
    end
    if status == 409 then
        self:_log(player.Name .. " is already registered; rotate the token and provide it via Gecko.start({token=...})")
    else
        self:_log("Registration failed: " .. tostring(status))
    end
    return nil
end

function Gecko:_log(...)
    local fn = (self.config and self.config.logFn) or defaultLog
    fn(...)
end

function Gecko.setState(fields)
    if type(fields) ~= "table" then return end
    for k, v in pairs(fields) do
        self.state[k] = v
    end
end

function Gecko.on(command, handler)
    self.handlers[command] = handler
end

function Gecko.isCoordinated()
    return self.coordination ~= nil and self.coordination.mode == "coordinated"
end

function Gecko.shouldWait()
    return self.isCoordinated() and self.state.ready == true
end

function Gecko.isRunning()
    return self._running
end

function Gecko.event(event, message, details, level)
    if not self.token or not self._running then return end
    local body = {
        event   = event,
        message = message and tostring(message):sub(1, 300) or "",
        details = details,
        level   = level or "info",
    }
    task.spawn(function()
        self:_httpCall("POST", "/accounts/events", self.token, body)
    end)
end

function Gecko:_pollCommands()
    local status, commands = self:_httpCall("POST", "/accounts/commands/poll", self.token)
    if status ~= 200 or type(commands) ~= "table" then return end
    for _, cmd in ipairs(commands) do
        self:_runCommand(cmd)
    end
end

function Gecko:_runCommand(cmd)
    local ack = self:_httpCall("POST", "/accounts/commands/" .. cmd.id .. "/ack", self.token)
    if ack ~= 200 then return end

    local handler = self.handlers[cmd.command_type]
    local body
    if not handler then
        body = { success = false, error = "unknown command" }
    else
        local ok, result = pcall(handler, cmd.parameters or {})
        if ok then
            body = {
                success = true,
                result = (type(result) == "table" and next(result) ~= nil) and result or nil,
            }
        else
            body = { success = false, error = tostring(result):sub(1, 900) }
        end
    end
    self:_httpCall("POST", "/accounts/commands/" .. cmd.id .. "/result", self.token, body)
end

function Gecko:_serverId()
    local id = game.JobId
    if type(id) == "string" and id ~= "" then return id end
    return nil
end

local _sending = false
function Gecko:_sendState()
    if not self.token or _sending then return nil end
    _sending = true
    local body = {
        server_id  = self:_serverId(),
        session_id = self.sessionId,
    }
    for k, v in pairs(self.state) do
        body[k] = v
    end
    local status, ack = self:_httpCall("POST", "/accounts/status", self.token, body)
    _sending = false

    if status == 200 and ack then
        self.interval = tonumber(ack.heartbeat_interval_seconds) or self.interval
        self.coordination = ack.coordination
        if (tonumber(ack.pending_commands) or 0) > 0 then
            task.spawn(function() self:_pollCommands() end)
        end
    end
    return status, ack
end

function Gecko.flush()
    if not self._running then return end
    task.spawn(function() self:_sendState() end)
end

function Gecko:_startHeartbeat()
    if self._loopThread then return end
    self._loopThread = task.spawn(function()
        local failures = 0
        while self._running do
            local status = self:_sendState()
            if status == 200 then
                failures = 0
            elseif status == 401 then
                self:_log("Token rejected (rotated or deleted). Set a new token via Gecko.start({token=...}).")
                self.coordination = nil
                self._running = false
                break
            else
                failures = failures + 1
                if failures == 1 or failures % 12 == 0 then
                    self:_log("Heartbeat failed (" .. tostring(status) .. "); retrying")
                end
            end
            local wait_s = math.min(self.interval * math.max(1, failures), 60)
            task.wait(wait_s)
        end
        self._loopThread = nil
    end)
end

function Gecko.stop()
    self._running = false
    self.coordination = nil
end

function Gecko.start(userConfig)
    if self._running and not (type(userConfig) == "table" and userConfig.reconfigure == true) then
        return self
    end

    local cfg = validateConfig(userConfig)
    self.config = {
        apiUrl          = cfg.apiUrl,
        enrollmentKey   = cfg.enrollmentKey,
        groupId         = cfg.groupId,
        defaultInterval = cfg.defaultInterval,
        tokenDir        = cfg.tokenDir,
        logFn           = cfg.logFn,
    }
    self._http    = resolveHttp(cfg.httpFn)
    self.interval = cfg.defaultInterval
    self._running = true

    genv.Gecko = self

    self.token = cfg.token or self:_readSavedToken() or self:_register()
    if not self.token then
        self._running = false
        return self
    end

    self:_log("Reporting for " .. resolvePlayer().Name
        .. " (session " .. self.sessionId:sub(1, 8) .. ")")

    self:_startHeartbeat()
    return self
end

return Gecko
