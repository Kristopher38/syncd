local event = require("event")
local computer = require("computer")
local com = require("component")

local internet = com.internet
local stem = {}

-- Constants
--------------------------------------------------------------------

local ADDRESS = "stem.fomalhaut.me"
local PORT = 5733
local Package = {
  MESSAGE = 0,
  SUBSCRIBE = 1,
  UNSUBSCRIBE = 2,
  PING = 3,
  PONG = 4
}
local PING_TIMEOUT = 5

-- Server level API
--------------------------------------------------------------------

local server_api = {
  __address = nil,
  __port = nil,
  __socket = nil,
  __channels = {}, -- list of channels this server is subscribed to
  __stream = "", -- the string which plays the role of bytearray for incoming data
  
  __build_package = function(type, id, message)
    local package = string.char(type)
    if type == Package.PING or type == Package.PONG then
      -- ping/pong content takes place of the `id` argument here
      package = package .. id
    else
      package = package .. string.char(#id) .. id
      if message ~= nil then
        package = package .. message
      end
    end
    local len = #package
    package = string.char(math.floor(len / 256), len % 256) .. package
    return package
  end,
  
  isSubscribed = function(self, id)
    return self.__channels[id]
  end,
  
  send = function(self, id, message)
    if self:isConnected() then
      local data = self.__build_package(Package.MESSAGE, id, message)
      local sent = 0
      repeat
        local result, message = self.__socket.write(data:sub(sent + 1))
        if not result then return nil, message end
        sent = sent + result
      until sent == #data
      return true
    else
      return nil, "not connected"
    end
  end,
  
  subscribe = function(self, id)
    if self:isConnected() then
      self.__socket.write(self.__build_package(Package.SUBSCRIBE, id))
      self.__channels[id] = true
      return true
    else
      return nil, "not connected"
    end
  end,
  
  unsubscribe = function(self, id)
    if self:isConnected() then
      self.__socket.write(self.__build_package(Package.UNSUBSCRIBE, id))
      self.__channels[id] = false
      return true
    else
      return nil, "not connected"
    end
  end,

  ping = function(self, content, timeout)
    -- send ping request
    self.__socket.write(self.__build_package(Package.PING, content))
    -- wait for response
    local time = os.time()
    local duration = timeout or PING_TIMEOUT
    while true do
      local name, data = event.pull(duration, "stem_pong")
      if name == "stem_pong" then
        return data == content
      else
        local passed = os.time() - time
        if passed >= duration * 20 then
          return false
        else
          duration = (timeout or PING_TIMEOUT) - (passed / 20)
        end
      end
    end
  end,

  isConnected = function(self)
    if self.__socket == nil then
      return nil, "there were no connection attempts"
    else
      return self.__socket.finishConnect()
    end
  end,

  reconnect = function(self)
    if self:isConnected() then
      self:disconnect()
    end
    local socket, error = internet.connect(self.__address or ADDRESS, self.__port or PORT)
    if not socket then
      return nil, error
    end
    self.__socket = socket
    event.listen('internet_ready', self.__listener)
    -- check connection until there will be some useful information
    -- also this serves to kick off internet_ready events generation
    while true do
      local result, error = self.__socket.finishConnect()
      if result then
        return self
      elseif result == nil then
        self:disconnect()
        return nil, error
      end
    end
  end,
  
  disconnect = function(self)
    self.__socket.close()
    self.__channels = {}
    self.__stream = ""
    event.ignore('internet_ready', self.__listener)
  end,
  
  __incoming = function(self, socket_id)
    -- check if the message belongs to the current connection
    if self.__socket.id() == socket_id then
      -- read all contents of the socket
      while true do
        local chunk = self.__socket.read()
        if chunk ~= nil and #chunk > 0 then
          self.__stream = self.__stream .. chunk
        else
          break
        end
      end
      -- read all packages that may be already downloaded
      while true do
        -- calculate the next package size, if necessary
        if self.len == nil and #self.__stream >= 2 then
          local a, b = self.__stream:byte(1, 2)
          self.len = a * 256 + b
        end
        -- check if the stream contains enough bytes for the package to be retrieved
        if self.len ~= nil and #self.__stream >= self.len + 2 then
          -- determine the package type
          local type = self.__stream:byte(3)
          local package = { type = type }
          if type == Package.PING or type == Package.PONG then
            -- read content
            package.content = self.__stream:sub(4, self.len + 2)
          else
            -- read channel ID
            local id_len = self.__stream:byte(4)
            local id = self.__stream:sub(5, id_len + 4)
            package.id = id
            -- read a message
            if type == Package.MESSAGE then
              package.message = self.__stream:sub(id_len + 5, self.len + 2)
            end
          end
          -- handle the package to processor
          self:__process(package)
          -- trim the stream
          self.__stream = self.__stream:sub(self.len + 3)
          self.len = nil
        else
          break
        end
      end
    end
  end,
  
  __process = function(self, package)
    if package.type == Package.MESSAGE then
      computer.pushSignal("stem_message", package.id, package.message)
    elseif package.type == Package.PING then
      self.__socket.write(self.__build_package(Package.PONG, package.content))
    elseif package.type == Package.PONG then
      computer.pushSignal("stem_pong", package.content)
    end
  end
}
server_api.__index = server_api

-- Library level functions
--------------------------------------------------------------------

function stem.connect(address, port)
  local server = {
    __address = address,
    __port = port,
    __socket = socket
  }
  setmetatable(server, server_api)
  server.__listener = function(_, _, id)
    server:__incoming(id)
  end
  return server:reconnect()
end

return stem
