-- sd-gunracks server-logic harness. Runs the resource's real server modules under stock Lua 5.4 in
-- a fake FiveM environment (env.lua), with the bridge, oxmysql and shared/fit.lua faked
-- (stubs.lua), and drives placing, storing, taking, access and the integrity paths with fake
-- players.
--   lua tests/run.lua      -> PASS/FAIL per scenario, exit 0 only if all pass
--   lua tests/run.lua -v   -> also stream the resource's own log lines
--   GUNRACKS_RESOURCE=...  -> override the resource folder
local here = (arg and arg[0] or 'run.lua'):match('^(.*)[/\\]') or '.'
package.path = here .. '/?.lua;' .. package.path

local H = require 'env'
local S = require 'stubs'
local L = require 'loader'

for _, a in ipairs(arg or {}) do
    if a == '-v' or a == '--verbose' then
        H.verbose = true
    end
end

-- Everyone stands around the origin (racks go at x = 1.5, within Interact.Range of all of them),
-- except player 5, who is in another routing bucket.
local HOME = {
    [1] = { x = 0.0, y = 0.0, z = 30.0 },
    [2] = { x = 1.0, y = 0.0, z = 30.0 },
    [3] = { x = 0.0, y = 1.0, z = 30.0 },
    [4] = { x = -1.0, y = 0.0, z = 30.0 },
    [5] = { x = 0.0, y = 0.0, z = 30.0 },
    [6] = { x = 0.0, y = -1.0, z = 30.0 },
    [7] = { x = 1.0, y = 1.0, z = 30.0 },
}
H.addPlayer(1, { name = 'Owner Olsen' })
H.addPlayer(2, { name = 'Thief Tate' })
H.addPlayer(3, { name = 'Officer Ortiz', job = 'police', grade = 2 })
H.addPlayer(4, { name = 'Admin Ada', admin = true })
H.addPlayer(5, { name = 'Elsewhere Eli', bucket = 7 })
H.addPlayer(6, { name = 'Ballas Bo', gang = 'ballas', gangGrade = 1 })
H.addPlayer(7, { name = 'Cadet Cole', job = 'police', grade = 1 })
for src, p in pairs(HOME) do
    H.setPos(src, p)
end

L.loadServer()
---@type string[] The statements the boot thread sent, kept before the first reset wipes the log.
local BOOT_SQL = { table.unpack(H.db.log) }

local config   = require 'configs.config'
local registry = require 'server.racks.registry'
local sync     = require 'server.racks.sync'
local actions  = require 'server.racks.actions'
local weapons  = require 'shared.weapons'
local geo      = require 'shared.geo'
local access   = require 'shared.access'
local inv      = S.inventory

local function fmt(v)
    if type(v) == 'table' then
        local ok, s = pcall(json.encode, v)
        return ok and s or tostring(v)
    end

    return tostring(v)
end

local function check(cond, msg, ...)
    if not cond then
        local extra = {}
        for i = 1, select('#', ...) do
            extra[#extra + 1] = fmt((select(i, ...)))
        end

        error('ASSERT: ' .. msg .. (#extra > 0 and (' [' .. table.concat(extra, ' | ') .. ']') or ''), 2)
    end
end

local function eq(a, b, msg) check(a == b, ('%s: expected %s, got %s'):format(msg, fmt(b), fmt(a))) end
local function deepEq(a, b)
    if type(a) ~= type(b) then return false end

    if type(a) ~= 'table' then
        return a == b
    end

    for k, v in pairs(a) do
        if not deepEq(v, b[k]) then return false end
    end

    for k in pairs(b) do
        if a[k] == nil then return false end
    end

    return true
end

local function noErrors() check(#H.errors == 0, 'harness caught thread/handler errors', H.errors) end
local function refused(res, key, msg)
    check(res and res.success == false, msg .. ': expected a refusal', res)
    eq(res.message, key, msg)
end

---A callback as `src`, a second later (each scenario step is a separate player action, so the
---rate limiter never sees them back to back unless a scenario means it to).
local function call(name, src, payload)
    H.advance(1000)
    return H.call('sd-gunracks:server:' .. name, src, payload)
end

local SPOT = { x = 1.5, y = 0.0, z = 30.0 }
local function useItem(src, item)
    local slot = inv._give(src, item, 1)
    H.advance(1000)
    H.records.usable[item](src, nil, nil, slot)

    return slot
end

local function placeRack(src, item, pos, heading)
    useItem(src, item)
    local r = call('place', src, { coords = pos or SPOT, heading = heading or 0.0 })
    check(r and r.success, 'placeRack', r)

    return registry.get(r.data.id)
end

local function carbineMeta(serial)
    return { serial = serial or 'CARB-001', ammo = 30, durability = 87.5, registered = 'Owner Olsen',
        components = { 'at_flashlight', 'at_scope_medium' }, tint = 3 }
end

local function giveGun(src, name, meta) return inv._give(src, name, 1, meta) end
local function store(src, rack, slot, invSlot, weapon)
    return call('store', src, { rackId = rack.id, slot = slot, invSlot = invSlot, weapon = weapon })
end

local function dbSlots(id) return json.decode(H.db.rows[id].slots or '{}') end
---A staff console call (sd-gunracks:server:admin:<name>) as `src`, a second later.
local function console(name, src, payload)
    H.advance(1000)
    return H.call('sd-gunracks:server:admin:' .. name, src, payload)
end

---A console refusal: `{ ok = false, err }` with this locale key.
local function denied(res, key, msg)
    check(res and res.ok == false, msg .. ': expected a refusal', res)
    eq(res.err, key, msg)
end

local function auditCount(event, reason) return #H.auditEvents(event, reason) end

local usable = H.records.usable
---Fresh world between scenarios: empty table, empty inventories, everyone home, nobody synced.
local function reset()
    H.dbReset()
    registry.load()
    inv._reset()
    for src = 1, 7 do
        sync.forget(src)
        actions.forget(src)
        H.setPos(src, HOME[src])
        H.buckets[src] = src == 5 and 7 or 0
    end

    H.advance(5000)
    for k in pairs(H.aces) do
        H.aces[k] = nil
    end

    for k in pairs(H.offline) do
        H.offline[k] = nil
    end

    for k in pairs(H.records) do
        H.records[k] = {}
    end

    H.records.usable = usable
    H.errors = {}
end

local passed, failed = 0, 0
local function scenario(name, fn)
    reset()
    local ok, err = xpcall(fn, debug.traceback)

    if ok then
        passed = passed + 1
        H.out('PASS  ' .. name)
    else
        failed = failed + 1
        H.out('FAIL  ' .. name)
        H.out(err)
        H.dumpLog()
    end
end


scenario('boot: schema + every rack item registered as usable', function()
    check(BOOT_SQL[1] and BOOT_SQL[1]:find('^CREATE TABLE IF NOT EXISTS sd_gunracks'), 'schema created first', BOOT_SQL)
    eq(BOOT_SQL[2], 'SELECT * FROM sd_gunracks', 'then every rack loaded')
    for item in pairs(config.Racks.Items) do
        check(usable[item], 'usable registered for ' .. item)
    end

    check(H.commands.gunracks and H.commands.gunracks.props.restricted == 'group.admin', 'admin command restricted')
    noErrors()
end)

scenario('place: using the item opens placement; confirming creates a locked owned rack and takes the item', function()
    sync.payload(1)
    sync.payload(5)
    useItem(1, 'gunrack_oak')
    local ev = H.clientEvents('sd-gunracks:client:startPlacement', 0, 1)
    eq(#ev, 1, 'placement opened once')
    eq(ev[1].payload.model, 'sd_gunrack_oak', 'placement model')
    local mark = H.mark()
    local r = call('place', 1, { coords = SPOT, heading = 450.0 })
    check(r.success, 'place', r)
    local rack = registry.get(r.data.id)
    eq(rack.owner, 'CID1', 'owner')
    eq(rack.ownerName, 'Owner Olsen', 'owner name')
    eq(rack.locked, true, 'player racks start locked')
    eq(rack.heading, 90.0, 'heading normalised')
    eq(inv.count(1, 'gunrack_oak'), 0, 'item taken')
    check(H.db.rows[rack.id] and H.db.rows[rack.id].model == 'sd_gunrack_oak', 'row inserted')
    eq(#H.clientEvents('sd-gunracks:client:upsert', mark, 1), 1, 'owner told')
    eq(#H.clientEvents('sd-gunracks:client:upsert', mark, 5), 0, 'other bucket not told')
    eq(auditCount('place'), 1, 'place logged')

    local again = call('place', 1, { coords = { x = 3.0, y = 0.0, z = 30.0 }, heading = 0.0 })
    refused(again, 'err.no_placement', 'second confirm without a new item use')
    eq(auditCount('suspect', 'place_no_session'), 1, 'sessionless place logged suspect')
    noErrors()
end)

scenario('place limits: range, spacing, overlap, per-player cap, job restriction', function()
    useItem(1, 'gunrack_oak')
    refused(call('place', 1, { coords = { x = 9.0, y = 0.0, z = 30.0 }, heading = 0.0 }), 'err.too_far_place', 'beyond range')
    eq(inv.count(1, 'gunrack_oak'), 1, 'item kept after a refusal')
    refused(call('place', 1, { coords = { x = 0 / 0, y = 0.0, z = 30.0 }, heading = 0.0 }), 'err.bad_spot', 'NaN coords')
    check(call('place', 1, { coords = SPOT, heading = 0.0 }).success, 'first rack')

    useItem(1, 'gunrack_oak')
    refused(call('place', 1, { coords = { x = 1.6, y = 0.0, z = 30.0 }, heading = 0.0 }), 'err.spot_too_close', 'same spot')
    refused(call('place', 1, { coords = { x = 2.1, y = 0.0, z = 30.0 }, heading = 0.0 }), 'err.spot_overlap', 'boxes overlap')
    refused(call('place', 1, { coords = { x = 1.5, y = 0.3, z = 30.0 }, heading = 90.0 }), 'err.spot_overlap', 'turned box overlaps')
    check(call('place', 1, { coords = { x = 2.48, y = 0.0, z = 30.0 }, heading = 0.0 }).success, 'edge to edge is fine')

    local was = config.Placement.MaxPerPlayer
    config.Placement.MaxPerPlayer = 2
    local mark = H.mark()
    useItem(1, 'gunrack_oak')
    eq(#H.clientEvents('sd-gunracks:client:startPlacement', mark, 1), 0, 'no placement at the cap')
    check(H.records.notify[#H.records.notify].data.description == 'err.place_limit 2', 'cap notified', H.records.notify)
    config.Placement.MaxPerPlayer = was

    config.Placement.Jobs = { police = 0 }
    mark = H.mark()
    useItem(2, 'gunrack_oak')
    eq(#H.clientEvents('sd-gunracks:client:startPlacement', mark, 2), 0, 'civilian refused by job rule')
    useItem(3, 'gunrack_oak')
    eq(#H.clientEvents('sd-gunracks:client:startPlacement', mark, 3), 1, 'police allowed by job rule')
    config.Placement.Jobs = false
    noErrors()
end)

scenario('store + take: the gun keeps its exact metadata; clients only ever see name, components, tint', function()
    local rack = placeRack(1, 'gunrack_oak')
    sync.payload(1)
    sync.payload(2)
    local meta = carbineMeta()
    local slot = giveGun(1, 'WEAPON_CARBINERIFLE', meta)
    local mark = H.mark()
    local r = store(1, rack, 2, slot)
    check(r.success, 'store', r)
    eq(inv.count(1, 'WEAPON_CARBINERIFLE'), 0, 'gun left the inventory')
    local rec = rack.slots[2]
    eq(rec.name, 'WEAPON_CARBINERIFLE', 'stored name')
    eq(rec.by, 'CID1', 'racked by')
    eq(rec.byName, 'Owner Olsen', 'racked by name')
    check(deepEq(rec.metadata, meta), 'full metadata kept', rec.metadata)
    check(rec.metadata ~= meta, 'metadata copied, not shared with the inventory')
    eq(dbSlots(rack.id)['2'].metadata.serial, 'CARB-001', 'written through to the db')

    local mine = H.clientEvents('sd-gunracks:client:upsert', mark, 1)
    local theirs = H.clientEvents('sd-gunracks:client:upsert', mark, 2)
    eq(#mine, 1, 'owner got the delta')
    eq(#theirs, 1, 'bystander in the bucket got the delta')
    local v = theirs[1].payload
    local pub = v.slots[2]
    local keys = {}
    for k in pairs(pub) do
        keys[#keys + 1] = k
    end

    table.sort(keys)
    eq(table.concat(keys, ','), 'components,name,tint', 'public slot fields')
    eq(pub.tint, 3, 'tint')
    eq(table.concat(pub.components, ','), 'at_flashlight,at_scope_medium', 'ox components')
    check(not json.encode(v):find('CARB%-001'), 'serial must not reach clients', v)
    check(not json.encode(v):find('CID1'), 'owner id must not reach clients', v)
    check(v.owner == nil and v.access == nil and v.ownerName == nil, 'no private rack fields', v)
    eq(v.mine, false, 'not the bystander\'s')
    eq(v.allowed, false, 'bystander cannot open a locked rack')
    eq(mine[1].payload.mine, true, 'owner sees it as theirs')
    eq(mine[1].payload.manage, true, 'owner may manage')

    local t = call('take', 1, { rackId = rack.id, slot = 2 })
    check(t.success, 'take', t)
    local got = inv.getSlots(1, 'WEAPON_CARBINERIFLE')[1]
    check(got and deepEq(got.metadata, meta), 'same gun back', got)
    check(rack.slots[2] == nil, 'slot empty')
    check(next(dbSlots(rack.id)) == nil, 'db slots empty', H.db.rows[rack.id].slots)
    eq(auditCount('store'), 1, 'store logged')
    eq(auditCount('take'), 1, 'take logged')
    noErrors()
end)

scenario('take race: two players take the same gun at once -> exactly one gets it', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(call('setLocked', 1, { rackId = rack.id, locked = false }).success, 'unlock')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta())).success, 'store')
    H.db.latency = 200
    H.advance(1000)
    local r1, r2
    CreateThread(function() r1 = H.call('sd-gunracks:server:take', 1, { rackId = rack.id, slot = 1 }) end)
    CreateThread(function() r2 = H.call('sd-gunracks:server:take', 2, { rackId = rack.id, slot = 1 }) end)
    check(r1 == nil, 'first take is waiting on its db write', r1)
    refused(r2, 'err.slot_empty', 'second take while the first is in flight')
    H.run(1000)
    check(r1 and r1.success, 'first take completes', r1)
    eq(inv.count(1, 'WEAPON_CARBINERIFLE') + inv.count(2, 'WEAPON_CARBINERIFLE'), 1, 'one gun in total')
    check(next(rack.claims) == nil, 'no claim left behind')

    -- the same for two stores into one slot
    local a, b
    local sa, sb = giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('A')), giveGun(2, 'WEAPON_PUMPSHOTGUN', { serial = 'B', ammo = 2 })
    H.advance(1000)
    CreateThread(function() a = H.call('sd-gunracks:server:store', 1, { rackId = rack.id, slot = 3, invSlot = sa }) end)
    CreateThread(function() b = H.call('sd-gunracks:server:store', 2, { rackId = rack.id, slot = 3, invSlot = sb }) end)
    refused(b, 'err.slot_taken', 'second store into a claimed slot')
    H.run(1000)
    check(a and a.success, 'first store completes', a)
    eq(rack.slots[3].metadata.serial, 'A', 'the first gun is on the rack')
    eq(inv.count(2, 'WEAPON_PUMPSHOTGUN'), 1, 'the loser keeps their gun')
    H.db.latency = 0
    noErrors()
end)

scenario('give failure: a take that cannot be handed over leaves the gun on the rack', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta())).success, 'store')
    inv.full[1] = true
    refused(call('take', 1, { rackId = rack.id, slot = 1 }), 'err.cannot_carry', 'cannot carry')
    check(rack.slots[1] and next(rack.claims) == nil, 'slot restored, claim released')
    inv.full[1] = nil
    inv.failAdd[1] = true
    refused(call('take', 1, { rackId = rack.id, slot = 1 }), 'err.cannot_carry', 'add failed after canCarry')
    check(rack.slots[1], 'slot restored after the failed give')
    eq(dbSlots(rack.id)['1'].metadata.serial, 'CARB-001', 'db written back with the gun')
    eq(inv.count(1, 'WEAPON_CARBINERIFLE'), 0, 'nothing given')
    inv.failAdd[1] = nil
    H.db.failNext.update = 1
    refused(call('take', 1, { rackId = rack.id, slot = 1 }), 'err.save_failed', 'db write failed before the give')
    check(rack.slots[1], 'slot kept when the db write fails')
    eq(inv.count(1, 'WEAPON_CARBINERIFLE'), 0, 'nothing given when the db write fails')
    check(call('take', 1, { rackId = rack.id, slot = 1 }).success, 'take works once the inventory is fine')
    noErrors()
end)

scenario('store rollback: a failed removal or db write changes nothing', function()
    local rack = placeRack(1, 'gunrack_oak')
    local meta = carbineMeta()
    local slot = giveGun(1, 'WEAPON_CARBINERIFLE', meta)
    inv.failRemove[1] = true
    refused(store(1, rack, 1, slot), 'err.remove_failed', 'removal failed')
    check(rack.slots[1] == nil and next(rack.claims) == nil, 'slot untouched, claim released')
    eq(inv.count(1, 'WEAPON_CARBINERIFLE'), 1, 'gun still carried')
    inv.failRemove[1] = nil
    H.db.failNext.update = 1
    refused(store(1, rack, 1, slot), 'err.save_failed', 'db write failed')
    check(rack.slots[1] == nil and next(rack.claims) == nil, 'slot cleared again')
    local back = inv.getSlots(1, 'WEAPON_CARBINERIFLE')
    eq(#back, 1, 'gun handed back')
    check(deepEq(back[1].metadata, meta), 'handed back with its metadata', back[1])
    noErrors()
end)

scenario('access: owner, locked, unlocked, admin, who may manage', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta())).success, 'owner stores')
    refused(call('take', 2, { rackId = rack.id, slot = 1 }), 'err.no_access', 'stranger at a locked rack')
    refused(store(2, rack, 2, giveGun(2, 'WEAPON_PUMPSHOTGUN', { serial = 'T' })), 'err.no_access', 'stranger cannot store either')
    refused(call('setLocked', 2, { rackId = rack.id, locked = false }), 'err.not_owner', 'stranger cannot unlock')
    refused(call('pickup', 2, { rackId = rack.id }), 'err.not_owner', 'stranger cannot pick up')
    check(call('take', 4, { rackId = rack.id, slot = 1 }).success, 'admin opens a locked rack')
    check(store(4, rack, 1, inv.getSlots(4, 'WEAPON_CARBINERIFLE')[1].slot).success, 'admin puts it back')
    check(call('setLocked', 1, { rackId = rack.id, locked = false }).success, 'owner unlocks')
    eq(H.db.rows[rack.id].locked, 0, 'unlock written through')
    eq(auditCount('lock'), 1, 'lock change logged')
    check(call('take', 2, { rackId = rack.id, slot = 1 }).success, 'anyone at an unlocked rack')
    check(call('setLocked', 4, { rackId = rack.id, locked = true }).success, 'admin may lock any rack')
    -- the pure rules agree
    local r = { owner = 'CID1', locked = true }
    check(access.canUse(r, { identifier = 'CID1' }), 'owner always')
    check(not access.canUse(r, { identifier = 'CID2' }), 'stranger locked')
    check(access.canUse({ owner = 'CID1', locked = false }, { identifier = 'CID2' }), 'stranger unlocked')
    noErrors()
end)

scenario('job/gang restricted staff rack: grade gates, gangs, nobody else', function()
    local res = call('adminPlace', 4, { model = 'sd_gunrack_oak', coords = SPOT, heading = 0.0, locked = true,
        access = { jobs = { police = 2 }, gangs = { ballas = 1 } } })
    check(res.success, 'admin place', res)
    local rack = registry.get(res.data.id)
    check(rack.owner == nil, 'staff racks belong to nobody')
    eq(rack.access.jobs.police, 2, 'job grade stored')
    check(json.decode(H.db.rows[rack.id].access).gangs.ballas == 1, 'access written to the db')
    check(store(3, rack, 1, giveGun(3, 'WEAPON_PUMPSHOTGUN', { serial = 'PD-1', ammo = 8 })).success, 'police grade 2 stores')
    refused(call('take', 7, { rackId = rack.id, slot = 1 }), 'err.no_access', 'police grade 1 refused')
    refused(call('take', 2, { rackId = rack.id, slot = 1 }), 'err.no_access', 'civilian refused')
    check(call('take', 6, { rackId = rack.id, slot = 1 }).success, 'ballas grade 1 allowed')
    local v3 = sync.view(rack, require('server.racks.actor').of(3))
    eq(v3.allowed, true, 'police view allowed')
    eq(v3.manage, false, 'police cannot manage a staff rack')
    eq(sync.view(rack, require('server.racks.actor').of(2)).forceable, false, 'staff racks cannot be forced (default)')
    refused(call('adminPlace', 2, { model = 'sd_gunrack_oak', coords = { x = 3, y = 0, z = 30 }, heading = 0 }), 'err.admin_only', 'non-staff admin place')
    eq(auditCount('suspect', 'admin_not_staff'), 1, 'non-staff admin call logged')
    noErrors()
end)

scenario('police seize: any rack, logged with serial and owner; civilians cannot', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta())).success, 'store')
    refused(call('seize', 2, { rackId = rack.id, slot = 1 }), 'err.not_police', 'civilian seize')
    eq(auditCount('suspect', 'seize_not_police'), 1, 'civilian seize logged suspect')
    check(call('seize', 3, { rackId = rack.id, slot = 1 }).success, 'officer seizes from a locked rack')
    eq(inv.getSlots(3, 'WEAPON_CARBINERIFLE')[1].metadata.serial, 'CARB-001', 'officer holds the gun')
    local log = H.auditEvents('seize')[1]
    check(log and log.data.serial == 'CARB-001' and log.data.owner == 'CID1', 'seize logged with serial + owner', log)
    noErrors()
end)

scenario('force the lock: tool, police alert, too-soon, success unlocks, failure can break the tool', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta())).success, 'store')
    refused(call('forceStart', 2, { rackId = rack.id }), 'err.force_no_item lockpick', 'no lockpick')
    inv._give(2, 'lockpick', 2)
    local mark = H.mark()
    local st = call('forceStart', 2, { rackId = rack.id })
    check(st.success and st.data.difficulty, 'force start', st)
    local alerts = H.clientEvents('sd-gunracks:client:policeAlert', mark, 2)
    eq(#alerts, 1, 'police alert raised on the forcing client')
    eq(alerts[1].payload.coords.x, rack.coords.x, 'alert at the rack')

    H.advance(700)
    local early = H.call('sd-gunracks:server:forceFinish', 2, { rackId = rack.id, success = true })
    check(early.success and early.data.unlocked == false, 'a too-quick success counts as a fail', early)
    check(rack.locked, 'still locked')
    eq(auditCount('suspect', 'force_too_soon'), 1, 'too-quick finish logged')

    check(call('forceStart', 2, { rackId = rack.id }).success, 'second attempt')
    H.advance(3000)
    local done = H.call('sd-gunracks:server:forceFinish', 2, { rackId = rack.id, success = true })
    check(done.success and done.data.unlocked, 'honest success unlocks', done)
    check(not rack.locked, 'rack unlocked')
    eq(H.db.rows[rack.id].locked, 0, 'unlock written through')
    local flog = H.auditEvents('force')
    check(flog[#flog].data.result == 'success', 'force logged', flog)
    check(call('take', 2, { rackId = rack.id, slot = 1 }).success, 'thief takes from the forced rack')

    check(call('setLocked', 1, { rackId = rack.id, locked = true }).success, 'owner relocks')
    config.Interact.Force.BreakChance = 1.0
    check(call('forceStart', 2, { rackId = rack.id }).success, 'third attempt')
    H.advance(3000)
    local fail = H.call('sd-gunracks:server:forceFinish', 2, { rackId = rack.id, success = false })
    check(fail.success and fail.data.broke == true, 'failed attempt broke the pick', fail)
    eq(inv.count(2, 'lockpick'), 1, 'one lockpick used up')
    check(rack.locked, 'still locked after a fail')
    config.Interact.Force.BreakChance = 0.35

    refused(call('forceFinish', 2, { rackId = rack.id, success = true }), 'err.force_failed', 'finish without a start')
    eq(auditCount('suspect', 'force_no_start'), 1, 'sessionless finish logged')
    refused(call('forceStart', 1, { rackId = rack.id }), 'err.force_not_needed', 'owner has the key')
    check(call('setLocked', 1, { rackId = rack.id, locked = false }).success, 'owner unlocks')
    refused(call('forceStart', 2, { rackId = rack.id }), 'err.force_not_locked', 'nothing to force')
    noErrors()
end)

scenario('pickup: only an empty rack, only its owner; the item comes back', function()
    sync.payload(1)
    sync.payload(2)
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta())).success, 'store')
    refused(call('pickup', 1, { rackId = rack.id }), 'err.not_empty', 'rack with a gun')
    refused(call('pickup', 2, { rackId = rack.id }), 'err.not_owner', 'not the owner')
    check(call('take', 1, { rackId = rack.id, slot = 1 }).success, 'take')
    local mark = H.mark()
    check(call('pickup', 1, { rackId = rack.id }).success, 'pickup')
    eq(inv.count(1, 'gunrack_oak'), 1, 'item back')
    check(registry.get(rack.id) == nil and H.db.rows[rack.id] == nil, 'rack gone from memory and db')
    eq(#H.clientEvents('sd-gunracks:client:remove', mark, 2), 1, 'bucket told it is gone')
    eq(auditCount('pickup'), 1, 'pickup logged')
    noErrors()
end)

scenario('routing buckets: each client gets only its bucket; deltas stay in it; a bucket change resyncs', function()
    local a = placeRack(1, 'gunrack_oak')
    H.setPos(5, SPOT)
    local b = placeRack(5, 'gunrack_oak')
    eq(b.bucket, 7, 'placed in the placer\'s bucket')
    local p1, p5 = sync.payload(1), sync.payload(5)
    eq(#p1.racks, 1, 'bucket 0 list size')
    eq(p1.racks[1].id, a.id, 'bucket 0 sees its rack')
    eq(#p5.racks, 1, 'bucket 7 list size')
    eq(p5.racks[1].id, b.id, 'bucket 7 sees its rack')

    local mark = H.mark()
    check(store(5, b, 1, giveGun(5, 'WEAPON_CARBINERIFLE', carbineMeta('E1'))).success, 'store in bucket 7')
    eq(#H.clientEvents('sd-gunracks:client:upsert', mark, 5), 1, 'bucket 7 told')
    eq(#H.clientEvents('sd-gunracks:client:upsert', mark, 1), 0, 'bucket 0 not told')
    refused(call('take', 1, { rackId = b.id, slot = 1 }), 'err.no_rack', 'rack from another bucket')
    eq(auditCount('suspect', 'wrong_bucket'), 1, 'cross-bucket use logged')

    mark = H.mark()
    H.buckets[1] = 7
    H.run(4500)
    local ev = H.clientEvents('sd-gunracks:client:sync', mark, 1)
    check(#ev >= 1, 'bucket change resynced', ev)
    eq(ev[#ev].payload.bucket, 7, 'new bucket')
    eq(#ev[#ev].payload.racks, 1, 'only the new bucket\'s racks')
    eq(ev[#ev].payload.racks[1].id, b.id, 'the bucket 7 rack')

    mark = H.mark()
    H.players[2].job = 'police'
    sync.payload(2)
    H.players[2].job = 'unemployed'
    H.run(2500)
    check(#H.clientEvents('sd-gunracks:client:sync', mark, 2) >= 1, 'job change resynced')
    mark = H.mark()
    H.loadedHandlers[1](2)
    eq(#H.clientEvents('sd-gunracks:client:sync', mark, 2), 1, 'character load resynced')
    noErrors()
end)

scenario('public view: qb attachments + lowercase weapon names round-trip', function()
    local rack = placeRack(1, 'gunrack_oak')
    sync.payload(1)
    local info = { serie = 'QB-77', ammo = 6, quality = 90, tint = 2,
        attachments = { { component = 'COMPONENT_AT_AR_FLSH', label = 'Flashlight' } } }
    inv._give(1, 'weapon_pumpshotgun', 1, info)
    local mark = H.mark()
    local r = store(1, rack, 1, nil, 'weapon_pumpshotgun')
    check(r.success, 'store by name (no slot id)', r)
    eq(rack.slots[1].name, 'WEAPON_PUMPSHOTGUN', 'normalised to uppercase')
    eq(rack.slots[1].item, 'weapon_pumpshotgun', 'inventory spelling kept for the give-back')
    local v = H.clientEvents('sd-gunracks:client:upsert', mark, 1)[1].payload
    eq(v.slots[1].components[1], 'COMPONENT_AT_AR_FLSH', 'qb attachment as a component string')
    eq(v.slots[1].tint, 2, 'qb tint')
    check(not json.encode(v):find('QB%-77'), 'serial must not reach clients')
    local i = call('inspect', 1, { rackId = rack.id, slot = 1 })
    eq(i.data.serial, 'QB-77', 'qb serial read')
    eq(i.data.attachments[1], 'Flashlight', 'qb attachment label')
    check(call('take', 1, { rackId = rack.id, slot = 1 }).success, 'take')
    eq(inv.count(1, 'weapon_pumpshotgun'), 1, 'given back under the inventory\'s own name')
    eq(weapons.publicSlot({ name = 'X', metadata = { serial = 's', components = { 'a', 7 } } }).components[2], nil, 'non-strings dropped')
    noErrors()
end)

scenario('what a slot accepts: blacklist, wrong kind, non-weapons, bad slots, lying clients', function()
    local rack = placeRack(1, 'gunrack_oak')
    refused(store(1, rack, 1, giveGun(1, 'WEAPON_RPG', { serial = 'R' })), 'err.blacklisted', 'blacklisted even though fitted')
    refused(store(1, rack, 1, giveGun(1, 'WEAPON_PISTOL', { serial = 'P' })), 'err.no_fit', 'pistol in a long-gun slot')
    refused(store(1, rack, 1, inv._give(1, 'water', 1)), 'err.not_weapon', 'not a weapon')
    eq(auditCount('suspect', 'not_weapon'), 1, 'non-weapon logged')
    local carb = giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta())
    refused(store(1, rack, 9, carb), 'err.bad_slot', 'slot the rack does not have')
    eq(auditCount('suspect', 'bad_slot'), 1, 'bad slot logged')
    refused(store(1, rack, 1, carb, 'WEAPON_PUMPSHOTGUN'), 'err.no_weapon', 'slot id and weapon name disagree')
    refused(store(1, rack, 1, 999), 'err.no_weapon', 'empty inventory slot')
    eq(inv.count(1, 'WEAPON_RPG') + inv.count(1, 'WEAPON_PISTOL') + inv.count(1, 'WEAPON_CARBINERIFLE'), 3, 'nothing was taken')
    local peg = placeRack(1, 'gunrack_pegboard', { x = -1.5, y = 0.0, z = 30.0 }, 0.0)
    check(store(1, peg, 2, giveGun(1, 'WEAPON_PISTOL', { serial = 'P2' })).success, 'pistol on the pegboard\'s pistol slot')
    refused(store(1, peg, 1, giveGun(1, 'WEAPON_PISTOL', { serial = 'P3' })), 'err.no_fit', 'pistol on the pegboard\'s long slot')
    noErrors()
end)

scenario('persistence: a reload brings back racks, guns and lock state', function()
    local rack = placeRack(1, 'gunrack_oak', SPOT, 123.0)
    check(store(1, rack, 3, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('KEEP-1'))).success, 'store in slot 3')
    check(call('setLocked', 1, { rackId = rack.id, locked = false }).success, 'unlock')
    local n = registry.load()
    eq(n, 1, 'one rack loaded')
    local again = registry.get(rack.id)
    check(again ~= rack, 'a fresh object from the db')
    eq(again.slots[3].metadata.serial, 'KEEP-1', 'gun metadata reloaded')
    eq(again.slots[3].metadata.components[2], 'at_scope_medium', 'nested arrays reloaded')
    eq(again.slots[3].by, 'CID1', 'who racked it reloaded')
    eq(again.locked, false, 'lock state reloaded')
    eq(again.owner, 'CID1', 'owner reloaded')
    check(math.abs(again.heading - 123.0) < 1e-6, 'heading reloaded')
    check(again.slots[1] == nil and again.slots[2] == nil, 'empty slots stay empty')
    check(call('take', 2, { rackId = rack.id, slot = 3 }).success, 'reloaded rack works')
    noErrors()
end)

scenario('choose weapon: only the guns this slot takes, with ammo + serial; addon extras by group', function()
    local rack = placeRack(1, 'gunrack_oak')
    config.Weapons.Extra.WEAPON_M4A1 = 'GROUP_RIFLE'
    config.Weapons.Extra.WEAPON_GLOCK = 'GROUP_PISTOL'
    local carb = giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('C1'))
    giveGun(1, 'WEAPON_PUMPSHOTGUN', { serial = 'S1', ammo = 4 })
    giveGun(1, 'WEAPON_PISTOL', { serial = 'P1', ammo = 12 })
    giveGun(1, 'WEAPON_RPG', { ammo = 1 })
    local m4 = giveGun(1, 'WEAPON_M4A1', { serial = 'M1', ammo = 25 })
    giveGun(1, 'WEAPON_GLOCK', { serial = 'G1' })
    H.labels.WEAPON_CARBINERIFLE, H.labels.WEAPON_PUMPSHOTGUN, H.labels.WEAPON_M4A1 = 'Carbine Rifle', 'Pump Shotgun', 'M4A1'
    local r = call('listWeapons', 1, { rackId = rack.id, slot = 1 })
    check(r.success, 'list', r)
    local names = {}
    for _, w in ipairs(r.data.list) do
        names[#names + 1] = w.weapon
    end

    eq(table.concat(names, ','), 'WEAPON_CARBINERIFLE,WEAPON_M4A1,WEAPON_PUMPSHOTGUN', 'accepted guns, sorted by label')
    eq(r.data.list[1].invSlot, carb, 'slot id')
    eq(r.data.list[1].ammo, 30, 'ammo')
    eq(r.data.list[1].serial, 'C1', 'serial')
    check(store(1, rack, 1, m4).success, 'an addon gun stores through its group')
    refused(call('listWeapons', 1, { rackId = rack.id, slot = 1 }), 'err.slot_taken', 'list for a taken slot')
    refused(call('listWeapons', 2, { rackId = rack.id, slot = 2 }), 'err.no_access', 'stranger at a locked rack')
    config.Weapons.Extra.WEAPON_M4A1, config.Weapons.Extra.WEAPON_GLOCK = nil, nil
    noErrors()
end)

scenario('inspect: users and police see serial + who racked it; strangers at a locked rack do not', function()
    local rack = placeRack(1, 'gunrack_oak')
    H.labels.at_flashlight, H.labels.at_scope_medium = 'Flashlight', 'Medium Scope'
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta())).success, 'store')
    local i = call('inspect', 1, { rackId = rack.id, slot = 1 })
    check(i.success, 'owner inspects', i)
    eq(i.data.serial, 'CARB-001', 'serial')
    eq(i.data.ammo, 30, 'ammo')
    eq(i.data.durability, 87.5, 'condition')
    eq(table.concat(i.data.attachments, ', '), 'Flashlight, Medium Scope', 'attachment labels')
    eq(i.data.by, 'Owner Olsen', 'racked by')
    check(type(i.data.when) == 'string' and i.data.when:match('^%d+%-%d+%-%d+ %d+:%d+$'), 'racked when', i.data.when)
    refused(call('inspect', 2, { rackId = rack.id, slot = 1 }), 'err.no_access', 'stranger')
    check(call('inspect', 3, { rackId = rack.id, slot = 1 }).success, 'police may inspect')
    refused(call('inspect', 1, { rackId = rack.id, slot = 2 }), 'err.slot_empty', 'empty slot')
    noErrors()
end)

scenario('staff console: delete returns the guns (or keeps the rack), the rack list, give items', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('D1'))).success, 'store 1')
    check(store(1, rack, 2, giveGun(1, 'WEAPON_PUMPSHOTGUN', { serial = 'D2', ammo = 3 })).success, 'store 2')
    placeRack(2, 'gunrack_oak', { x = 1.5, y = 2.0, z = 30.0 }, 0.0)

    local list = console('getRacks', 4)
    check(list.list and #list.list == 2, 'two racks listed', list)
    eq(list.list[1].ownerName, 'Owner Olsen', 'by id, with owner')
    eq(list.list[1].stored, 2, 'stored count')
    denied(console('getRacks', 2), 'err.admin_only', 'non-staff list')

    inv.full[4] = true
    denied(console('deleteRack', 4, { rackId = rack.id }), 'admin.delete_partial 0 2', 'admin cannot carry the guns')
    check(registry.get(rack.id) and registry.storedCount(rack) == 2 and not rack.removing, 'rack kept, guns intact')
    inv.full[4] = nil
    local del = console('deleteRack', 4, { rackId = rack.id })
    check(del.ok and del.given == 2, 'deleted with both guns returned', del)
    eq(inv.getSlots(4, 'WEAPON_CARBINERIFLE')[1].metadata.serial, 'D1', 'admin got gun 1')
    eq(inv.getSlots(4, 'WEAPON_PUMPSHOTGUN')[1].metadata.serial, 'D2', 'admin got gun 2')
    check(registry.get(rack.id) == nil and H.db.rows[rack.id] == nil, 'rack gone')
    denied(console('deleteRack', 4, { rackId = rack.id }), 'err.no_rack', 'deleting it twice')

    local g = console('giveItem', 4, { target = 2, item = 'gunrack_walnut', count = 99 })
    check(g.ok, 'give', g)
    eq(inv.count(2, 'gunrack_walnut'), config.Admin.MaxGive, 'count capped')
    eq(g.targetName, 'Thief Tate', 'named who got it')
    denied(console('giveItem', 4, { target = 2, item = 'water', count = 1 }), 'err.bad_model', 'not a rack item')
    denied(console('giveItem', 4, { target = 99, item = 'gunrack_oak', count = 1 }), 'err.no_player', 'no such player')
    denied(console('giveItem', 2, { target = 2, item = 'gunrack_oak' }), 'err.admin_only', 'non-staff give')
    eq(#H.auditEvents('admin'), 3, 'partial delete, delete and give logged')
    noErrors()
end)

scenario('exports: CreateRack / GetRack / GetRacks / DeleteRack', function()
    local id, err = H.exports.CreateRack('sd_gunrack_pistols', vec3(10.0, 10.0, 30.0), 180.0,
        { bucket = 0, owner = 'CID9', ownerName = 'House Owner', access = { jobs = { police = 0 } } })
    check(id, 'created', err)
    local copy = H.exports.GetRack(id)
    eq(copy.owner, 'CID9', 'copy owner')
    eq(copy.access.jobs.police, 0, 'copy access')
    copy.slots[1] = { name = 'X' }
    check(registry.get(id).slots[1] == nil, 'GetRack is a detached copy')
    eq(#H.exports.GetRacks(), 1, 'GetRacks')
    local nid, why = H.exports.CreateRack('sd_gunrack_pistols', vec3(10.1, 10.0, 30.0), 180.0, {})
    check(nid == nil and why == 'too_close', 'spacing applies to exports', why)
    check(H.exports.CreateRack('nope', vec3(0, 0, 0), 0) == nil, 'unknown model refused')

    local rack = registry.get(id)
    rack.slots[1] = { name = 'WEAPON_PISTOL', item = 'WEAPON_PISTOL', metadata = { serial = 'EXP-1' }, by = 'CID9', at = os.time() }
    registry.saveSlots(rack)
    local ok, guns = H.exports.DeleteRack(id)
    check(ok and #guns == 1 and guns[1].metadata.serial == 'EXP-1', 'deleted, guns handed to the caller', guns)
    check(registry.get(id) == nil and H.db.rows[id] == nil, 'gone')

    local id2 = H.exports.CreateRack('sd_gunrack_pistols', vec3(1.5, 0.0, 30.0), 0.0, { owner = 'CID1' })
    registry.get(id2).slots[2] = { name = 'WEAPON_PISTOL', item = 'WEAPON_PISTOL', metadata = { serial = 'EXP-2' }, by = 'CID1', at = os.time() }
    inv.full[1] = true
    local ok2, why2 = H.exports.DeleteRack(id2, 1)
    check(not ok2 and why2 == 'cannot_carry' and registry.get(id2), 'kept when the player cannot carry', why2)
    inv.full[1] = nil
    check(H.exports.DeleteRack(id2, 1), 'deleted into the player')
    eq(inv.getSlots(1, 'WEAPON_PISTOL')[1].metadata.serial, 'EXP-2', 'player got the gun')
    noErrors()
end)

scenario('delete with guns: a failed write hands nothing out and leaves the rack as it was', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('W1'))).success, 'store 1')
    check(store(1, rack, 2, giveGun(1, 'WEAPON_PUMPSHOTGUN', { serial = 'W2', ammo = 2 })).success, 'store 2')

    H.db.failNext.update = 1
    denied(console('deleteRack', 4, { rackId = rack.id }), 'err.save_failed', 'staff delete: the write failed')
    eq(inv.count(4, 'WEAPON_CARBINERIFLE') + inv.count(4, 'WEAPON_PUMPSHOTGUN'), 0, 'nothing handed to the admin')
    check(registry.get(rack.id) == rack and not rack.removing, 'rack still there and usable')
    check(rack.slots[1] and rack.slots[2], 'both guns still on it', rack.slots)

    local db = dbSlots(rack.id)

    check(db['1'] and db['1'].metadata.serial == 'W1' and db['2'] and db['2'].metadata.serial == 'W2', 'and in the database', db)

    H.db.failNext.update = 1

    local ok, why = H.exports.DeleteRack(rack.id, 2)

    check(not ok and why == 'save_failed', 'export: the write failed', why)
    eq(inv.count(2, 'WEAPON_CARBINERIFLE') + inv.count(2, 'WEAPON_PUMPSHOTGUN'), 0, 'nothing handed to the player')
    check(registry.get(rack.id) == rack and not rack.removing and rack.slots[1] and rack.slots[2], 'rack unchanged')
    check(next(dbSlots(rack.id)) ~= nil and dbSlots(rack.id)['2'].metadata.serial == 'W2', 'database unchanged')
    noErrors()
end)

scenario('delete with guns: the emptied slots are written before any gun is handed out', function()
    local realAdd = inv.add
    local rack, writtenFirst

    ---Run `fn` with every give recording whether the rack's row already had its slots written empty.
    local function watchGives(fn)
        writtenFirst = {}
        inv.add = function(src, item, count, metadata)
            writtenFirst[#writtenFirst + 1] = next(dbSlots(rack.id)) == nil

            return realAdd(src, item, count, metadata)
        end

        local a, b = fn()

        inv.add = realAdd

        return a, b
    end

    rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('O1'))).success, 'store 1')
    check(store(1, rack, 2, giveGun(1, 'WEAPON_PUMPSHOTGUN', { serial = 'O2', ammo = 2 })).success, 'store 2')

    local del = watchGives(function() return console('deleteRack', 4, { rackId = rack.id }) end)

    check(del.ok and del.given == 2, 'staff delete with both guns returned', del)
    check(#writtenFirst == 2 and writtenFirst[1] and writtenFirst[2], 'each give came after the write', writtenFirst)
    eq(inv.getSlots(4, 'WEAPON_CARBINERIFLE')[1].metadata.serial, 'O1', 'admin got gun 1')
    eq(inv.getSlots(4, 'WEAPON_PUMPSHOTGUN')[1].metadata.serial, 'O2', 'admin got gun 2')
    check(registry.get(rack.id) == nil and H.db.rows[rack.id] == nil, 'rack gone')

    rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 3, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('O3'))).success, 'store 3')

    local ok = watchGives(function() return H.exports.DeleteRack(rack.id, 2) end)

    check(ok, 'export deleted it into the player')
    check(#writtenFirst == 1 and writtenFirst[1], 'the give came after the write', writtenFirst)
    eq(inv.getSlots(2, 'WEAPON_CARBINERIFLE')[1].metadata.serial, 'O3', 'player got the gun')
    check(registry.get(rack.id) == nil and H.db.rows[rack.id] == nil, 'rack gone')
    noErrors()
end)

scenario('delete with guns: a give that fails part way puts the rest back on the rack', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('P1'))).success, 'store 1')
    check(store(1, rack, 2, giveGun(1, 'WEAPON_PUMPSHOTGUN', { serial = 'P2', ammo = 2 })).success, 'store 2')
    check(store(1, rack, 3, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('P3'))).success, 'store 3')

    inv.addsLeft[4] = 1
    denied(console('deleteRack', 4, { rackId = rack.id }), 'admin.delete_partial 1 2', 'staff delete: the second give failed')
    inv.addsLeft[4] = nil
    eq(#inv.getSlots(4, 'WEAPON_CARBINERIFLE') + #inv.getSlots(4, 'WEAPON_PUMPSHOTGUN'), 1, 'the admin got one gun')
    eq(inv.getSlots(4, 'WEAPON_CARBINERIFLE')[1].metadata.serial, 'P1', 'the first')
    check(registry.get(rack.id) == rack and not rack.removing, 'rack kept')
    check(rack.slots[1] == nil and rack.slots[2] and rack.slots[3], 'the other two back on it', rack.slots)

    local db = dbSlots(rack.id)

    check(db['1'] == nil and db['2'].metadata.serial == 'P2' and db['3'].metadata.serial == 'P3', 'and in the database', db)

    inv.addsLeft[2] = 1

    local ok, why = H.exports.DeleteRack(rack.id, 2)

    inv.addsLeft[2] = nil
    check(not ok and why == 'cannot_carry', 'export: the second give failed', why)
    eq(#inv.getSlots(2, 'WEAPON_CARBINERIFLE') + #inv.getSlots(2, 'WEAPON_PUMPSHOTGUN'), 1, 'the player got one gun')
    eq(inv.getSlots(2, 'WEAPON_PUMPSHOTGUN')[1].metadata.serial, 'P2', 'the next one')
    check(registry.get(rack.id) == rack and not rack.removing, 'rack kept')
    check(rack.slots[2] == nil and rack.slots[3], 'the last gun back on it', rack.slots)

    db = dbSlots(rack.id)

    check(db['2'] == nil and db['3'] and db['3'].metadata.serial == 'P3', 'and in the database', db)
    eq(#H.auditEvents('admin'), 1, 'the partial staff delete logged')
    noErrors()
end)

scenario('integrity: rate limit (logged once), range, unknown racks', function()
    local rack = placeRack(1, 'gunrack_oak')
    local a = giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('R1'))
    local b = giveGun(1, 'WEAPON_PUMPSHOTGUN', { serial = 'R2' })
    H.advance(1000)
    check(H.call('sd-gunracks:server:store', 1, { rackId = rack.id, slot = 1, invSlot = a }).success, 'first store')
    H.advance(100)
    refused(H.call('sd-gunracks:server:store', 1, { rackId = rack.id, slot = 2, invSlot = b }), 'err.too_fast', 'hammering')
    H.advance(100)
    refused(H.call('sd-gunracks:server:store', 1, { rackId = rack.id, slot = 2, invSlot = b }), 'err.too_fast', 'still hammering')
    eq(auditCount('suspect', 'rate_limited'), 1, 'rate limit logged once per window')
    H.setPos(2, { x = 20.0, y = 0.0, z = 30.0 })
    check(call('setLocked', 1, { rackId = rack.id, locked = false }).success, 'unlock')
    refused(call('take', 2, { rackId = rack.id, slot = 1 }), 'err.too_far', 'too far from the rack')
    refused(call('take', 1, { rackId = 4242, slot = 1 }), 'err.no_rack', 'no such rack')
    refused(call('take', 1, { rackId = 'x' }), 'err.no_rack', 'garbage id')
    noErrors()
end)

scenario('geometry: wall heading, rack-space transforms, box overlap', function()
    eq(geo.wallHeading(0.0, -1.0), 0.0, 'wall facing -Y: no turn')
    eq(geo.wallHeading(1.0, 0.0), 90.0, 'wall facing +X')
    eq(geo.wallHeading(0.0, 1.0), 180.0, 'wall facing +Y')
    eq(geo.wallHeading(-1.0, 0.0), 270.0, 'wall facing -X')
    -- local -Y (the front) must end up along the wall normal
    for _, n in ipairs({ { 1, 0 }, { 0, 1 }, { -0.6, 0.8 } }) do
        local h = geo.wallHeading(n[1], n[2])
        local x, y = geo.toWorld({ x = 0, y = 0, z = 0 }, h, { 0.0, -1.0, 0.0 })
        check(math.abs(x - n[1]) < 1e-9 and math.abs(y - n[2]) < 1e-9, 'front along the normal', n, x, y)
    end

    local x, y, z = geo.toWorld({ x = 10, y = 20, z = 30 }, 90.0, { 0.0, 1.0, 0.5 })
    check(math.abs(x - 9.0) < 1e-9 and math.abs(y - 20.0) < 1e-9 and z == 30.5, 'GTA heading: local +Y -> (-sin, cos)', x, y, z)
    local def = { min = { -0.5, -0.1, 0.0 }, max = { 0.5, 0.1, 1.0 } }
    check(geo.overlaps(geo.box(def, { x = 0, y = 0, z = 0 }, 0), geo.box(def, { x = 0.9, y = 0, z = 0 }, 0)), 'side by side, overlapping')
    check(not geo.overlaps(geo.box(def, { x = 0, y = 0, z = 0 }, 0), geo.box(def, { x = 1.0, y = 0, z = 0 }, 0)), 'edge to edge')
    check(not geo.overlaps(geo.box(def, { x = 0, y = 0, z = 0 }, 0), geo.box(def, { x = 0, y = 0, z = 1.0 }, 0)), 'stacked above')
    check(geo.overlaps(geo.box(def, { x = 0, y = 0, z = 0 }, 0), geo.box(def, { x = 0.3, y = 0.3, z = 0 }, 90)), 'crossed')
    noErrors()
end)


-- ------------------------------------------------------------------------------------------------
-- The staff console (server/racks/admin.lua handlers, server/racks/views.lua, the log table)
-- ------------------------------------------------------------------------------------------------

scenario('console: every call refuses non-staff (logged); the configurable ace and the command ace both count', function()
    local names = require 'shared.admin_callbacks'
    local rack = placeRack(1, 'gunrack_oak')
    for _, name in ipairs(names) do
        denied(console(name, 2, { rackId = rack.id, id = rack.id, slot = 1, locked = false, target = '2', access = { jobs = {} } }),
            'err.admin_only', 'non-staff ' .. name)
    end

    eq(auditCount('suspect', 'admin_not_staff'), #names, 'each refusal logged as suspect')
    check(registry.get(rack.id) and rack.locked and rack.owner == 'CID1', 'nothing changed')

    local mark = H.mark()
    H.command('gunracks', 2)
    eq(#H.clientEvents('sd-gunracks:client:admin:open', mark, 2), 0, 'the command does not open it for a player')
    H.command('gunracks', 4)
    local ev = H.clientEvents('sd-gunracks:client:admin:open', mark, 4)
    eq(#ev, 1, 'the command opens it for staff')
    eq(ev[1].payload.perms.admin, true, 'perms sent')
    eq(ev[1].payload.perms.delete, true, 'delete allowed by default')
    eq(ev[1].payload.pollMs.racks, 6000, 'poll periods in ms')
    eq(H.auditEvents('admin')[1].data.action, 'open', 'opening logged')

    -- Not in the admin group, but granted the console's own ace: allowed in, and at every rack.
    H.aces[2] = { [config.Admin.Ace] = true }
    check(console('getRacks', 2).list, 'the configurable ace opens the console')
    check(call('take', 2, { rackId = rack.id, slot = 1 }).message == 'err.slot_empty', 'and counts as staff at a locked rack')
    H.aces[2] = { ['command.' .. config.Admin.Command] = true }
    check(console('getRacks', 2).list, 'the command ace alone also counts')
    H.aces[2] = nil
    denied(console('getOverview', 2), 'err.admin_only', 'and without either, refused again')
    noErrors()
end)

scenario('console: overview, rack list, one rack with its slots, the catalog', function()
    local mine = placeRack(1, 'gunrack_oak')
    check(store(1, mine, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('OV-1'))).success, 'store')
    local res = call('adminPlace', 4, { model = 'sd_gunrack_oak', coords = { x = 1.5, y = 2.0, z = 30.0 }, heading = 0.0, locked = true,
        access = { jobs = { police = 2 } } })
    check(res.success, 'staff rack', res)

    local o = console('getOverview', 4)
    eq(o.racks, 2, 'racks')
    eq(o.guns, 1, 'guns')
    eq(o.slots, 6, 'slots')
    eq(o.locked, 2, 'locked')
    eq(o.staff, 1, 'staff racks')
    eq(o.restricted, 1, 'with an access list')
    eq(o.owners, 1, 'owners')
    eq(o.byModel[1].model, 'sd_gunrack_oak', 'by model')
    eq(o.byModel[1].count, 2, 'by model count')
    check(#o.recent >= 3, 'recent activity from the log table', o.recent)
    eq(o.recent[1].kind, 'admin.place', 'newest first, staff action refined')

    local list = console('getRacks', 4).list
    eq(#list, 2, 'both racks')
    local staffRow = list[2]
    check(staffRow.owner == nil, 'a staff rack has no owner')
    eq(staffRow.access.jobs[1].name, 'police', 'access as a list')
    eq(staffRow.access.jobs[1].grade, 2, 'with its grade')
    eq(#staffRow.access.gangs, 0, 'empty side as an empty list')
    eq(list[1].ownerOnline, true, 'owner is on')

    local d = console('getRack', 4, { id = mine.id })
    eq(#d.slots, 3, 'every slot')
    eq(d.slots[1].gun.serial, 'OV-1', 'stored gun serial')
    eq(d.slots[1].gun.ammo, 30, 'ammo')
    eq(d.slots[1].gun.byName, 'Owner Olsen', 'who racked it')
    eq(d.slots[1].kindLabel, 'Long gun', 'what the slot takes')
    check(d.slots[2].gun == nil, 'an empty slot has no gun')
    denied(console('getRack', 4, { id = 999 }), 'err.no_rack', 'unknown rack')

    local c = console('getCatalog', 4)
    eq(#c.models, 3, 'every model the fits know')
    eq(c.maxGive, config.Admin.MaxGive, 'give cap')
    local pegboard

    for _, m in ipairs(c.models) do
        if m.model == 'sd_gunrack_pegboard' then
            pegboard = m
        end
    end

    eq(#pegboard.kinds, 2, 'a model with two kinds of slot')
    eq(pegboard.item, 'gunrack_pegboard', 'and its item')
    noErrors()
end)

scenario('console: take one gun into the admin inventory: claimed, rolled back on a failed give, never duplicated', function()
    local rack = placeRack(1, 'gunrack_oak')
    local meta = carbineMeta('TK-1')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', meta)).success, 'store')

    inv.full[4] = true
    denied(console('takeGun', 4, { rackId = rack.id, slot = 1 }), 'err.cannot_carry', 'admin cannot carry')
    check(rack.slots[1] and next(rack.claims) == nil, 'slot restored, claim released')
    inv.full[4] = nil
    inv.failAdd[4] = true
    denied(console('takeGun', 4, { rackId = rack.id, slot = 1 }), 'err.cannot_carry', 'the give failed after canCarry')
    check(rack.slots[1], 'slot restored after the failed give')
    eq(dbSlots(rack.id)['1'].metadata.serial, 'TK-1', 'db written back with the gun')
    inv.failAdd[4] = nil
    H.db.failNext.update = 1
    denied(console('takeGun', 4, { rackId = rack.id, slot = 1 }), 'err.save_failed', 'db write failed before the give')
    check(rack.slots[1], 'slot kept when the db write fails')
    eq(inv.count(4, 'WEAPON_CARBINERIFLE'), 0, 'nothing given yet')
    denied(console('takeGun', 4, { rackId = rack.id, slot = 7 }), 'err.bad_slot', 'a slot the rack does not have')
    denied(console('takeGun', 4, { rackId = rack.id, slot = 2 }), 'err.slot_empty', 'an empty slot')

    -- The admin and the owner reach for the same gun at once: exactly one gets it.
    H.db.latency = 200
    H.advance(1000)
    local a, b
    CreateThread(function() a = H.call('sd-gunracks:server:admin:takeGun', 4, { rackId = rack.id, slot = 1 }) end)
    CreateThread(function() b = H.call('sd-gunracks:server:take', 1, { rackId = rack.id, slot = 1 }) end)
    refused(b, 'err.slot_empty', 'the owner finds it claimed')
    H.run(1000)
    H.db.latency = 0
    check(a and a.ok, 'the admin gets it', a)
    eq(a.label, inv.label('WEAPON_CARBINERIFLE'), 'named by the inventory label')
    eq(inv.count(4, 'WEAPON_CARBINERIFLE') + inv.count(1, 'WEAPON_CARBINERIFLE'), 1, 'one gun in total')
    check(deepEq(inv.getSlots(4, 'WEAPON_CARBINERIFLE')[1].metadata, meta), 'with all its metadata')
    check(next(dbSlots(rack.id)) == nil and next(rack.claims) == nil, 'slot empty in memory and db, no claim left')
    local logged = H.auditEvents('admin')
    check(logged[#logged].data.action == 'take' and logged[#logged].data.serial == 'TK-1', 'logged with the serial', logged)
    noErrors()
end)

scenario('console: delete waits for guns in flight; AllowDelete off refuses it', function()
    local rack = placeRack(1, 'gunrack_oak')
    local slot = giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('DL-1'))
    H.db.latency = 200
    H.advance(1000)
    local stored
    CreateThread(function() stored = H.call('sd-gunracks:server:store', 1, { rackId = rack.id, slot = 1, invSlot = slot }) end)
    local del = H.call('sd-gunracks:server:admin:deleteRack', 4, { rackId = rack.id })
    denied(del, 'err.rack_busy', 'a store is in flight')
    H.run(1000)
    H.db.latency = 0
    check(stored and stored.success, 'the store finished', stored)
    check(registry.get(rack.id) and rack.slots[1], 'rack and gun still there')

    config.Admin.AllowDelete = false
    denied(console('deleteRack', 4, { rackId = rack.id }), 'err.delete_disabled', 'switched off')
    config.Admin.AllowDelete = true
    local ok = console('deleteRack', 4, { rackId = rack.id })
    check(ok.ok and ok.given == 1, 'deleted once nothing is in flight', ok)
    eq(inv.getSlots(4, 'WEAPON_CARBINERIFLE')[1].metadata.serial, 'DL-1', 'the gun went to the admin')
    noErrors()
end)

scenario('console: transfer by server id, by citizen id on or off; unknown refused; db failure rolls back', function()
    local rack = placeRack(1, 'gunrack_oak')
    sync.payload(1)
    sync.payload(2)
    local mark = H.mark()
    local t = console('transfer', 4, { rackId = rack.id, target = '2' })
    check(t.ok, 'by server id', t)
    eq(rack.owner, 'CID2', 'owner')
    eq(rack.ownerName, 'Thief Tate', 'owner name')
    eq(H.db.rows[rack.id].owner, 'CID2', 'owner written through')
    eq(H.db.rows[rack.id].owner_name, 'Thief Tate', 'name written through')
    local seen = H.clientEvents('sd-gunracks:client:upsert', mark, 2)
    check(#seen == 1 and seen[1].payload.mine == true and seen[1].payload.manage == true, 'the new owner is told it is theirs', seen)
    refused(call('setLocked', 1, { rackId = rack.id, locked = false }), 'err.not_owner', 'the old owner lost it')

    check(console('transfer', 4, { rackId = rack.id, target = 'CID6' }).ok, 'by citizen id, online')
    eq(rack.ownerName, 'Ballas Bo', 'named from the online player')
    H.offline.OFF1 = 'Gone Gary'
    check(console('transfer', 4, { rackId = rack.id, target = 'OFF1' }).ok, 'by citizen id, offline')
    eq(rack.owner, 'OFF1', 'offline owner')
    eq(rack.ownerName, 'Gone Gary', 'named from the framework table')

    denied(console('transfer', 4, { rackId = rack.id, target = 'NOPE9' }), 'err.no_character', 'nobody by that id')
    denied(console('transfer', 4, { rackId = rack.id, target = '99' }), 'err.no_player', 'no player with that server id')
    denied(console('transfer', 4, { rackId = rack.id, target = 'a b' }), 'err.no_character', 'not a citizen id')
    denied(console('transfer', 4, { rackId = rack.id, target = '' }), 'err.bad_request', 'empty')
    denied(console('transfer', 4, { rackId = rack.id, target = 'OFF1' }), 'err.already_owner', 'already theirs')
    H.db.failNext.update = 1
    denied(console('transfer', 4, { rackId = rack.id, target = '1' }), 'err.save_failed', 'db write failed')
    eq(rack.owner, 'OFF1', 'owner rolled back')
    eq(rack.ownerName, 'Gone Gary', 'name rolled back')
    local logged = H.auditEvents('admin')
    eq(logged[#logged].data.to, 'OFF1', 'transfers logged')
    noErrors()
end)

scenario('console: access edits are validated, saved, synced and take effect', function()
    local res = call('adminPlace', 4, { model = 'sd_gunrack_oak', coords = SPOT, heading = 0.0, locked = true })
    local rack = registry.get(res.data.id)
    local slot = giveGun(3, 'WEAPON_PUMPSHOTGUN', { serial = 'AC-1', ammo = 4 })
    refused(store(3, rack, 1, slot), 'err.no_access', 'police not on the list yet')
    sync.payload(3)
    local mark = H.mark()

    local ok = console('setAccess', 4, { rackId = rack.id, access = { jobs = { { name = ' police ', grade = 2 } }, gangs = {} } })
    check(ok.ok, 'saved', ok)
    eq(ok.access.jobs[1].name, 'police', 'trimmed and sent back as a list')
    eq(rack.access.jobs.police, 2, 'kept as a map')
    eq(json.decode(H.db.rows[rack.id].access).jobs.police, 2, 'written through')
    eq(H.clientEvents('sd-gunracks:client:upsert', mark, 3)[1].payload.allowed, true, 'the officer is told they may use it now')
    check(store(3, rack, 1, slot).success, 'police grade 2 stores')
    refused(call('take', 7, { rackId = rack.id, slot = 1 }), 'err.no_access', 'grade 1 still refused')

    for what, bad in pairs({
        ['a space in a name'] = { jobs = { { name = 'po lice', grade = 1 } } },
        ['a grade that is not a number'] = { jobs = { { name = 'police', grade = 'high' } } },
        ['a side that is not a list'] = { jobs = 'police' },
    }) do
        denied(console('setAccess', 4, { rackId = rack.id, access = bad }), 'err.bad_access 16', what)
    end

    local many = {}
    for i = 1, 17 do
        many[i] = { name = 'job' .. i, grade = 0 }
    end

    denied(console('setAccess', 4, { rackId = rack.id, access = { jobs = many } }), 'err.bad_access 16', 'too many lines')
    denied(console('setAccess', 4, { rackId = rack.id }), 'err.bad_access 16', 'no list at all')
    eq(rack.access.jobs.police, 2, 'refusals change nothing')

    H.db.failNext.update = 1
    denied(console('setAccess', 4, { rackId = rack.id, access = { jobs = {}, gangs = { { name = 'ballas', grade = 0 } } } }),
        'err.save_failed', 'db write failed')
    eq(rack.access.jobs.police, 2, 'rolled back')
    check(console('setAccess', 4, { rackId = rack.id, access = { jobs = {}, gangs = {} } }).ok, 'cleared')
    check(rack.access == nil and H.db.rows[rack.id].access == nil, 'no list in memory or db')
    refused(call('take', 3, { rackId = rack.id, slot = 1 }), 'err.no_access', 'the officer is locked out again')
    eq(H.auditEvents('admin')[#H.auditEvents('admin')].data.action, 'access', 'logged')
    noErrors()
end)

scenario('console: lock and unlock any rack from anywhere; a bad value is refused', function()
    local rack = placeRack(1, 'gunrack_oak')
    H.setPos(4, { x = 900.0, y = 900.0, z = 30.0 })
    local r = console('setLocked', 4, { rackId = rack.id, locked = false })
    check(r.ok and r.locked == false, 'unlocked from across the map', r)
    eq(H.db.rows[rack.id].locked, 0, 'written through')
    denied(console('setLocked', 4, { rackId = rack.id, locked = 'yes' }), 'err.bad_request', 'not a boolean')
    eq(rack.locked, false, 'unchanged by the bad call')
    H.db.failNext.update = 1
    denied(console('setLocked', 4, { rackId = rack.id, locked = true }), 'err.save_failed', 'db write failed')
    eq(rack.locked, false, 'rolled back')
    check(console('setLocked', 4, { rackId = rack.id, locked = true }).ok, 'locked again')
    noErrors()
end)

scenario('console: weapon search by weapon, serial, rack owner and who racked it', function()
    local a = placeRack(1, 'gunrack_oak')
    local b = placeRack(6, 'gunrack_pegboard', { x = -1.5, y = 0.0, z = 30.0 }, 0.0)
    H.labels.WEAPON_CARBINERIFLE, H.labels.WEAPON_PISTOL = 'Carbine Rifle', 'Pistol'
    check(store(1, a, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('SR-100'))).success, 'store a1')
    check(store(1, a, 2, giveGun(1, 'WEAPON_PUMPSHOTGUN', { serial = 'SR-200', ammo = 2 })).success, 'store a2')
    check(store(6, b, 2, giveGun(6, 'WEAPON_PISTOL', { serial = 'BB-300', ammo = 9 })).success, 'store b2')

    local function hits(q, field)
        local r = console('searchWeapons', 4, { q = q, field = field })
        check(r.list, 'search answered', r)
        local out = {}
        for _, h in ipairs(r.list) do
            out[#out + 1] = h.serial
        end

        table.sort(out)

        return table.concat(out, ','), r
    end

    eq((hits('', 'any')), 'BB-300,SR-100,SR-200', 'everything')
    eq((hits('carbine', 'weapon')), 'SR-100', 'by label')
    eq((hits('weapon_pistol', 'weapon')), 'BB-300', 'by weapon name')
    eq((hits('sr-2', 'serial')), 'SR-200', 'by serial')
    eq((hits('olsen', 'owner')), 'SR-100,SR-200', 'by rack owner name')
    eq((hits('cid6', 'owner')), 'BB-300', 'by rack owner id')
    eq((hits('ballas bo', 'by')), 'BB-300', 'by who racked it')
    eq((hits('olsen', 'serial')), '', 'a field limits where it looks')
    local _, r = hits('BB-300', 'nonsense')
    eq(r.list[1].rackId, b.id, 'an unknown field searches everything, and names the rack')
    eq(r.list[1].slot, 2, 'and the slot')
    config.Admin.SearchLimit = 1
    local _, capped = hits('', 'any')
    check(#capped.list == 1 and capped.total == 3 and capped.capped == true, 'capped, with the real total', capped)
    config.Admin.SearchLimit = 200
    denied(console('searchWeapons', 4, { q = ('x'):rep(65), field = 'any' }), 'err.bad_request', 'an absurd search')
    noErrors()
end)

scenario('console: teleport says where to stand and logs it; a rack in another bucket is flagged', function()
    local rack = placeRack(1, 'gunrack_oak', SPOT, 0.0)
    local t = console('teleport', 4, { rackId = rack.id })
    check(t.ok, 'answered', t)
    check(math.abs(t.x - 1.5) < 1e-6 and math.abs(t.y - (-0.17 - 1.0)) < 1e-6, 'a step out from its front', t)
    eq(t.h, 0.0, 'facing it')
    eq(t.sameBucket, true, 'same bucket')
    H.setPos(5, SPOT)
    local far = placeRack(5, 'gunrack_oak')
    local t2 = console('teleport', 4, { rackId = far.id })
    check(t2.ok and t2.sameBucket == false and t2.bucket == 7, 'flagged as another bucket', t2)
    local logged = H.auditEvents('admin')
    eq(logged[#logged].data.action, 'teleport', 'logged')
    denied(console('teleport', 4, { rackId = 404 }), 'err.no_rack', 'unknown rack')
    noErrors()
end)

scenario('console: the players on the server with their racks', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(store(1, rack, 1, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('PL-1'))).success, 'store')
    local list = console('getPlayers', 4).list
    eq(#list, 7, 'everyone on')
    local olsen = list[1]
    eq(olsen.src, 1, 'by server id')
    eq(olsen.cid, 'CID1', 'citizen id')
    eq(#olsen.racks, 1, 'their rack')
    eq(olsen.guns, 1, 'their guns')
    eq(list[3].job, 'police', 'job')
    eq(list[3].jobGrade, 2, 'grade')
    eq(list[6].gang, 'ballas', 'gang')
    eq(#list[2].racks, 0, 'nobody else has one')
    noErrors()
end)

scenario('console: staff writes are paced and one at a time; reads come in bursts', function()
    local rack = placeRack(1, 'gunrack_oak')
    check(console('setLocked', 4, { rackId = rack.id, locked = false }).ok, 'first write')
    H.advance(100)
    denied(H.call('sd-gunracks:server:admin:setLocked', 4, { rackId = rack.id, locked = true }), 'err.too_fast', 'a second write 100 ms later')
    eq(rack.locked, false, 'refused write changed nothing')
    eq(auditCount('suspect', 'rate_limited'), 1, 'logged once')

    H.advance(5000)
    local n = 0
    for _ = 1, 20 do
        if H.call('sd-gunracks:server:admin:getRacks', 4).list then
            n = n + 1
        end
    end

    eq(n, config.Admin.RateLimit.ReadBurst, 'a burst of reads, then refused')
    H.advance(1000)
    check(H.call('sd-gunracks:server:admin:getRacks', 4).list, 'the bucket refills')

    -- A write waiting on the database holds every other write of that admin.
    H.advance(5000)
    H.db.latency = 300
    local first
    CreateThread(function() first = H.call('sd-gunracks:server:admin:setLocked', 4, { rackId = rack.id, locked = true }) end)
    H.advance(500)
    denied(H.call('sd-gunracks:server:admin:transfer', 4, { rackId = rack.id, target = '2' }), 'err.too_fast', 'one write at a time')
    H.run(1000)
    H.db.latency = 0
    check(first and first.ok and rack.locked, 'the first write finished', first)
    eq(rack.owner, 'CID1', 'the refused one did nothing')
    noErrors()
end)

scenario('console: the log table is written, paged, filtered and pruned', function()
    check(BOOT_SQL[3] and BOOT_SQL[3]:find('^CREATE TABLE IF NOT EXISTS sd_gunracks_log'), 'log table made after the racks load', BOOT_SQL)
    local rack = placeRack(1, 'gunrack_oak')
    for i = 1, 3 do
        check(store(1, rack, i, giveGun(1, 'WEAPON_CARBINERIFLE', carbineMeta('LG-' .. i))).success, 'store ' .. i)
    end

    check(call('take', 1, { rackId = rack.id, slot = 2 }).success, 'take')
    check(console('setLocked', 4, { rackId = rack.id, locked = false }).ok, 'staff unlock')
    eq(#H.db.logRows, 6, 'every event became a row')
    local row = H.db.logRows[2]
    eq(row.kind, 'store', 'kind')
    eq(row.actor, 'Owner Olsen (Owner Olsen)', 'character (account)')
    eq(row.cid, 'CID1', 'character id')
    eq(row.rack, rack.id, 'filed under the rack')
    eq(json.decode(row.data).serial, 'LG-1', 'structured fields kept')
    eq(H.db.logRows[6].kind, 'admin.lock', 'staff kind refined by the action')

    local p = console('getLogs', 4, { page = 1, size = 10 })
    eq(p.total, 6, 'total')
    eq(p.size, 10, 'size')
    eq(p.pages, 1, 'pages')
    check(p.list[1].id > p.list[2].id, 'newest first')
    eq(p.list[1].kind, 'admin.lock', 'the newest row')
    local kinds = {}
    for _, k in ipairs(p.kinds) do
        kinds[#kinds + 1] = k.kind .. '=' .. k.count
    end

    eq(table.concat(kinds, ','), 'admin.lock=1,place=1,store=3,take=1', 'kinds with their counts')

    for i = 1, 25 do
        H.db.logRows[#H.db.logRows + 1] = { id = H.db.logNext, at = os.time(), kind = 'store', detail = 'filler ' .. i }
        H.db.logNext = H.db.logNext + 1
    end

    local p1 = console('getLogs', 4, { page = 1, size = 10 })
    local p3 = console('getLogs', 4, { page = 3, size = 10 })
    local p9 = console('getLogs', 4, { page = 9, size = 10 })
    eq(p1.pages, 4, '31 rows, 10 a page')
    eq(#p3.list, 10, 'a full middle page')
    eq(p9.page, 4, 'past the end clamps to the last page')
    eq(#p9.list, 1, 'the last row alone')
    eq(p9.list[1].kind, 'place', 'the oldest row last')
    eq(console('getLogs', 4, { size = 1000 }).size, 100, 'size capped')
    eq(console('getLogs', 4, { size = 1 }).size, 10, 'size floored')

    eq(console('getLogs', 4, { kind = 'take' }).total, 1, 'by kind')
    eq(console('getLogs', 4, { q = 'olsen' }).total, 5, 'search by who')
    eq(console('getLogs', 4, { q = 'LG-3' }).total, 1, 'search the detail')
    eq(console('getLogs', 4, { q = '100%' }).total, 0, 'a % in a search is literal')
    eq(console('getLogs', 4, { q = 'filler 1', kind = 'store' }).total, 11, 'search and kind together')
    eq(console('getLogs', 4, { rack = rack.id }).total, 6, 'one rack')
    eq(console('getLogs', 4, { rack = rack.id, kind = 'store' }).kinds[1].kind, 'admin.lock', 'one rack keeps its own kinds')
    denied(console('getLogs', 4, { kind = "x' OR 1" }), 'err.bad_request', 'a kind that is not a kind')

    local audit = require 'server.racks.audit'
    local DB = config.Logs.Database
    DB.MaxRows, DB.MaxDays = 5, 0
    audit.prune()
    eq(#H.db.logRows, 5, 'pruned to MaxRows')
    eq(H.db.logRows[5].detail, 'filler 25', 'the newest kept')
    H.db.logRows[1].at = os.time() - 3 * 86400
    DB.MaxRows, DB.MaxDays = 0, 2
    audit.prune()
    eq(#H.db.logRows, 4, 'pruned by age')
    DB.MaxRows, DB.MaxDays = 50000, 90

    DB.Enabled = false
    local before = #H.db.logRows
    check(console('setLocked', 4, { rackId = rack.id, locked = true }).ok, 'staff lock')
    eq(#H.db.logRows, before, 'no rows while the table is switched off')
    check(#H.auditEvents('admin') > 0, 'lib.logger still has it')
    DB.Enabled = true
    noErrors()
end)

H.out(('\n%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
