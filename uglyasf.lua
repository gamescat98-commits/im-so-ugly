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
