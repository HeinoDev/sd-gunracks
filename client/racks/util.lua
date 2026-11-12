---@type table Rack fits (shared.fit): rack labels.
local fit = require 'shared.fit'
---@type table Inventory bridge (bridge.client.inventory): item labels.
local inventory = require 'bridge.client.inventory'
---@type table Notify bridge (bridge.client.notify): on-screen notifications.
local notify = require 'bridge.client.notify'

---@type table Util module; the table returned at end of file.
local util = {}

---A native's boolean answer as a Lua boolean. On this platform natives can hand back 1/0 instead of
---true/false, and 0 is truthy in Lua, so every native yes/no goes through here.
---@param v any
---@return boolean
function util.yes(v)
    return v == true or v == 1
end

---A readable name for a weapon: the inventory's label (under either spelling), else the weapon
---name tidied up (WEAPON_CARBINERIFLE -> Carbinerifle).
---@param name string|nil
---@return string
function util.weaponLabel(name)
    if not name then return '?' end

    local label = inventory.label(name) or inventory.label(name:lower()) or inventory.label(name:upper())

    if label then return label end

    local s = name:gsub('^[Ww][Ee][Aa][Pp][Oo][Nn]_', ''):gsub('_', ' '):lower()

    return (s:gsub('^%l', string.upper))
end

---A rack model's label from racks.json.
---@param model string
---@return string
function util.rackLabel(model)
    local def = fit.rack(model)

    return def and def.label or model
end

---Notify the local player under the resource title.
---@param msg string
---@param kind? string success | error | inform
function util.notify(msg, kind)
    notify.show({ title = locale('title'), description = msg, type = kind or 'inform' })
end

---A short progress bar (configs/client/targets.lua Progress). Instant when `ms` is 0.
---@param ms integer|nil duration
---@param label string
---@param anim? table { dict, clip }
---@return boolean finished false when the player cancelled
function util.progress(ms, label, anim)
    if not ms or ms <= 0 then return true end

    return lib.progressCircle({
        duration = ms,
        label = label,
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = anim and anim.dict and { dict = anim.dict, clip = anim.clip } or nil,
    }) and true or false
end

return util
