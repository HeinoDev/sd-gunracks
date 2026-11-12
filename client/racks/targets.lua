---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Rack fits (shared.fit): slots (focus + radius) and which guns each takes.
local fit = require 'shared.fit'
---@type table Rack-space geometry (shared.geo): slot focus -> world.
local geo = require 'shared.geo'
---@type table Weapon names (shared.weapons): normalising + blacklist.
local weapons = require 'shared.weapons'
---@type table Client rack mirror (client.racks.state).
local state = require 'client.racks.state'
---@type table Client helpers (client.racks.util): labels.
local util = require 'client.racks.util'
---@type table Rack menus + flows (client.racks.menus): what each option does.
local menus = require 'client.racks.menus'
---@type table Target bridge (bridge.client.target): backend-agnostic target wiring.
local target = require 'bridge.client.target'
---@type table Inventory bridge (bridge.client.inventory): the held weapon, the force item.
local inventory = require 'bridge.client.inventory'

---@type table Target option config (config.Targets).
local T = config.Targets

---@type table Targets module; the table returned at end of file.
local targets = {}

---@type table<integer, any[]> Sphere-zone ids per rack, one per slot.
local zones = {}

---@type table<integer, string>|nil Weapon hash -> name for every weapon any rack knows, built on
---first use. Only needed where the inventory cannot say which item is in the player's hands.
local byHash = nil

---Name a held weapon from its hash, for inventories that report only the hash.
---@param hash integer
---@return string|nil
local function nameForHash(hash)
    if not byHash then
        byHash = {}
        for _, def in pairs(fit.racks() or {}) do
            for _, list in pairs(def.fits or {}) do
                for name in pairs(list) do
                    byHash[joaat(name)] = name
                end
            end
        end

        for name in pairs(config.Weapons.Extra or {}) do
            byHash[joaat(name)] = weapons.normalise(name)
        end
    end

    return byHash[hash]
end

---The gun in the player's hands, if this slot would take it.
---@param view table rack view
---@param index integer slot index
---@return table|nil held { name (UPPERCASE), item (inventory spelling), slot }
local function heldFor(view, index)
    local cw = inventory.currentWeapon()

    if not cw then return nil end

    local name = cw.name and weapons.normalise(cw.name) or nameForHash(cw.hash)

    if not name or weapons.blocked(name, config.Weapons) then return nil end

    if not fit.accepts(view.model, index, name) then return nil end

    return { name = name, item = cw.name or name, slot = cw.slot }
end

---The options of one slot's zone. Every option's canInteract reads the live mirror, so the zone
---never needs rebuilding when guns come and go. On ox_target the labels also follow the gun
---("Rack Carbine Rifle", "Take Pump Shotgun"): ox_target reads an option's label after running its
---canInteract, so the check rewrites its own option's label.
---@param id integer rack id
---@param index integer slot index
---@param kindLabel string the slot kind's label ("Long gun")
---@return table[] options
local function slotOptions(id, index, kindLabel)
    local S = T.Slot

    local function view()
        return state.get(id)
    end

    local function stored()
        local v = view()

        return v and v.slots and v.slots[index] or nil
    end

    local store = {
        name = ('sd_gunracks_store_%d_%d'):format(id, index),
        icon = S.store.icon,
        distance = S.store.distance,
        label = locale('target.store_generic'),
    }

    store.canInteract = function()
        local v = view()

        if not v or not v.allowed or stored() then return false end

        local held = heldFor(v, index)

        if not held then return false end

        store.label = locale('target.store', util.weaponLabel(held.item))

        return true
    end

    store.onSelect = function()
        local v = view()
        local held = v and heldFor(v, index)

        if held then
            menus.store(id, index, held.slot, held.item)
        end
    end

    local take = {
        name = ('sd_gunracks_take_%d_%d'):format(id, index),
        icon = S.take.icon,
        distance = S.take.distance,
        label = locale('target.take_generic'),
    }

    take.canInteract = function()
        local v, s = view(), stored()

        if not v or not v.allowed or not s then return false end

        take.label = locale('target.take', util.weaponLabel(s.name))

        return true
    end

    take.onSelect = function() menus.take(id, index) end

    local seize = {
        name = ('sd_gunracks_seize_%d_%d'):format(id, index),
        icon = S.seize.icon,
        distance = S.seize.distance,
        label = locale('target.seize_generic'),
    }

    seize.canInteract = function()
        local v, s = view(), stored()

        if not v or v.mine or not s or not state.me().police then return false end

        seize.label = locale('target.seize', util.weaponLabel(s.name))

        return true
    end

    seize.onSelect = function() menus.seize(id, index) end

    return {
        store,
        {
            name = ('sd_gunracks_choose_%d_%d'):format(id, index),
            label = locale('target.choose', kindLabel),
            icon = S.choose.icon,
            distance = S.choose.distance,
            canInteract = function()
                local v = view()

                return v ~= nil and v.allowed and stored() == nil
            end,
            onSelect = function() menus.choose(id, index) end,
        },
        take,
        {
            name = ('sd_gunracks_inspect_%d_%d'):format(id, index),
            label = locale('target.inspect'),
            icon = S.inspect.icon,
            distance = S.inspect.distance,
            canInteract = function()
                local v = view()

                return v ~= nil and stored() ~= nil and (v.allowed or state.me().police)
            end,
            onSelect = function() menus.inspect(id, index) end,
        },
        seize,
    }
end

---The rack-wide options on the rack prop itself: lock / unlock / pick up for whoever may manage
---it, force the lock for whoever may not open it.
---@param id integer
---@return table[] options
local function rackOptions(id)
    local R = T.Rack

    local function view()
        return state.get(id)
    end

    return {
        {
            name = 'sd_gunracks_lock',
            label = locale('target.lock'),
            icon = R.lock.icon,
            distance = R.lock.distance,
            canInteract = function()
                local v = view()

                return v ~= nil and v.manage and not v.locked
            end,
            onSelect = function() menus.setLocked(id, true) end,
        },
        {
            name = 'sd_gunracks_unlock',
            label = locale('target.unlock'),
            icon = R.unlock.icon,
            distance = R.unlock.distance,
            canInteract = function()
                local v = view()

                return v ~= nil and v.manage and v.locked
            end,
            onSelect = function() menus.setLocked(id, false) end,
        },
        {
            name = 'sd_gunracks_pickup',
            label = locale('target.pickup'),
            icon = R.pickup.icon,
            distance = R.pickup.distance,
            canInteract = function()
                local v = view()

                return v ~= nil and v.manage and next(v.slots or {}) == nil
            end,
            onSelect = function() menus.pickup(id) end,
        },
        {
            name = 'sd_gunracks_force',
            label = locale('target.force'),
            icon = R.force.icon,
            distance = R.force.distance,
            canInteract = function()
                local v = view()

                if not v or not v.forceable then return false end

                local item = state.me().forceItem

                return not item or inventory.has(item, 1)
            end,
            onSelect = function() menus.force(id) end,
        },
    }
end

---Wire a freshly drawn rack: the rack options on its prop and one zone per slot.
---
---The target resources show a zone when the player's aim ray ENDS inside it. A stored gun has no
---collision and a slot is mostly open air, so the ray goes through the gun and ends on whatever is
---behind it (the rest, the board, the wall, the floor). Each slot therefore gets a box covering its
---whole column (racks.json `zone`, tools/props/zones.py): wide as the gap to its neighbours, deep
---enough to take in what the ray lands on. A slot without a `zone` gets a small sphere at its focus
---point instead.
---@param id integer
---@param entity integer the local rack prop
function targets.addRack(id, entity)
    local view = state.get(id)
    local def = view and fit.rack(view.model)

    if not def then return end

    if targets.useInteract() then
        return targets.addInteract(id, entity, def)
    end

    target.addLocalEntity(entity, rackOptions(id))

    local origin = vector3(view.x, view.y, view.z)
    local list = {}

    for index, slot in ipairs(def.slots or {}) do
        local kind = def.kinds and def.kinds[slot.kind]
        local name = ('sd_gunracks_%d_%d'):format(id, index)
        local options = slotOptions(id, index, (kind and kind.label) or locale('target.slot'))
        local zone = slot.zone

        if zone then
            local x, y, z = geo.toWorld(origin, view.heading, zone.c)
            list[#list + 1] = target.addBoxZone({
                name = name,
                coords = vector3(x, y, z),
                size = vector3(zone.s[1], zone.s[2], zone.s[3]),
                rotation = geo.heading(view.heading + (zone.yaw or 0.0)),
                debug = config.Debug,
                options = options,
            })
        else
            local x, y, z = geo.toWorld(origin, view.heading, slot.focus or slot.pos)
            list[#list + 1] = target.addSphereZone({
                name = name,
                coords = vector3(x, y, z),
                radius = slot.radius or 0.12,
                debug = config.Debug,
                options = options,
            })
        end
    end

    zones[id] = list
end

---Is sd-interact the way in (configs/client/targets.lua Interact)?
---@return boolean
function targets.useInteract()
    local mode = T.Interact

    if mode == false then return false end

    local running = GetResourceState('sd-interact') == 'started'

    return running and (mode == true or mode == 'auto' or mode == nil)
end

---@type table<integer, boolean> racks wired through sd-interact (they come off the same way)
local viaInteract = {}

---An option for sd-interact: the same table, its canInteract also handing back the label it just
---set (the option crosses into sd-interact as a copy, so a label rewritten here would not show).
---@param o table
---@return table
local function forInteract(o)
    local can = o.canInteract

    return {
        name = o.name,
        label = o.label,
        icon = o.icon,
        distance = o.distance,
        canInteract = function()
            if can and not can() then return false end

            return true, o.label
        end,
        onSelect = function() o.onSelect() end,
    }
end

---Wire a drawn rack through sd-interact: a prompt on each slot (on the rack itself, at the middle of
---where its gun sits, so a look at the gun opens it and the rack never hides its own prompt) and the
---rack's own options a little above its top.
---@param id integer
---@param entity integer
---@param def table racks.json entry
function targets.addInteract(id, entity, def)
    local api = exports['sd-interact']

    for index, slot in ipairs(def.slots or {}) do
        local kind = def.kinds and def.kinds[slot.kind]
        local opts = {}

        for _, o in ipairs(slotOptions(id, index, (kind and kind.label) or locale('target.slot'))) do
            opts[#opts + 1] = forInteract(o)
        end

        local f = slot.focus or slot.pos

        api:addLocalEntity(entity, {
            name = ('sd_gunracks_%d_%d'):format(id, index),
            options = opts,
            offset = vector3(f[1], f[2], f[3]),
            interactDistance = 2.4,
            distance = 5.0,
        })
    end

    local opts = {}
    for _, o in ipairs(rackOptions(id)) do
        opts[#opts + 1] = forInteract(o)
    end

    local lo, hi = def.min, def.max

    api:addLocalEntity(entity, {
        name = ('sd_gunracks_%d'):format(id),
        options = opts,
        offset = vector3((lo[1] + hi[1]) / 2, lo[2], hi[3] + 0.08),
        interactDistance = 2.6,
        distance = 5.0,
    })

    viaInteract[id] = true
end

---Unwire a rack that is no longer drawn.
---@param id integer
---@param entity integer|nil
function targets.removeRack(id, entity)
    if viaInteract[id] then
        viaInteract[id] = nil

        if entity and GetResourceState('sd-interact') == 'started' then
            exports['sd-interact']:removeLocalEntity(entity)
        end

        zones[id] = nil

        return
    end

    if entity then
        target.removeLocalEntity(entity)
    end

    for _, z in ipairs(zones[id] or {}) do
        target.removeZone(z)
    end

    zones[id] = nil
end

return targets
