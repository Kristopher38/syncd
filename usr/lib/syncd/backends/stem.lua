local computer = require("computer")
local event = require("event")
local stem = require("stem")

local stemBackend = {}
stemBackend.__index = stemBackend

function stemBackend.new()
    local self = {
        _server = nil
    }
    return setmetatable(self, stemBackend)
end

function stemBackend:connect(address)
    local server, err = stem.connect(address)
    if server ~= nil then
        self._server = server
        self._listenerWrap = function(_, ...)
            stemBackend._listener(self, ...)
        end
        event.listen("stem_message", self._listenerWrap)
        return true
    else
        return nil, err
    end
end

function stemBackend:subscribe(channel)
    return self._server:subscribe(channel)
end

function stemBackend:unsubscribe(channel)
    return self._server:unsubscribe(channel)
end

function stemBackend:send(channel, msg)
    return self._server:send(channel, msg)
end

function stemBackend:_listener(channel, msg)
    computer.pushSignal("syncd_backend_message", channel, msg)
end

function stemBackend:disconnect()
    event.ignore("stem_message", self._listenerWrap)
    self._server:disconnect()
end

return stemBackend
