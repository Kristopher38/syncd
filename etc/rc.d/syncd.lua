local serialization = require("serialization")
local event = require("event")
local fs = require("filesystem")
local component = require("component")
local inspect = require("inspect")
local cbor = require("cbor")
local xxh64 = require("xxh64")
local syslog = require("syslog")
local stemBackend = require("syncd.backends.stem")

local log = {}
for levelName, levelValue in pairs(syslog) do
    log[levelName] = function(...) syslog(string.format(...), levelValue, "syncd") end
end

local syncd = {}
syncd.__index = syncd

function syncd.new(address, syncedDir, channel, backend)
    local self = {
        _address = address,
        _syncedDir = fs.canonical(syncedDir),
        _channel = channel,
        _backend = backend,
        _commsEstablished = false,
    }
    return setmetatable(self, syncd)
end

function syncd:connect()
    self._listenerWrap = function(_, ...)
        self:_listener(...)
    end
    event.listen("syncd_backend_message", self._listenerWrap)
    
    local res, err = self._backend:connect(self._address)
    if res then
        return self:_join(self._channel)
    else
        return nil, err
    end
end

function syncd:disconnect()
    event.ignore("syncd_backend_message", self._listenerWrap)
    self._backend:disconnect()
end

function syncd:commsEstablished()
    return self._commsEstablished
end

function syncd:ping()
    log.debug("Sending ping")
    self:_send(self._channel, { type = "Ping" })
end

function syncd:pong()
    self:_send(self._channel, { type = "Pong" })
end

function syncd:list(path)
    self:_send(self._channel, { type = "List", path = path })
end

function syncd:listResp(entries)
    self:_send(self._channel, { type = "ListResp", entries = entries})
end

function syncd:get(path)
    self:_send(self._channel, { type = "Get", path = path})
end

function syncd:getResp(path, contents)
    self:_send(self._channel, { type = "GetResp", path = path, contents = contents})
end

function syncd:fsEventCreate(path, entity)
    self:_send(self._channel, { type = "FsEventCreate", path = path, entity = entity})
end

function syncd:fsEventModify(path, hash)
    self:_send(self._channel, { type = "FsEventModify", path = path, hash = hash})
end

function syncd:fsEventRename(pathFrom, pathTo)
    self:_send(self._channel, {
        type = "FsEventRename",
        path_from = pathFrom,
        path_to = pathTo
    })
end

function syncd:fsEventDelete(path)
    self:_send(self._channel, { type = "FsEventDelete", path = path})
end

function syncd:fsEventUnknown(path, entity, hash)
    self:_send(self._channel, {
        type = "FsEventUnknown",
        path = path,
        entity = entity,
        hash = hash
    })
end

function syncd:_join(channel)
    return self._backend:subscribe(channel)
end

function syncd:_leave(channel)
    return self._backend:unsubscribe(channel)
end

function syncd:_send(channel, msg)
    return self._backend:send(channel, cbor.encode(msg))
end

local function fileHash(path)
    local f, err = io.open(path, "rb")
    if f then
        local content = f:read("*a")
        local hash = xxh64.sum(content)
        f:close()
        return hash
    else
        return nil, err
    end
end

local function pathEscapesDir(path, dir)
    return path:sub(1, #dir) ~= dir
end

local function getSafeCanonical(dir, path)
    local canonical = fs.canonical(fs.concat(dir, path))
    if pathEscapesDir(canonical, dir) then
        error(string.format(
            "path %s has a canonical form of %s and would escape directory %s",
            path, canonical, dir
        ))
    end
    return canonical
end

syncd.handlers = {}

function syncd.handlers:Ping(msg)
    self._commsEstablished = true
    self:pong()
end

function syncd.handlers:Pong(msg)
    self._commsEstablished = true
end

function syncd.handlers:ListResp(msg)
    for _, entry in ipairs(msg.entries) do
        local path = getSafeCanonical(self._syncedDir, entry.path)
        if entry.entity == "File" then
            if fs.exists(path) then
                if not fs.isDirectory(path) then
                    local localHash = fileHash(path)
                    if localHash ~= entry.hash then
                        -- both files exist but local file is different, download
                        log.debug(
                            "Local and remote hash of %s differ: local hash is %d, remote is %d, requesting file contents",
                            path, localHash, entry.hash
                        )
                        self:get(entry.path)
                    else
                        -- both files exist and are identical, do nothing
                        log.debug("Local and remote hash of %s are identical (hash is %d)", path, localHash)
                    end
                else
                    -- path exists locally but is a directory - download file,
                    -- directory will get removed in GetResp handler
                    log.debug("Remote path is a file but local path %s is a directory, requesting file contents", path)
                    self:get(entry.path)
                end
            else
                -- file does not exist locally, download
                log.debug("Path %s does not exist locally, requesting file contents", path)
                self:get(entry.path)
            end
        elseif entry.entity == "Directory" then
            log.debug("Path %s is a directory, requesting directory contents", path)
            self:list(entry.path)
        end
    end
end

function syncd.handlers:GetResp(msg)
    local path = getSafeCanonical(self._syncedDir, msg.path)
    local f, err = io.open(path, "wb")
    if f then
        f:write(msg.contents)
        f:close()
        log.info("Updated file %s with new contents, hash: %s", path, xxh64.sum(msg.contents))
    else
        log.error("Failed opening file %s for writing: %s", msg.path, err)
    end
end

function syncd.handlers:FsEventCreate(msg)
    local path = getSafeCanonical(self._syncedDir, msg.path)
    if msg.entity == "File" then
        local f, err = io.open(path, "wb")
        if f then
            f:close()
            log.info("Created file %s", path)
        else
            log.error("Failed creating file %s: %s", path, err)
        end
    elseif msg.entity == "Directory" then
        local ok, err = fs.makeDirectory(path)
        if not ok then
            log.error("Failed creating directory %s: %s", path, err)
        else
            log.info("Created directory %s", path)
        end
    elseif msg.entity == "Symlink" then
        log.warning("Unimplemented FsEventCreate for entity Symlink")
    else
        log.warning("Unknown entity type %s in FsEventCreate", msg.entity)
    end
end

function syncd.handlers:FsEventModify(msg)
    local path = getSafeCanonical(self._syncedDir, msg.path)
    log.debug("Requesting update for file %s", path)
    self:get(msg.path)
end

function syncd.handlers:FsEventRename(msg)
    local path_from = getSafeCanonical(self._syncedDir, msg.path)
    local path_to = getSafeCanonical(self._syncedDir, msg.path)
    local ok, err = fs.rename(path_from, path_to)
    if not ok then
        log.error("Failed renaming %s to %s: %s", path_from, path_to, err)
    else
        log.info("Renamed file from %s to %s", path_from, path_to)
    end
end

function syncd.handlers:FsEventDelete(msg)
    local path = getSafeCanonical(self._syncedDir, msg.path) 
    local ok, err = fs.remove(path)
    if not ok then
        log.error("Failed removing file %s: %s", path, err)
    else
        log.info("Removed file %s", path)
    end
end

function syncd.handlers:FsEventUnknown(msg)
    log.warning("Unimplemented FsEventUnknown")
end


function syncd:_listener(channel, rawMsg)
    if channel == self._channel then
        local msg = cbor.decode(rawMsg)
        log.debug("Received %s message:\n%s", msg.type, inspect(msg))
        if self.handlers[msg.type] then
            local ok, err = pcall(self.handlers[msg.type], self, msg)
            if not ok then
                log.error("Failed processing message: %s", err)
            end
        else
            log.warning("Received unknown message type %s", msg.type)
        end
    end
end

local function errorfmt(...) error(string.format(...)) end

local backends = {
    stem = stemBackend
}

local configPath = "/etc/syncd.cfg"

local defaultConfig = {
    channel = "default_channel",
    syncedDir = "/home/default_dir",
    backend = "stem",
    backendOps = {},
    address = "stem.fomalhaut.me:5733",
}

local function loadConfig()
    local f, err = io.open(configPath, "r")
    if f then
        local cfg, err = serialization.unserialize(f:read("*a"))
        if cfg then
            f:close()
            return cfg
        else
            errorfmt("Failed reading config file %s: %s", configPath, err)
        end
    else
        errorfmt("Failed to open config file %s: %s", configPath, err)
    end
end

local function saveConfig(cfg)
    local f, err = io.open(configPath, "w")
    if f then
        local cfgStr = serialization.serialize(cfg)
        local f, err = f:write(cfgStr)
        if f then
            f:flush()
            f:close()
            return
        else
            errorfmt("Failed writing config file %s: %s", configPath, err)
        end
    else
        errorfmt("Failed to create config file %s: %s", configPath, err)
    end
end

local function getConfig()
    if not fs.exists(configPath) then
        saveConfig(defaultConfig)
    end
    local config = loadConfig()
    -- assert that all fields present in default config are present in loaded config
    for k, _ in pairs(defaultConfig) do
        if not config[k] then
            errorfmt("Missing field '%s' in service's config file %s", k, configPath)
        end
    end
    -- assert that provided backend exists
    if not backends[config.backend] then
        errorfmt("Unknown backend '%s' specified in service's config file %s", config.backend, configPath)
    end
    return config
end

local inst

function start()
    if not component.isAvailable("internet") then
        errorfmt("This service requires an internet card to run")
    end

    local config = getConfig()
    local backend = backends[config.backend].new()
    inst = syncd.new(config.address, config.syncedDir, config.channel, backend)

    local res, err = inst:connect()
    if not res then
        errorfmt("Failed to connect to %s using %s backend: %s", config.address, config.backend, err)
    end

    -- try to ping every 2 seconds
    event.timer(2, function()
        if not inst:commsEstablished() then
            inst:ping()
            return true
        else
            inst:list(".")
            -- remove timer once we're connected
            return false
        end
    end, math.huge)
end

function stop()
    inst:disconnect()
end
