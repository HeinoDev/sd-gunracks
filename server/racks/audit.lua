---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): the boot-time misconfig warning.
local log = require 'shared.log'
---@type table Server persistence (server.racks.store): the sd_gunracks_log table.
local store = require 'server.racks.store'

---@type table Player bridge (bridge.server.player): name + identifier lookups.
local playerBridge = require 'bridge.server.player'

---@type table Audit-logging config (config.Logs): master toggle + per-event switches.
local CFG = config.Logs or {}
---@type table The log table's switch and retention (config.Logs.Database).
local DB = CFG.Database or {}
---@type function|nil ox_lib server logger, or nil when no ox:logger backend is configured.
local logger = lib.logger

---@type table Audit module; the table returned at end of file.
local audit = {}

---Resolve a player's audit identity through the bridge: their character full name, character id
---(citizenid on qb/qbox, identifier on ESX), and the account username (GetPlayerName). Falls back
---to the username when the character can't be read. Self-contained (audit can't require
---server.racks.actor - the rate limiter logs through audit and actor sits above it - so it does
---its own lookup).
---@param src integer player server id
---@return string character character full name, or the username as a fallback
---@return string|nil cid character id, or nil if no character
---@return string username the account display name
local function actorOf(src)
    local username = GetPlayerName(src) or ('src ' .. src)
    local okName, character = pcall(playerBridge.getName, src)

    if not okName or not character or character == 'Unknown' then
        character = username
    end

    local okId, cid = pcall(playerBridge.getIdentifier, src)

    return character, okId and cid or nil, username
end

---The kind a row is filed under in the log table: the event, refined by the staff action when the
---call names one (admin -> admin.delete), so the Logs tab can filter one kind of staff action.
---@param event string
---@param data table|nil
---@return string kind
local function kindOf(event, data)
    local action = type(data) == 'table' and data.action or nil

    if type(action) == 'string' and action ~= '' then
        return event .. '.' .. action
    end

    return event
end

---The call's structured fields as the JSON kept with the row; nil when they do not encode.
---@param data table|nil
---@return string|nil json
local function encode(data)
    if type(data) ~= 'table' or next(data) == nil then return nil end

    local ok, s = pcall(json.encode, data)

    return ok and s or nil
end

---Record one audit event, subject to the master toggle and the per-event switch: a row in the
---sd_gunracks_log table (the console's Logs tab) unless Database is off, and a line to the external
---log backend when an ox:logger backend is configured. Never errors on an unconfigured server. For a
---player source the entry carries a readable actor - "Character Name (Username)" with the character
---id and server id - both in the line and as queryable metadata; system events (nil/'system') and
---other resources (an export's caller, by name) pass through as they are.
---@param event string event key (matches configs/server/logs.lua Events)
---@param source integer|string|nil acting player server id, a resource name, or nil/'system' for server events
---@param message string human-readable one-line summary
---@param data table? structured fields attached to the log (`action` refines the kind, `rack` files it under a rack)
function audit.log(event, source, message, data)
    if not CFG.Enabled then return end

    if CFG.Events and CFG.Events[event] == false then return end

    local player = type(source) == 'number' and source > 0
    local character, cid, username

    if player then
        character, cid, username = actorOf(source)
    end

    if DB.Enabled ~= false then
        local actorName

        if player then
            actorName = ('%s (%s)'):format(character, username)
        elseif type(source) == 'string' and source ~= 'system' then
            actorName = source
        end

        store.insertLog({
            at = os.time(),
            kind = kindOf(event, data),
            actor = actorName,
            cid = cid,
            src = player and source or nil,
            rack = type(data) == 'table' and math.tointeger(tonumber(data.rack)) or nil,
            detail = message,
            data = encode(data),
        })
    end

    if not logger then return end

    if player then
        cid = cid or 'unknown'

        ---@type table enriched metadata: the call's own data plus the readable actor fields.
        local meta = {}

        if data then
            for k, v in pairs(data) do
                meta[k] = v
            end
        end

        meta.character, meta.username, meta.cid, meta.sid = character, username, cid, source

        logger(source, event, ('%s (%s) [cid %s | id %d]: %s'):format(character, username, cid, source, message), meta)

        return
    end

    logger(source or 'system', event, message, data)
end

---Delete the log rows the retention limits no longer keep (configs/server/logs.lua Database).
---@return integer deleted
function audit.prune()
    if DB.Enabled == false or not store.logReady() then return 0 end

    local maxRows = math.max(0, math.floor(tonumber(DB.MaxRows) or 0))
    local maxDays = math.max(0, math.floor(tonumber(DB.MaxDays) or 0))
    local n = store.pruneLogs(maxRows, maxDays)

    if n > 0 then
        log.info('audit', 'pruned %d old log rows', n)
    end

    return n
end

-- One-time boot warning: logging is on but there is no backend to receive it, so only the log
-- table has it. Better the owner sees this than wonders why their sink is empty.
CreateThread(function()
    if CFG.Enabled and not logger then
        log.warn('audit', 'no ox:logger backend configured (set the ox:logger convar + service key); %s',
            DB.Enabled ~= false and 'audit events go to the sd_gunracks_log table only' or 'audit logs are OFF')
    end
end)

return audit
