-- Bridge + fit stubs for sd-gunracks: the resource's bridge/ folder talks to a live framework and
-- inventory, and shared/fit.lua reads the generated data/racks.json, so under stock Lua each is
-- replaced by a fake. The bridge fakes are backed by per-src tables the scenarios inspect and
-- mutate; the fit fake is a small fixture of three racks. Installed via package.preload so the
-- resource's own `require 'bridge.server.inventory'` etc. resolve here before the loader runs.
local H = require 'env'

local S = {}

-- Flags per src: `full` (cannot carry, add fails), `failAdd` (canCarry says yes, the add still
-- fails: the give-failure rollback path), `addsLeft` (that many adds succeed, then they fail like
-- `failAdd`: a give that fails part way), `failRemove` (removals fail).
local inventory = {
    system = 'ox_inventory',
    durabilityKey = 'durability',
    full = {},
    failAdd = {},
    addsLeft = {},
    failRemove = {},
}
local stores = {}

local function store(src)
    src = tonumber(src)
    stores[src] = stores[src] or { nextSlot = 1, slots = {} }

    return stores[src]
end

function inventory._reset()
    stores = {}
    inventory.full, inventory.failAdd, inventory.addsLeft, inventory.failRemove = {}, {}, {}, {}
end

---Dump one player's inventory as a readable string (for assertion messages).
function inventory._dump(src)
    local parts = {}
    for _, s in ipairs(inventory.getSlots(src)) do
        parts[#parts + 1] = ('%s x%d@%d%s'):format(s.name, s.count, s.slot, s.metadata and (' ' .. json.encode(s.metadata)) or '')
    end

    return '{' .. table.concat(parts, ', ') .. '}'
end

---Put an item in a player's inventory directly (test setup); returns the slot it landed in.
function inventory._give(src, item, count, metadata)
    local st = store(src)
    local slot = st.nextSlot
    st.nextSlot = slot + 1
    st.slots[slot] = { slot = slot, name = item, count = count or 1, metadata = metadata }

    return slot
end

function inventory.add(src, item, count, metadata)
    src = tonumber(src)

    if inventory.full[src] or inventory.failAdd[src] then return false end

    local left = inventory.addsLeft[src]

    if left then
        if left <= 0 then return false end

        inventory.addsLeft[src] = left - 1
    end

    count = count or 1
    local st = store(src)

    if not metadata or next(metadata) == nil then
        for _, s in pairs(st.slots) do
            if s.name == item and (not s.metadata or next(s.metadata) == nil) then
                s.count = s.count + count return true
            end
        end
    end

    inventory._give(src, item, count, metadata)

    return true
end

function inventory.count(src, item)
    local n = 0

    for _, s in pairs(store(src).slots) do
        if s.name == item then
            n = n + s.count
        end
    end

    return n
end

function inventory.has(src, item, amount)
    return inventory.count(src, item) >= (amount or 1)
end

function inventory.remove(src, item, count)
    if inventory.failRemove[tonumber(src)] then return false end

    count = count or 1

    if inventory.count(src, item) < count then return false end

    local st = store(src)
    for _, s in ipairs(inventory.getSlots(src, item)) do
        local take = math.min(count, s.count)
        s.count = s.count - take
        count = count - take

        if s.count <= 0 then
            st.slots[s.slot] = nil
        end

        if count <= 0 then break end
    end

    return true
end

function inventory.canCarry(src) return not inventory.full[tonumber(src)] end

function inventory.getSlots(src, item)
    local out = {}
    for _, s in pairs(store(src).slots) do
        if item == nil or s.name == item then
            out[#out + 1] = s
        end
    end

    table.sort(out, function(a, b) return a.slot < b.slot end)

    return out
end

function inventory.getSlot(src, slot) return store(src).slots[slot] end

function inventory.removeFromSlot(src, item, count, slot)
    if inventory.failRemove[tonumber(src)] then return false end

    if slot == nil then
        return inventory.remove(src, item, count)
    end

    local st = store(src)
    local s = st.slots[slot]

    if not s or s.name ~= item or s.count < (count or 1) then return false end

    s.count = s.count - (count or 1)

    if s.count <= 0 then
        st.slots[slot] = nil
    end

    return true
end

function inventory.durabilityOf(metadata)
    if type(metadata) ~= 'table' then return nil end

    return tonumber(metadata.durability)
end

function inventory.registerUsable(item, fn) H.records.usable[item] = fn end
H.labels = {}
function inventory.label(name) return H.labels[name] or name end

S.inventory = inventory

local player = {}
function player.get(src) return H.players[tonumber(src)] end
function player.getIdentifier(src)
    local p = H.players[tonumber(src)]
    return p and ('CID' .. p.src) or nil
end

function player.getName(src)
    local p = H.players[tonumber(src)]
    return p and p.name or 'Unknown'
end

function player.getJob(src)
    local p = H.players[tonumber(src)]
    return p and p.job or nil
end

function player.getGang(src)
    local p = H.players[tonumber(src)]
    return p and p.gang or nil
end

H.loadedHandlers = {}
function player.onLoaded(cb) H.loadedHandlers[#H.loadedHandlers + 1] = cb end
-- Characters who exist but are not on: citizen id -> name (what the framework's table would say).
H.offline = {}
function player.offlineName(cid) return H.offline[cid] end
S.player = player

local job = {}
function job.getName(src)
    local p = H.players[tonumber(src)]
    return p and p.job or nil
end

function job.getGrade(src)
    local p = H.players[tonumber(src)]
    return p and p.grade or 0
end

function job.has(src, name, minGrade)
    local p = H.players[tonumber(src)]
    return p ~= nil and p.job == name and (p.grade or 0) >= (minGrade or 0)
end

S.job = job

local gang = {}
function gang.getName(src)
    local p = H.players[tonumber(src)]
    return p and p.gang or nil
end

function gang.getGrade(src)
    local p = H.players[tonumber(src)]
    return p and p.gangGrade or 0
end

S.gang = gang

local notify = {}
function notify.to(src, data, kind)
    H.records.notify[#H.records.notify + 1] = { src = src, data = data, kind = kind, at = H.now }
end

S.notify = notify

-- Three racks shaped like the real ones: a floor rack of long guns, a wall board of handguns and a
-- wall rack with two kinds (long + pistol, like the pegboard). Fits are dummies; only which keys
-- exist matters to the server. Extras are accepted by group, the way the real fit.lua does it.
local fixture = {
    sd_gunrack_oak = {
        label = 'Oak Floor Rack', mount = 'floor',
        min = { -0.48, -0.17, 0.0 }, max = { 0.48, 0.17, 0.86 },
        slots = {
            { kind = 'long', pos = { -0.3, 0.0, 0.1 }, yaw = 0.0, focus = { -0.3, -0.12, 0.5 }, radius = 0.1 },
            { kind = 'long', pos = { 0.0, 0.0, 0.1 }, yaw = 0.0, focus = { 0.0, -0.12, 0.5 }, radius = 0.1 },
            { kind = 'long', pos = { 0.3, 0.0, 0.1 }, yaw = 0.0, focus = { 0.3, -0.12, 0.5 }, radius = 0.1 },
        },
        kinds = { long = { type = 'upright', label = 'Long gun', groups = { 'GROUP_RIFLE', 'GROUP_SHOTGUN', 'GROUP_SMG' } } },
        fits = { long = {
            WEAPON_CARBINERIFLE = { 0, 0.01, 0.3, -78, 90, 0 },
            WEAPON_PUMPSHOTGUN = { 0, 0.01, 0.3, -78, 90, 0 },
            WEAPON_RPG = { 0, 0.01, 0.3, -78, 90, 0 }, -- fitted, but blacklisted in the config
        } },
    },
    sd_gunrack_pistols = {
        label = 'Pistol Display Board', mount = 'wall',
        min = { -0.4, 0.0, 0.0 }, max = { 0.4, 0.05, 0.6 },
        slots = {
            { kind = 'pistol', pos = { -0.2, -0.02, 0.3 }, yaw = 0.0, focus = { -0.2, -0.04, 0.3 }, radius = 0.08 },
            { kind = 'pistol', pos = { 0.2, -0.02, 0.3 }, yaw = 0.0, focus = { 0.2, -0.04, 0.3 }, radius = 0.08 },
        },
        kinds = { pistol = { type = 'horizontal', label = 'Handgun', groups = { 'GROUP_PISTOL' } } },
        fits = { pistol = { WEAPON_PISTOL = { 0, 0, 0, 0, 90, 0 } } },
    },
    sd_gunrack_pegboard = {
        label = 'Tactical Pegboard', mount = 'wall',
        min = { -0.6, 0.0, 0.0 }, max = { 0.6, 0.05, 1.0 },
        slots = {
            { kind = 'long', pos = { 0.0, -0.02, 0.7 }, yaw = 0.0, focus = { 0.0, -0.04, 0.7 }, radius = 0.1 },
            { kind = 'pistol', pos = { -0.3, -0.02, 0.3 }, yaw = 0.0, focus = { -0.3, -0.04, 0.3 }, radius = 0.08 },
        },
        kinds = {
            long = { type = 'horizontal', label = 'Long gun', groups = { 'GROUP_RIFLE' } },
            pistol = { type = 'peg', label = 'Handgun', groups = { 'GROUP_PISTOL' } },
        },
        fits = { long = { WEAPON_CARBINERIFLE = { 0, 0, 0, 0, 0, 0 } }, pistol = { WEAPON_PISTOL = { 0, 0, 0, 0, 0, 0 } } },
    },
}

local fit = {}
function fit.racks() return fixture end
function fit.rack(model) return fixture[model] end
function fit.accepts(model, slot, weapon)
    local r = fixture[model]
    local s = r and r.slots[slot]

    if not s or type(weapon) ~= 'string' then return false end

    local name = weapon:upper()

    if r.fits[s.kind] and r.fits[s.kind][name] then return true end

    local group = (require('configs.config').Weapons.Extra or {})[name]
    for _, g in ipairs(group and r.kinds[s.kind].groups or {}) do
        if g == group then return true end
    end

    return false
end

function fit.place() return H.vec3(0, 0, 0), H.vec3(0, 0, 0) end
S.fit = fit

local function tagLogger()
    local l = setmetatable({}, { __call = function() end })
    l.on = function() return false end

    return l
end

local debugMod = { tag = tagLogger, enabled = function() return false end }
local framework = { name = 'qb', isQbx = true, core = {} }

package.preload['shared.fit'] = function() return fit end
package.preload['bridge.shared.debug'] = function() return debugMod end
package.preload['bridge.shared.framework'] = function() return framework end
package.preload['bridge.shared.inventory_id'] = function() return { name = 'ox_inventory' } end
package.preload['bridge.shared.init'] = function() return true end
package.preload['bridge.server.init'] = function() return true end
package.preload['bridge.server.inventory'] = function() return inventory end
package.preload['bridge.server.player'] = function() return player end
package.preload['bridge.server.job'] = function() return job end
package.preload['bridge.server.gang'] = function() return gang end
package.preload['bridge.server.notify'] = function() return notify end
package.preload['bridge.server.version'] = function() return { check = function() end } end

return S
