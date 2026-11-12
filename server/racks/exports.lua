---@type table Rack fits (shared.fit): which models exist.
local fit = require 'shared.fit'
---@type table Rack-space geometry (shared.geo): heading normalising.
local geo = require 'shared.geo'
---@type table Audit-log helper (server.racks.audit): external audit trail via lib.logger.
local audit = require 'server.racks.audit'
---@type table Live racks (server.racks.registry).
local registry = require 'server.racks.registry'
---@type table Per-bucket client sync (server.racks.sync).
local sync = require 'server.racks.sync'
---@type table Admin helpers (server.racks.admin): access-list sanitising.
local admin = require 'server.racks.admin'
---@type table Player handlers (server.racks.actions): handing a rack's guns to a player.
local actions = require 'server.racks.actions'

-- Server exports for other resources (housing, MLO armouries). They write to the database, so
-- call them from a thread (any event handler or CreateThread). README.md documents them.

---Every rack, as detached copies (stored guns with full metadata).
---@return table[] racks
exports('GetRacks', function()
    local out = {}
    for _, r in pairs(registry.all()) do
        out[#out + 1] = registry.copy(r)
    end

    table.sort(out, function(a, b) return a.id < b.id end)

    return out
end)

---One rack as a detached copy, or nil.
---@param id integer
---@return table|nil rack
exports('GetRack', function(id)
    local r = registry.get(id)

    return r and registry.copy(r) or nil
end)

---Create a rack without an item.
---@param model string rack model (sd_gunrack_*)
---@param coords vector3|table world origin (docs/contract.md: floor racks on the floor, wall racks on the wall)
---@param heading number degrees
---@param opts? { bucket?: integer, owner?: string, ownerName?: string, locked?: boolean, access?: table, ignoreSpacing?: boolean }
---@return integer|nil id
---@return string|nil err 'bad_model' | 'bad_coords' | 'too_close' | 'overlap' | 'save_failed'
exports('CreateRack', function(model, coords, heading, opts)
    opts = type(opts) == 'table' and opts or {}

    if type(model) ~= 'string' or not fit.rack(model) then return nil, 'bad_model' end

    local x, y, z = coords and tonumber(coords.x), coords and tonumber(coords.y), coords and tonumber(coords.z)

    if not (x and y and z) then return nil, 'bad_coords' end

    local pos = vector3(x, y, z)
    local bucket = math.tointeger(tonumber(opts.bucket)) or 0

    heading = geo.heading(heading)

    if not opts.ignoreSpacing then
        local free, why = registry.spotFree(model, pos, heading, bucket)

        if not free then return nil, why end
    end

    local rack = registry.create({
        model = model,
        coords = pos,
        heading = heading,
        bucket = bucket,
        owner = type(opts.owner) == 'string' and opts.owner or nil,
        ownerName = type(opts.ownerName) == 'string' and opts.ownerName or nil,
        locked = opts.locked == nil and true or opts.locked == true,
        access = admin.readAccess(opts.access),
    })

    if not rack then return nil, 'save_failed' end

    sync.push(rack)

    local resource = GetInvokingResource()

    audit.log('export', resource or 'system',
        ('%s created rack %d (%s)'):format(tostring(resource), rack.id, model),
        { rack = rack.id, model = model, owner = rack.owner, resource = resource })

    return rack.id
end)

---Delete a rack. With `giveTo` (a player server id) its guns go into that player's inventory first,
---and the rack is kept if they cannot carry them all. Without it the rack is deleted and its guns
---are handed back to the caller, which decides where they go (a house stash, the owner...).
---@param id integer
---@param giveTo? integer player server id
---@return boolean ok
---@return table|string guns the removed guns { { name, item, metadata, by, at } } on success, or an error key
exports('DeleteRack', function(id, giveTo)
    local rack = registry.get(id)

    if not rack or rack.removing then return false, 'no_rack' end

    if next(rack.claims) ~= nil then return false, 'busy' end

    rack.removing = true

    local count = registry.storedCount(rack)
    local guns = {}
    local target = math.tointeger(tonumber(giveTo))

    if target then
        -- The emptied slots are written before any gun is handed out (actions.giveAll).
        local given, left = actions.giveAll(target, rack)

        if not given then
            rack.removing = nil
            return false, 'save_failed'
        end

        if left > 0 then
            rack.removing = nil
            sync.push(rack)
            return false, 'cannot_carry'
        end
    else
        local indices = {}

        for i in pairs(rack.slots) do
            indices[#indices + 1] = i
        end

        table.sort(indices)

        for _, i in ipairs(indices) do
            guns[#guns + 1] = rack.slots[i]
        end
    end

    -- With `giveTo`, its guns are already with the player and its emptied slots written: the rack
    -- stays, empty.
    if not registry.destroy(rack) then
        rack.removing = nil

        if target then
            sync.push(rack)
        end

        return false, 'save_failed'
    end

    sync.drop(rack)

    local resource = GetInvokingResource()
    local where = target and ('given to ' .. target) or 'returned to the caller'

    audit.log('export', resource or 'system',
        ('%s deleted rack %d (%d guns %s)'):format(tostring(resource), rack.id, count, where),
        { rack = rack.id, guns = count, giveTo = target, resource = resource })

    return true, guns
end)
