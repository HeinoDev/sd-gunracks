---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Rack fits (shared.fit): slots, kinds and which guns each slot accepts.
local fit = require 'shared.fit'
---@type table Rack-space geometry (shared.geo): distances.
local geo = require 'shared.geo'
---@type table Access rules (shared.access): owner / locked / access-list decisions.
local access = require 'shared.access'
---@type table Weapon metadata reads (shared.weapons): names, serials, ammo, attachments.
local weapons = require 'shared.weapons'
---@type table Audit-log helper (server.racks.audit): external audit trail via lib.logger.
local audit = require 'server.racks.audit'
---@type table Live racks (server.racks.registry).
local registry = require 'server.racks.registry'
---@type table Per-bucket client sync (server.racks.sync).
local sync = require 'server.racks.sync'
---@type table Player facts from the bridge (server.racks.actor).
local actor = require 'server.racks.actor'
---@type table Per-player request pacing (server.racks.limits).
local limits = require 'server.racks.limits'
---@type table Inventory bridge (bridge.server.inventory): backend-agnostic item ops.
local inventory = require 'bridge.server.inventory'
---@type table Job bridge (bridge.server.job): the place-permission check.
local job = require 'bridge.server.job'
---@type table Notify bridge (bridge.server.notify): server -> client notifications.
local notify = require 'bridge.server.notify'

---@type table Placement config (config.Placement): range, spacing, per-player limit, jobs.
local PLACE = config.Placement
---@type table Interaction config (config.Interact): range, force, seize.
local INTERACT = config.Interact
---@type table Force-the-lock config (config.Interact.Force).
local FORCE = INTERACT.Force or {}

---@type table Actions module; the table returned at end of file.
local actions = {}

---A refusal in the callback response shape.
---@param key string locale key
---@param ... any locale arguments
---@return table response
local function fail(key, ...)
    return { success = false, message = locale(key, ...) }
end

---A success in the callback response shape.
---@param data? table
---@return table response
local function ok(data)
    return { success = true, data = data or {} }
end

---Notify one player under the resource title.
---@param src integer
---@param msg string
---@param kind? string success | error | inform
local function tell(src, msg, kind)
    notify.to(src, { title = locale('title'), description = msg, type = kind or 'inform' })
end

actions.tell = tell

---The rack item for a model (the reverse of configs/shared/racks.lua Items).
---@param model string
---@return string|nil item
function actions.itemFor(model)
    for item, m in pairs(config.Racks.Items) do
        if m == model then return item end
    end

    return nil
end

---A display label for a rack model (racks.json label, else the model name).
---@param model string
---@return string
local function rackLabel(model)
    local def = fit.rack(model)
    return def and def.label or model
end

actions.rackLabel = rackLabel

---Where the player's ped stands, or nil without one.
---@param src integer
---@return vector3|nil
local function pedCoords(src)
    local ped = GetPlayerPed(src)

    if not ped or ped == 0 then return nil end

    return GetEntityCoords(ped)
end

actions.pedCoords = pedCoords

---The common gate for anything done at a rack: pace, the rack exists and is not being removed,
---it is in the player's routing bucket, and the player stands within Interact.Range of it.
---@param src integer
---@param rackId any
---@param kind? 'action'|'query'
---@return Rack|nil rack
---@return table|nil refusal response when rack is nil
local function atRack(src, rackId, kind)
    if not limits.allow(src, kind or 'action') then
        return nil, fail('err.too_fast')
    end

    local rack = registry.get(rackId)

    if not rack or rack.removing then
        return nil, fail('err.no_rack')
    end

    if rack.bucket ~= GetPlayerRoutingBucket(src) then
        audit.log('suspect', src,
            ('used rack %d from another routing bucket'):format(rack.id),
            { reason = 'wrong_bucket', rack = rack.id })
        return nil, fail('err.no_rack')
    end

    local pc = pedCoords(src)

    if not pc or geo.dist(pc, rack.coords) > INTERACT.Range then
        return nil, fail('err.too_far')
    end

    return rack
end

actions.atRack = atRack

---A slot index the rack really has, with its racks.json definition.
---@param rack Rack
---@param slot any
---@return integer|nil index
---@return table|nil def racks.json slot
local function slotOf(rack, slot)
    local index = math.tointeger(tonumber(slot))
    local def = fit.rack(rack.model)
    local s = index and def and def.slots and def.slots[index]

    if not s then return nil end

    return index, s
end

---The spellings an inventory may use for one weapon item: as sent, UPPERCASE (ox) and lowercase
---(qb), without repeats.
---@param name string
---@return string[]
local function spellings(name)
    local out, seen = {}, {}
    for _, n in ipairs({ name, name:upper(), name:lower() }) do
        if not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end

    return out
end

---The inventory slot of the gun the player means. With a slot id the server reads that slot and
---trusts nothing else the client said about it; without one (inventories that cannot tell which
---slot is in the player's hands) the first stack of that weapon is used.
---@param src integer
---@param invSlot any slot id the client named
---@param weapon any weapon item name the client named
---@return table|nil row { name, slot, count, metadata }
local function findWeapon(src, invSlot, weapon)
    if invSlot ~= nil then
        local s = inventory.getSlot(src, invSlot)

        if not s then return nil end

        if weapon ~= nil and weapons.normalise(s.name) ~= weapons.normalise(weapon) then
            return nil
        end

        return s
    end

    if type(weapon) ~= 'string' or weapon == '' then return nil end

    for _, name in ipairs(spellings(weapon)) do
        local list = inventory.getSlots(src, name)

        if type(list) == 'table' and list[1] then
            local s = list[1]
            return { name = name, slot = s.slot, count = s.count, metadata = s.metadata or {} }
        end
    end

    return nil
end

---Hand a stored gun to `src` and empty its slot. The slot is claimed in memory BEFORE anything
---that can yield, so a second request for the same gun finds it gone; the database is written
---before the give, and both are rolled back if the give fails, so the gun is never in two places.
---@param src integer
---@param rack Rack
---@param index integer slot index
---@return table response
---@return table|nil rec the stored gun handed out (on success)
local function giveOut(src, rack, index)
    local rec = rack.slots[index]

    if not rec or rack.claims[index] then
        return fail('err.slot_empty')
    end

    rack.claims[index] = true
    rack.slots[index] = nil

    local function restore()
        rack.slots[index] = rec
        rack.claims[index] = nil
    end

    if not inventory.canCarry(src, rec.item, 1, rec.metadata) then
        restore()
        return fail('err.cannot_carry')
    end

    if not registry.saveSlots(rack) then
        restore()
        return fail('err.save_failed')
    end

    if not inventory.add(src, rec.item, 1, weapons.copy(rec.metadata)) then
        restore()

        if not registry.saveSlots(rack) then
            log.error('actions',
                'rack %d slot %d: give failed AND the rollback write failed; the gun is in memory only until the next save',
                rack.id, index)
        end

        return fail('err.cannot_carry')
    end

    rack.claims[index] = nil
    sync.push(rack)

    return ok({ slot = index, name = rec.name }), rec
end

actions.giveOut = giveOut

---Hand every stored gun on a rack to `src`, in slot order, the way giveOut hands one: the slots are
---emptied in memory and written to the database BEFORE anything is given. The first gun that does
---not go into the inventory stops it there: that gun and every one after it go back on the rack,
---which is written again, so a gun is never in two places. As in giveOut, the first gun is checked
---for room before anything is written. The caller has the rack marked `removing` with no store or
---take in flight, so nothing else touches its slots meanwhile.
---@param src integer
---@param rack Rack
---@return integer|nil given guns handed out; nil when the write failed and nothing changed
---@return integer left guns still on the rack
function actions.giveAll(src, rack)
    local indices = {}

    for i in pairs(rack.slots) do
        indices[#indices + 1] = i
    end

    table.sort(indices)

    if #indices == 0 then return 0, 0 end

    local first = rack.slots[indices[1]]

    if not inventory.canCarry(src, first.item, 1, first.metadata) then
        return 0, #indices
    end

    local guns = {}

    for _, i in ipairs(indices) do
        guns[i] = rack.slots[i]
        rack.slots[i] = nil
    end

    if not registry.saveSlots(rack) then
        for _, i in ipairs(indices) do
            rack.slots[i] = guns[i]
        end

        return nil, #indices
    end

    for n, i in ipairs(indices) do
        local rec = guns[i]
        local handed = inventory.canCarry(src, rec.item, 1, rec.metadata)
            and inventory.add(src, rec.item, 1, weapons.copy(rec.metadata))

        if not handed then
            for k = n, #indices do
                rack.slots[indices[k]] = guns[indices[k]]
            end

            if not registry.saveSlots(rack) then
                log.error('actions',
                    'rack %d: %d guns not handed out AND the rollback write failed; in memory only until the next save',
                    rack.id, #indices - n + 1)
            end

            return n - 1, #indices - n + 1
        end
    end

    return #indices, 0
end


-- Open placements: the rack item a player used and the slot it came from, so the confirm can only
-- place what was actually used (and removes that item). Forgotten after SessionSeconds.
---@type table<integer, { item: string, model: string, slot: any, at: integer }>
local sessions = {}

---May this player put racks down at all (Placement.Jobs)?
---@param src integer
---@return boolean
local function mayPlace(src)
    local jobs = PLACE.Jobs

    if type(jobs) ~= 'table' or next(jobs) == nil then return true end

    for name, minGrade in pairs(jobs) do
        if job.has(src, name, tonumber(minGrade) or 0) then return true end
    end

    return false
end

---Is this player at their rack limit (Placement.MaxPerPlayer)?
---@param identifier string
---@return boolean
local function atLimit(identifier)
    local max = tonumber(PLACE.MaxPerPlayer) or 0
    return max > 0 and registry.ownedCount(identifier) >= max
end

---A rack item was used: check the player may place one, then open placement mode on their client.
---Called from the usable-item handler, so failures are notified rather than returned.
---@param src integer
---@param item string rack item name
---@param invSlot any the inventory slot the item was used from (when the inventory says)
function actions.beginPlacement(src, item, invSlot)
    local model = config.Racks.Items[item]

    if not model or not fit.rack(model) then
        log.error('actions', 'rack item %s has no model in data/racks.json', tostring(item))
        return tell(src, locale('err.bad_model'), 'error')
    end

    local a = actor.of(src)

    if not a.identifier then
        return tell(src, locale('err.no_identity'), 'error')
    end

    if not mayPlace(src) then
        return tell(src, locale('err.place_jobs'), 'error')
    end

    if atLimit(a.identifier) then
        return tell(src, locale('err.place_limit', PLACE.MaxPerPlayer), 'error')
    end

    sessions[src] = { item = item, model = model, slot = invSlot, at = os.time() }
    TriggerClientEvent('sd-gunracks:client:startPlacement', src, { model = model, item = item })
end

---Is `v` a real, finite number?
---@param v any
---@return boolean
local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

---A pose out of a client payload, or nil when any part is missing or absurd.
---@param payload table { coords = { x, y, z }, heading }
---@return vector3|nil coords
---@return number|nil heading
function actions.readPose(payload)
    local c = type(payload) == 'table' and payload.coords

    if type(c) ~= 'table' and type(c) ~= 'vector3' then return nil end

    local x, y, z, h = tonumber(c.x), tonumber(c.y), tonumber(c.z), tonumber(payload.heading or 0)

    if not (finite(x) and finite(y) and finite(z) and finite(h)) then return nil end

    if math.abs(x) > 20000 or math.abs(y) > 20000 or z < -1000 or z > 3000 then return nil end

    return vector3(x, y, z), geo.heading(h)
end

---Confirm a placement: re-check everything the ghost checked (range, spacing) plus what only the
---server knows (the session, the limit, the item), take the item, then insert the rack. A failed
---insert gives the item back.
---@param src integer
---@param payload table { coords = { x, y, z }, heading }
---@return table response
function actions.place(src, payload)
    if not limits.allow(src, 'action') then
        return fail('err.too_fast')
    end

    local s = sessions[src]

    if not s then
        audit.log('suspect', src, 'placed a rack without using a rack item', { reason = 'place_no_session' })
        return fail('err.no_placement')
    end

    if os.time() - s.at > (PLACE.SessionSeconds or 300) then
        sessions[src] = nil
        return fail('err.no_placement')
    end

    local coords, heading = actions.readPose(payload)

    if not coords then
        audit.log('suspect', src, 'sent an unreadable rack pose', { reason = 'bad_pose' })
        return fail('err.bad_spot')
    end

    local a = actor.of(src)

    if not a.identifier then
        return fail('err.no_identity')
    end

    if not mayPlace(src) then
        return fail('err.place_jobs')
    end

    if atLimit(a.identifier) then
        return fail('err.place_limit', PLACE.MaxPerPlayer)
    end

    local pc = pedCoords(src)

    if not pc or geo.dist(pc, coords) > (PLACE.Range or 4.0) + (PLACE.RangeSlack or 1.5) then
        return fail('err.too_far_place')
    end

    local bucket = GetPlayerRoutingBucket(src)
    local free, why = registry.spotFree(s.model, coords, heading, bucket)

    if not free then
        return fail('err.spot_' .. tostring(why))
    end

    local removed = inventory.removeFromSlot(src, s.item, 1, s.slot) or inventory.remove(src, s.item, 1)

    if not removed then
        sessions[src] = nil
        return fail('err.no_item')
    end

    local rack = registry.create({
        model = s.model,
        coords = coords,
        heading = heading,
        bucket = bucket,
        owner = a.identifier,
        ownerName = a.name,
        locked = true,
    })

    if not rack then
        inventory.add(src, s.item, 1)
        return fail('err.save_failed')
    end

    sessions[src] = nil
    sync.push(rack)
    audit.log('place', src,
        ('placed %s (rack %d) at %.2f, %.2f, %.2f'):format(rackLabel(rack.model), rack.id, coords.x, coords.y, coords.z),
        {
            rack = rack.id,
            model = rack.model,
            x = coords.x,
            y = coords.y,
            z = coords.z,
            heading = heading,
            bucket = bucket,
        })
    return ok({ id = rack.id })
end

---The player backed out of placement mode: forget their session (the item never left them).
---@param src integer
function actions.cancelPlacement(src)
    sessions[src] = nil
end


---Put one of the player's guns on an empty slot. The server reads the gun out of the inventory
---slot itself, checks the slot takes it, claims the rack slot, then removes the gun from the
---player; if the removal or the database write fails, everything goes back the way it was.
---@param src integer
---@param payload table { rackId, slot, invSlot?, weapon? }
---@return table response
function actions.store(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local rack, refusal = atRack(src, payload.rackId)

    if not rack then return refusal end

    local a = actor.of(src)

    if not access.canUse(rack, a) then
        return fail('err.no_access')
    end

    local index = slotOf(rack, payload.slot)

    if not index then
        audit.log('suspect', src,
            ('stored into a slot rack %d does not have'):format(rack.id),
            { reason = 'bad_slot', rack = rack.id, slot = payload.slot })
        return fail('err.bad_slot')
    end

    if rack.slots[index] or rack.claims[index] then
        return fail('err.slot_taken')
    end

    local held = findWeapon(src, payload.invSlot, payload.weapon)

    if not held then
        return fail('err.no_weapon')
    end

    local name = weapons.normalise(held.name)

    if not weapons.isWeapon(name) then
        audit.log('suspect', src,
            ('tried to rack a non-weapon item %s'):format(tostring(held.name)),
            { reason = 'not_weapon', item = held.name })
        return fail('err.not_weapon')
    end

    if weapons.blocked(name, config.Weapons) then
        return fail('err.blacklisted')
    end

    if not fit.accepts(rack.model, index, name) then
        return fail('err.no_fit')
    end

    rack.claims[index] = true

    if not inventory.removeFromSlot(src, held.name, 1, held.slot) then
        rack.claims[index] = nil
        return fail('err.remove_failed')
    end

    local rec = {
        name = name,
        item = held.name,
        metadata = weapons.copy(held.metadata or {}),
        by = a.identifier,
        byName = a.name,
        at = os.time(),
    }
    rack.slots[index] = rec

    if not registry.saveSlots(rack) then
        rack.slots[index] = nil
        rack.claims[index] = nil
        inventory.add(src, held.name, 1, rec.metadata)
        return fail('err.save_failed')
    end

    rack.claims[index] = nil
    sync.push(rack)

    local serial = weapons.serial(rec.metadata)

    audit.log('store', src,
        ('stored %s (serial %s) on rack %d slot %d'):format(name, serial or 'none', rack.id, index),
        { rack = rack.id, slot = index, weapon = name, serial = serial, owner = rack.owner })

    return ok({ slot = index, name = name })
end

---Take a stored gun off the rack.
---@param src integer
---@param payload table { rackId, slot }
---@return table response
function actions.take(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local rack, refusal = atRack(src, payload.rackId)

    if not rack then return refusal end

    if not access.canUse(rack, actor.of(src)) then
        return fail('err.no_access')
    end

    local index = slotOf(rack, payload.slot)

    if not index then
        return fail('err.bad_slot')
    end

    local res, rec = giveOut(src, rack, index)

    if rec then
        local serial = weapons.serial(rec.metadata)

        audit.log('take', src,
            ('took %s (serial %s) from rack %d slot %d'):format(rec.name, serial or 'none', rack.id, index),
            {
                rack = rack.id,
                slot = index,
                weapon = rec.name,
                serial = serial,
                owner = rack.owner,
                racked_by = rec.by,
            })
    end

    return res
end

---Police seize a stored gun from any rack, locked or not. Logged with the serial and the owner.
---@param src integer
---@param payload table { rackId, slot }
---@return table response
function actions.seize(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local rack, refusal = atRack(src, payload.rackId)

    if not rack then return refusal end

    if not actor.of(src).police then
        audit.log('suspect', src,
            ('tried to seize from rack %d without a police job'):format(rack.id),
            { reason = 'seize_not_police', rack = rack.id })
        return fail('err.not_police')
    end

    local index = slotOf(rack, payload.slot)

    if not index then
        return fail('err.bad_slot')
    end

    local res, rec = giveOut(src, rack, index)

    if rec then
        local serial = weapons.serial(rec.metadata)
        local owner = tostring(rack.ownerName or rack.owner or 'none')

        audit.log('seize', src,
            ('seized %s (serial %s) from rack %d slot %d, owner %s'):format(
                rec.name, serial or 'none', rack.id, index, owner),
            {
                rack = rack.id,
                slot = index,
                weapon = rec.name,
                serial = serial,
                owner = rack.owner,
                racked_by = rec.by,
            })
    end

    return res
end

---The details of a stored gun: serial, ammo, attachments, who racked it and when. For players who
---may use the rack, and for police.
---@param src integer
---@param payload table { rackId, slot }
---@return table response
function actions.inspect(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local rack, refusal = atRack(src, payload.rackId, 'query')

    if not rack then return refusal end

    local a = actor.of(src)

    if not (access.canUse(rack, a) or a.police) then
        return fail('err.no_access')
    end

    local index = slotOf(rack, payload.slot)
    local rec = index and rack.slots[index]

    if not rec then
        return fail('err.slot_empty')
    end

    local md = rec.metadata
    return ok({
        name = rec.name,
        label = inventory.label(rec.item),
        serial = weapons.serial(md),
        ammo = weapons.ammo(md),
        durability = inventory.durabilityOf(md),
        attachments = weapons.componentLabels(md, inventory.label),
        tint = weapons.tint(md),
        by = rec.byName or locale('inspect.unknown'),
        when = os.date('%Y-%m-%d %H:%M', rec.at or os.time()),
    })
end

---The guns the player carries that this empty slot accepts, for the "Choose weapon" menu. The
---candidates are the slot kind's fitted weapons plus the configured addon weapons whose group the
---kind takes (fit.accepts makes the final call), each looked up in the inventory under both
---spellings.
---@param src integer
---@param payload table { rackId, slot }
---@return table response { list = { { invSlot, weapon, label, ammo, serial } } }
function actions.listWeapons(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local rack, refusal = atRack(src, payload.rackId, 'query')

    if not rack then return refusal end

    if not access.canUse(rack, actor.of(src)) then
        return fail('err.no_access')
    end

    local index, def = slotOf(rack, payload.slot)

    if not index then
        return fail('err.bad_slot')
    end

    if rack.slots[index] or rack.claims[index] then
        return fail('err.slot_taken')
    end

    local rdef = fit.rack(rack.model)
    local kind = rdef.kinds and rdef.kinds[def.kind] or {}
    local candidates = {}
    for name in pairs((rdef.fits or {})[def.kind] or {}) do
        candidates[name] = true
    end

    local groups = {}
    for _, g in ipairs(kind.groups or {}) do
        groups[g] = true
    end

    for name, group in pairs(config.Weapons.Extra or {}) do
        if groups[group] then
            candidates[weapons.normalise(name)] = true
        end
    end

    local list, seen = {}, {}
    for name in pairs(candidates) do
        if not weapons.blocked(name, config.Weapons) and fit.accepts(rack.model, index, name) then
            for _, spelled in ipairs(spellings(name)) do
                for _, s in ipairs(inventory.getSlots(src, spelled) or {}) do
                    local key = tostring(s.slot) .. ':' .. spelled

                    if not seen[key] then
                        seen[key] = true
                        list[#list + 1] = {
                            invSlot = s.slot,
                            weapon = spelled,
                            label = inventory.label(spelled),
                            ammo = weapons.ammo(s.metadata),
                            serial = weapons.serial(s.metadata),
                        }
                    end
                end
            end
        end
    end

    table.sort(list, function(x, y)
        if x.label ~= y.label then
            return tostring(x.label) < tostring(y.label)
        end

        return tostring(x.invSlot) < tostring(y.invSlot)
    end)

    return ok({ list = list })
end


---Lock or unlock a rack (owner or admin). Unlocked racks can be used by anyone standing at them.
---@param src integer
---@param payload table { rackId, locked }
---@return table response
function actions.setLocked(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local rack, refusal = atRack(src, payload.rackId)

    if not rack then return refusal end

    if not access.canManage(rack, actor.of(src)) then
        return fail('err.not_owner')
    end

    local want = payload.locked == true

    if rack.locked == want then
        return ok({ locked = want })
    end

    rack.locked = want

    if not registry.saveLocked(rack) then
        rack.locked = not want
        return fail('err.save_failed')
    end

    sync.push(rack)
    audit.log('lock', src,
        ('%s rack %d'):format(want and 'locked' or 'unlocked', rack.id),
        { rack = rack.id, locked = want })

    return ok({ locked = want })
end

---Pick an empty rack back up (owner or admin): the rack item goes back into the inventory.
---@param src integer
---@param payload table { rackId }
---@return table response
function actions.pickup(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local rack, refusal = atRack(src, payload.rackId)

    if not rack then return refusal end

    if not access.canManage(rack, actor.of(src)) then
        return fail('err.not_owner')
    end

    if not registry.isEmpty(rack) then
        return fail('err.not_empty')
    end

    local item = actions.itemFor(rack.model)

    if not item then
        return fail('err.bad_model')
    end

    if not inventory.canCarry(src, item, 1) then
        return fail('err.cannot_carry')
    end

    rack.removing = true

    if not inventory.add(src, item, 1) then
        rack.removing = nil
        return fail('err.cannot_carry')
    end

    if not registry.destroy(rack) then
        inventory.remove(src, item, 1)
        rack.removing = nil
        return fail('err.save_failed')
    end

    sync.drop(rack)
    audit.log('pickup', src,
        ('picked up %s (rack %d)'):format(rackLabel(rack.model), rack.id),
        { rack = rack.id, model = rack.model })

    return ok({ id = rack.id })
end


-- Attempts in progress: started (item checked, police alerted) and waiting for the skill check's
-- result. A finish without a matching start, or one sooner than Force.MinSeconds, was not played.
---@type table<integer, { rackId: integer, at: integer }> at = GetGameTimer() ms
local forcing = {}

---Start forcing a locked rack: check the player may try and has the tool, tell their client to
---raise the police alert, and hand back the skill-check settings.
---@param src integer
---@param payload table { rackId }
---@return table response { difficulty, inputs }
function actions.forceStart(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local rack, refusal = atRack(src, payload.rackId)

    if not rack then return refusal end

    if not FORCE.Enabled then
        return fail('err.force_disabled')
    end

    local a = actor.of(src)

    if not rack.locked then
        return fail('err.force_not_locked')
    end

    if access.canUse(rack, a) then
        return fail('err.force_not_needed')
    end

    if not access.canForce(rack, a, FORCE) then
        return fail('err.force_disabled')
    end

    if FORCE.Item and not inventory.has(src, FORCE.Item, 1) then
        return fail('err.force_no_item', inventory.label(FORCE.Item))
    end

    local open = forcing[src]

    if open and GetGameTimer() - open.at < (FORCE.TimeoutSeconds or 45) * 1000 then
        return fail('err.force_busy')
    end

    forcing[src] = { rackId = rack.id, at = GetGameTimer() }

    if math.random() < (FORCE.AlertChance or 1.0) then
        TriggerClientEvent('sd-gunracks:client:policeAlert', src, {
            coords = { x = rack.coords.x, y = rack.coords.y, z = rack.coords.z },
            alert = FORCE.Alert,
        })
    end

    return ok({ difficulty = FORCE.Difficulty or { 'easy', 'medium' }, inputs = FORCE.Inputs })
end

---The skill check finished. Success unlocks the rack; failure may use up the tool. The rack must
---still be locked and the player still at it.
---@param src integer
---@param payload table { rackId, success }
---@return table response { unlocked, broke }
function actions.forceFinish(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local open = forcing[src]
    forcing[src] = nil
    local rackId = math.tointeger(tonumber(payload.rackId))

    if not open or open.rackId ~= rackId then
        audit.log('suspect', src,
            ('finished forcing rack %s without starting'):format(tostring(payload.rackId)),
            { reason = 'force_no_start', rack = payload.rackId })
        return fail('err.force_failed')
    end

    local rack, refusal = atRack(src, rackId)

    if not rack then return refusal end

    local elapsed = GetGameTimer() - open.at

    if elapsed > (FORCE.TimeoutSeconds or 45) * 1000 then
        return fail('err.force_failed')
    end

    local tooSoon = elapsed < (FORCE.MinSeconds or 1) * 1000

    if tooSoon then
        audit.log('suspect', src,
            ('force on rack %d reported after %d ms'):format(rack.id, elapsed),
            { reason = 'force_too_soon', rack = rack.id })
    end

    if payload.success == true and not tooSoon then
        if not rack.locked then
            return ok({ unlocked = true })
        end

        rack.locked = false

        if not registry.saveLocked(rack) then
            rack.locked = true
            return fail('err.save_failed')
        end

        sync.push(rack)
        audit.log('force', src,
            ('forced the lock on rack %d (owner %s)'):format(rack.id, tostring(rack.ownerName or rack.owner)),
            { rack = rack.id, result = 'success', owner = rack.owner })

        return ok({ unlocked = true })
    end

    local broke = false

    if FORCE.Item and math.random() < (FORCE.BreakChance or 0) then
        broke = inventory.remove(src, FORCE.Item, 1) and true or false
    end

    audit.log('force', src,
        ('failed to force rack %d%s'):format(rack.id, broke and ' (tool broke)' or ''),
        { rack = rack.id, result = 'fail', broke = broke, owner = rack.owner })

    return ok({ unlocked = false, broke = broke })
end

---Forget a departed player's open placement and lock attempt.
---@param src integer
function actions.forget(src)
    sessions[src] = nil
    forcing[src] = nil
end

return actions
