---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Rack fits (shared.fit): where each stored gun sits in its slot.
local fit = require 'shared.fit'
---@type table Client rack mirror (client.racks.state).
local state = require 'client.racks.state'
---@type table Client helpers (client.racks.util): native booleans.
local util = require 'client.racks.util'
---@type table Rack targets (client.racks.targets): slot zones + rack options.
local targets = require 'client.racks.targets'
---@type table Inventory identity (bridge.shared.inventory_id): is ox_inventory running?
local inventoryId = require 'bridge.shared.inventory_id'

---@type table Drawing config (config.Draw).
local DRAW = config.Draw

---@type table Spawn module; the table returned at end of file.
local spawn = {}

-- Racks are drawn per client, as local props, only while the player is within StreamDistance
-- (one lib.points point per rack). A drawn rack keeps its prop, the weapon objects on it, and a
-- generation number: every show/hide bumps it, so a model still loading for an old show notices
-- it was superseded and deletes what it made instead of leaking it.
---@class DrawnRack
---@field entity integer|nil local rack prop
---@field weapons table<integer, { obj: integer|false, sig: string }> per slot; obj false while loading
---@field gen integer

---@type table<integer, DrawnRack> Racks currently drawn, by id.
local drawn = {}
---@type table<integer, table> The lib.points point of every tracked rack, by id.
local points = {}
---@type table<integer, integer> Latest generation per rack id (survives hide, so stale loads can tell).
local gens = {}

---Wait for a condition with the configured load timeout.
---@param check fun(): boolean
---@return boolean ok false on timeout
local function waitFor(check)
    local deadline = GetGameTimer() + (DRAW.LoadTimeout or 10000)

    while not check() do
        if GetGameTimer() > deadline then return false end

        Wait(0)
    end

    return true
end

---@type table<string, integer[]|false> ox_inventory component item -> its component hashes (false = none).
local oxComponents = {}

---The component hashes an attachment string stands for. A COMPONENT_ name is its own hash; on
---ox_inventory anything else is a component ITEM, whose client data lists the hashes it can be
---(one per weapon family), and the first one this weapon takes is the one fitted.
---@param weaponHash integer
---@param name string
---@return integer|nil hash
local function componentHash(weaponHash, name)
    if name:upper():sub(1, 10) == 'COMPONENT_' then
        local h = joaat(name:upper())

        return util.yes(DoesWeaponTakeWeaponComponent(weaponHash, h)) and h or nil
    end

    if inventoryId.name ~= 'ox_inventory' then return nil end

    local list = oxComponents[name]

    if list == nil then
        local ok, item = pcall(function() return exports.ox_inventory:Items(name) end)

        list = ok and item and item.client and type(item.client.component) == 'table' and item.client.component or false
        oxComponents[name] = list
    end

    for _, h in ipairs(list or {}) do
        if util.yes(DoesWeaponTakeWeaponComponent(weaponHash, h)) then return h end
    end

    return nil
end

---A string that changes when what a slot shows changes (gun, attachments or tint).
---@param s table|nil public slot { name, components, tint }
---@return string|nil
local function slotSig(s)
    if not s then return nil end

    return ('%s|%s|%s'):format(s.name, table.concat(s.components or {}, ','), tostring(s.tint or 0))
end

---Delete one weapon object if it still exists.
---@param obj integer|false|nil
local function deleteObj(obj)
    if obj and util.yes(DoesEntityExist(obj)) then
        DetachEntity(obj, false, false)
        DeleteEntity(obj)
    end
end

---Draw one stored gun on a drawn rack, the way docs/contract.md describes: the weapon asset, a
---weapon object with its attachments and tint, attached to the rack at the fitted offset and
---rotation (order 2: pitch, roll, yaw). Runs in its own thread (assets stream in).
---@param id integer rack id
---@param index integer slot index
---@param s table public slot { name, components, tint }
---@param gen integer the generation this draw belongs to
local function drawWeapon(id, index, s, gen)
    local d = drawn[id]
    local view = state.get(id)

    if not d or not view then return end

    local hash = joaat(s.name)

    if not util.yes(IsWeaponValid(hash)) then
        log.debug('spawn', 'rack %d slot %d: %s is not a weapon this client knows', id, index, s.name)
        return
    end

    RequestWeaponAsset(hash, 31, 0)

    if not waitFor(function() return util.yes(HasWeaponAssetLoaded(hash)) end) then
        log.debug('spawn', 'rack %d slot %d: weapon asset %s did not load', id, index, s.name)
        return
    end

    local dmin, dmax = GetModelDimensions(GetWeapontypeModel(hash))
    local offset, rot = fit.place(view.model, index, s.name, dmin, dmax)

    if not offset then
        log.debug('spawn', 'rack %d slot %d: no fit for %s', id, index, s.name)
        return
    end

    local comps = {}

    if DRAW.Attachments then
        for _, c in ipairs(s.components or {}) do
            local h = type(c) == 'string' and componentHash(hash, c) or nil

            if h then
                local cm = GetWeaponComponentTypeModel(h)

                if cm and cm ~= 0 then
                    RequestModel(cm)
                    waitFor(function() return util.yes(HasModelLoaded(cm)) end)
                end

                comps[#comps + 1] = h
            end
        end
    end

    -- The rack may have been hidden (or redrawn) while the assets streamed in.
    d = drawn[id]

    if not d or gens[id] ~= gen or not d.entity then return end

    local c = GetEntityCoords(d.entity)
    local obj = CreateWeaponObject(hash, 0, c.x, c.y, c.z, true, 1.0, 0)

    if not obj or obj == 0 then return end

    for _, h in ipairs(comps) do
        GiveWeaponComponentToWeaponObject(obj, h)
    end

    if DRAW.Tints and (s.tint or 0) > 0 then
        SetWeaponObjectTintIndex(obj, s.tint)
    end

    SetEntityCollision(obj, false, false)
    AttachEntityToEntity(
        obj, d.entity, 0,
        offset.x, offset.y, offset.z,
        rot.x, rot.y, rot.z,
        false, false, false, false, 2, true
    )

    local slot = d.weapons[index]

    if gens[id] ~= gen or not slot or slot.sig ~= slotSig(s) or slot.obj then
        deleteObj(obj) -- superseded while it was being made
        return
    end

    slot.obj = obj
end

---Bring the drawn guns of a rack in line with its view: delete what changed or left, draw what is
---new. Unchanged slots are left alone, so taking one gun does not redraw the other seven.
---@param id integer
local function syncWeapons(id)
    local d, view = drawn[id], state.get(id)

    if not d or not view or not d.entity then return end

    local wanted = view.slots or {}

    for index, slot in pairs(d.weapons) do
        if slot.sig ~= slotSig(wanted[index]) then
            deleteObj(slot.obj)
            d.weapons[index] = nil
        end
    end

    for index, s in pairs(wanted) do
        if not d.weapons[index] then
            d.weapons[index] = { obj = false, sig = slotSig(s) }

            local gen = d.gen

            CreateThread(function() drawWeapon(id, index, s, gen) end)
        end
    end
end

---Spawn a rack's prop (local, frozen), its target options and its guns.
---@param id integer
function spawn.show(id)
    if drawn[id] then return end

    local view = state.get(id)

    if not view then return end

    local gen = (gens[id] or 0) + 1

    gens[id] = gen

    local d = { entity = nil, weapons = {}, gen = gen }

    drawn[id] = d

    CreateThread(function()
        local hash = joaat(view.model)

        if not pcall(lib.requestModel, hash, DRAW.LoadTimeout or 10000) then
            log.error('spawn', 'rack model %s did not load (is it streamed?)', view.model)
            return
        end

        if drawn[id] ~= d or gens[id] ~= gen then
            SetModelAsNoLongerNeeded(hash) -- hidden again while it streamed in
            return
        end

        local ent = CreateObjectNoOffset(hash, view.x, view.y, view.z, false, false, false)

        SetEntityHeading(ent, view.heading + 0.0)
        FreezeEntityPosition(ent, true)
        SetEntityInvincible(ent, true)
        SetModelAsNoLongerNeeded(hash)

        d.entity = ent
        targets.addRack(id, ent)
        syncWeapons(id)
    end)
end

---Remove a drawn rack: its guns, its targets, its prop.
---@param id integer
function spawn.hide(id)
    local d = drawn[id]

    if not d then return end

    drawn[id] = nil
    gens[id] = (gens[id] or 0) + 1

    for _, slot in pairs(d.weapons) do
        deleteObj(slot.obj)
    end

    targets.removeRack(id, d.entity)

    if d.entity and util.yes(DoesEntityExist(d.entity)) then
        DeleteEntity(d.entity)
    end
end

---Start tracking a rack: a stream point that draws it while the player is near.
---@param id integer
function spawn.track(id)
    local view = state.get(id)

    if not view or points[id] then return end

    points[id] = lib.points.new({
        coords = vector3(view.x, view.y, view.z),
        distance = DRAW.StreamDistance or 40.0,
        rackId = id,
        onEnter = function(self) spawn.show(self.rackId) end,
        onExit = function(self) spawn.hide(self.rackId) end,
    })
end

---Stop tracking a rack (it was removed, or the player left its bucket).
---@param id integer
function spawn.untrack(id)
    spawn.hide(id)

    if points[id] then
        points[id]:remove()
        points[id] = nil
    end
end

---A tracked rack's view changed: redraw what changed on it (if it is drawn).
---@param id integer
function spawn.refresh(id)
    syncWeapons(id)
end

---The local prop of a drawn rack, or nil.
---@param id integer
---@return integer|nil entity
function spawn.entity(id)
    local d = drawn[id]

    return d and d.entity or nil
end

---Wire every drawn rack's interactions again: sd-interact started (its points start empty) or
---stopped (the racks go back to the target resource).
function spawn.rewire()
    for id, d in pairs(drawn) do
        if d.entity then
            targets.removeRack(id, d.entity)
            targets.addRack(id, d.entity)
        end
    end
end

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'sd-interact' then
        Wait(500) -- its exports register as it starts
        spawn.rewire()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'sd-interact' then
        spawn.rewire()
    end
end)

---Delete everything this client drew (resource stop).
function spawn.cleanupAll()
    for id in pairs(points) do
        spawn.untrack(id)
    end

    for id in pairs(drawn) do
        spawn.hide(id)
    end
end

return spawn
