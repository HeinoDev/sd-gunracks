---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Rack fits (shared.fit): each model's box and slots, from data/racks.json.
local fit = require 'shared.fit'
---@type table Rack-space geometry (shared.geo): boxes, overlap, distance.
local geo = require 'shared.geo'
---@type table Weapon metadata helpers (shared.weapons): deep copies for exports.
local weapons = require 'shared.weapons'
---@type table Server persistence (server.racks.store): the sd_gunracks table.
local store = require 'server.racks.store'

---@class Rack
---@field id integer               row id
---@field model string             rack model (sd_gunrack_*)
---@field coords vector3           world origin (see docs/contract.md for where that sits per mount)
---@field heading number           degrees
---@field bucket integer           routing bucket it lives in; only players in that bucket see it
---@field owner string|nil         owner's character id; nil for admin/export racks that belong to nobody
---@field ownerName string|nil     owner's character name when placed (for staff lists)
---@field locked boolean           locked racks open only to owner / admins / the access list
---@field access table|nil         { jobs = { name = minGrade }, gangs = { name = minGrade } }
---@field slots table<integer, table> slot index -> { name, item, metadata, by, byName, at }
---@field createdAt integer        unix seconds
---@field claims table<integer, boolean> slots with a store/take in flight (never persisted)
---@field removing boolean|nil     set while the rack is being picked up / deleted: every request is refused

---@type table Registry module; the table returned at end of file.
local registry = {}

-- Every rack on the server, by id. The table is the truth while the resource runs; each change
-- is written through to the database straight away (store.*), so a restart reloads exactly this.
---@type table<integer, Rack> Live racks by id.
local racks = {}

---@type boolean True once the boot load finished; requests before that see no racks.
local loaded = false

---Fill in the run-time-only fields a rack record needs.
---@param r table rack data
---@return Rack rack
local function hydrate(r)
    r.slots = r.slots or {}
    r.claims = {}
    r.removing = nil

    return r
end

---Load every rack from the database (boot). Racks whose model is missing from data/racks.json
---stay in the table but are not loaded, so a removed model does not wipe anyone's guns.
---@return integer count racks loaded
function registry.load()
    racks = {}

    local n = 0

    for _, r in ipairs(store.loadAll()) do
        if r.id and fit.rack(r.model) then
            racks[r.id] = hydrate(r)
            n = n + 1
        else
            log.warn('registry', 'rack %s has unknown model %s; left in the database, not loaded', tostring(r.id), tostring(r.model))
        end
    end

    loaded = true

    return n
end

---@return boolean true once the boot load finished
function registry.ready()
    return loaded
end

---One rack by id.
---@param id any
---@return Rack|nil
function registry.get(id)
    id = math.tointeger(tonumber(id))
    return id and racks[id] or nil
end

---Every rack (live table; do not mutate the result).
---@return table<integer, Rack>
function registry.all()
    return racks
end

---Every rack in one routing bucket.
---@param bucket integer
---@return Rack[]
function registry.inBucket(bucket)
    local out = {}
    for _, r in pairs(racks) do
        if r.bucket == bucket then
            out[#out + 1] = r
        end
    end

    table.sort(out, function(a, b) return a.id < b.id end)

    return out
end

---How many racks a character owns.
---@param identifier string|nil
---@return integer
function registry.ownedCount(identifier)
    if not identifier then return 0 end

    local n = 0
    for _, r in pairs(racks) do
        if r.owner == identifier then
            n = n + 1
        end
    end

    return n
end

---Racks within `radius` of `coords` in `bucket`, nearest first.
---@param coords vector3
---@param bucket integer
---@param radius number metres
---@return { rack: Rack, dist: number }[]
function registry.near(coords, bucket, radius)
    local out = {}
    for _, r in pairs(racks) do
        if r.bucket == bucket and not r.removing then
            local d = geo.dist(coords, r.coords)

            if d <= radius then
                out[#out + 1] = { rack = r, dist = d }
            end
        end
    end

    table.sort(out, function(a, b) return a.dist < b.dist end)

    return out
end

---How many guns a rack holds.
---@param rack Rack
---@return integer
function registry.storedCount(rack)
    local n = 0
    for _ in pairs(rack.slots) do
        n = n + 1
    end

    return n
end

---Is a rack empty and idle (nothing stored, nothing in flight)?
---@param rack Rack
---@return boolean
function registry.isEmpty(rack)
    return next(rack.slots) == nil and next(rack.claims) == nil
end

---May a rack of `model` go at this pose in `bucket`? Refused when another rack's origin is closer
---than Placement.MinDistance or the two boxes overlap.
---@param model string
---@param coords vector3
---@param heading number
---@param bucket integer
---@param ignoreId? integer a rack to leave out of the check
---@return boolean free
---@return string|nil why 'too_close' | 'overlap' | 'no_model'
function registry.spotFree(model, coords, heading, bucket, ignoreId)
    local def = fit.rack(model)

    if not def then return false, 'no_model' end

    local box = geo.box(def, coords, heading)
    local minDist = config.Placement.MinDistance or 0.3
    for id, r in pairs(racks) do
        if id ~= ignoreId and r.bucket == bucket then
            if geo.dist(coords, r.coords) < minDist then return false, 'too_close' end

            local other = fit.rack(r.model)

            if other and geo.overlaps(box, geo.box(other, r.coords, r.heading)) then
                return false, 'overlap'
            end
        end
    end

    return true
end

---Insert a new rack (database first, then the live table).
---@param data table { model, coords, heading, bucket, owner?, ownerName?, locked, access?, slots? }
---@return Rack|nil rack nil when the insert failed
function registry.create(data)
    local r = {
        model = data.model,
        coords = vector3(data.coords.x + 0.0, data.coords.y + 0.0, data.coords.z + 0.0),
        heading = geo.heading(data.heading),
        bucket = math.tointeger(tonumber(data.bucket)) or 0,
        owner = data.owner,
        ownerName = data.ownerName,
        locked = data.locked == true,
        access = data.access,
        slots = data.slots or {},
        createdAt = os.time(),
    }

    local id = store.insert(r)

    if not id then return nil end

    r.id = id
    racks[id] = hydrate(r)

    return r
end

---Delete a rack (database first, then the live table).
---@param rack Rack
---@return boolean ok
function registry.destroy(rack)
    if not store.delete(rack.id) then return false end

    racks[rack.id] = nil

    return true
end

---Write a rack's slots through to the database.
---@param rack Rack
---@return boolean ok
function registry.saveSlots(rack)
    return store.saveSlots(rack.id, rack.slots)
end

---Write a rack's lock state through to the database.
---@param rack Rack
---@return boolean ok
function registry.saveLocked(rack)
    return store.saveLocked(rack.id, rack.locked)
end

---Write a rack's access list through to the database.
---@param rack Rack
---@return boolean ok
function registry.saveAccess(rack)
    return store.saveAccess(rack.id, rack.access)
end

---Write a rack's owner (and the name shown for them) through to the database.
---@param rack Rack
---@return boolean ok
function registry.saveOwner(rack)
    return store.saveOwner(rack.id, rack.owner, rack.ownerName)
end

---A detached copy of a rack for other resources (exports): the stored guns with their full
---metadata, without the run-time bookkeeping.
---@param rack Rack
---@return table copy
function registry.copy(rack)
    return {
        id = rack.id,
        model = rack.model,
        coords = vector3(rack.coords.x, rack.coords.y, rack.coords.z),
        heading = rack.heading,
        bucket = rack.bucket,
        owner = rack.owner,
        ownerName = rack.ownerName,
        locked = rack.locked,
        access = weapons.copy(rack.access),
        slots = weapons.copy(rack.slots),
        createdAt = rack.createdAt,
    }
end

return registry
