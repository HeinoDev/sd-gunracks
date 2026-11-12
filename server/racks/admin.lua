---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Rack fits (shared.fit): which models exist, their boxes.
local fit = require 'shared.fit'
---@type table Rack-space geometry (shared.geo): distances, the spot in front of a rack.
local geo = require 'shared.geo'
---@type table Weapon metadata reads (shared.weapons): serials for the log.
local weapons = require 'shared.weapons'
---@type table Audit-log helper (server.racks.audit): the log table + lib.logger.
local audit = require 'server.racks.audit'
---@type table Server persistence (server.racks.store): the log table's pages.
local store = require 'server.racks.store'
---@type table Live racks (server.racks.registry).
local registry = require 'server.racks.registry'
---@type table Per-bucket client sync (server.racks.sync).
local sync = require 'server.racks.sync'
---@type table Player facts from the bridge (server.racks.actor): the staff ace.
local actor = require 'server.racks.actor'
---@type table Per-player request pacing (server.racks.limits).
local limits = require 'server.racks.limits'
---@type table Player-facing handlers (server.racks.actions): pose reading, labels, the guarded give.
local actions = require 'server.racks.actions'
---@type table The console's read models (server.racks.views).
local views = require 'server.racks.views'
---@type table Inventory bridge (bridge.server.inventory): backend-agnostic item ops.
local inventory = require 'bridge.server.inventory'
---@type table Player bridge (bridge.server.player): who a transfer goes to.
local player = require 'bridge.server.player'

---@type table Admin config (config.Admin): command, aces, polls, pacing, give cap.
local CFG = config.Admin or {}
---@type table Staff request pacing (config.Admin.RateLimit).
local PACE = CFG.RateLimit or {}

---@type table Admin module; the table returned at end of file.
local admin = {}

---@type integer Most jobs (and most gangs) one rack's access list may name.
local MAX_ACCESS = 16
---@type integer Highest grade an access line may ask for: framework grades are small numbers.
local MAX_GRADE = 999

---A refusal in the console's response shape (web/src/nui/wire.ts refusalOf).
---@param key string locale key
---@param ... any locale arguments
---@return table response { ok = false, err }
local function no(key, ...)
    return { ok = false, err = locale(key, ...) }
end

---A refusal in the player callbacks' shape (adminPlace answers the placer, which reads that one).
---@param key string locale key
---@param ... any locale arguments
---@return table response { success = false, message }
local function fail(key, ...)
    return { success = false, message = locale(key, ...) }
end

---The staff gate every admin callback passes first: a non-admin calling one is logged, because
---the console that sends them only opens for staff.
---@param src integer
---@param what string which callback, for the log
---@return boolean allowed
local function staff(src, what)
    if actor.isAdmin(src) then return true end

    audit.log('suspect', src,
        ('called admin %s without the staff ace'):format(what),
        { reason = 'admin_not_staff', callback = what })

    return false
end

---A trimmed string of at most `max` characters, or nil for anything else (or nothing at all).
---@param v any
---@param max integer
---@return string|nil
local function str(v, max)
    if type(v) == 'number' then
        v = tostring(math.tointeger(v) or v)
    end

    if type(v) ~= 'string' then return nil end

    v = v:match('^%s*(.-)%s*$')

    if v == '' or #v > max then return nil end

    return v
end

---An access list out of the admin's input, in either shape: the console's (`jobs = { { name,
---grade } }`) or the map the exports and the database use (`jobs = { name = minGrade }`). Names are
---trimmed and must look like a framework's job or gang name; grades are whole numbers from 0.
---@param raw any
---@return table|nil access { jobs = { name = minGrade }, gangs = {...} }, nil when it names nobody
---@return boolean bad true when something in it was unusable (and left out)
function admin.readAccess(raw)
    if type(raw) ~= 'table' then
        return nil, raw ~= nil
    end

    local out, any, bad = { jobs = {}, gangs = {} }, false, false

    for _, key in ipairs({ 'jobs', 'gangs' }) do
        local side = raw[key]

        if side ~= nil and type(side) ~= 'table' then
            bad = true
        end

        local n = 0

        for k, v in pairs(type(side) == 'table' and side or {}) do
            local name, grade

            if type(k) == 'number' and type(v) == 'table' then
                name, grade = v.name, v.grade
            else
                name, grade = k, v
            end

            name = str(name, 50)
            grade = tonumber(grade) or (grade == nil and 0 or nil)

            if not name or not name:match('^[%w_%-%.]+$') or not grade or grade ~= grade then
                bad = true
            elseif n >= MAX_ACCESS then
                bad = true
            else
                if out[key][name] == nil then
                    n = n + 1
                end

                out[key][name] = math.min(MAX_GRADE, math.max(0, math.floor(grade)))
                any = true
            end
        end
    end

    return any and out or nil, bad
end

---A live rack (not being removed) by the id the console sent.
---@param id any
---@return Rack|nil
local function live(id)
    local rack = registry.get(id)

    if not rack or rack.removing then return nil end

    return rack
end

---A rack's label for the log.
---@param rack Rack
---@return string
local function labelOf(rack)
    return ('%s #%d'):format(actions.rackLabel(rack.model), rack.id)
end

---Delete a rack, returning its guns to the admin's inventory first (actions.giveAll: the emptied
---slots are written before any gun is handed out). If they cannot carry them all, the rack stays
---with whatever is left on it (staff empty their pockets and try again): deleting with guns still
---on it would destroy them. The rack row is deleted only once it is empty.
---@param src integer
---@param rack Rack
---@return table response { ok, given } or a refusal
local function deleteWithReturn(src, rack)
    if next(rack.claims) ~= nil then
        return no('err.rack_busy')
    end

    rack.removing = true

    local given, left = actions.giveAll(src, rack)

    if not given then
        rack.removing = nil
        return no('err.save_failed')
    end

    if left > 0 then
        rack.removing = nil

        if given > 0 then
            sync.push(rack)
        end

        audit.log('admin', src,
            ('could not delete rack %d: returned %d guns, %d did not fit'):format(rack.id, given, left),
            { action = 'delete', rack = rack.id, given = given, left = left })

        return no('admin.delete_partial', given, left)
    end

    -- Its guns are already with the admin and its emptied slots written: the rack stays, empty.
    if not registry.destroy(rack) then
        rack.removing = nil

        if given > 0 then
            sync.push(rack)
        end

        return no('err.save_failed')
    end

    sync.drop(rack)
    audit.log('admin', src,
        ('deleted rack %d (%s, owner %s), returned %d guns'):format(
            rack.id, rack.model, tostring(rack.ownerName or rack.owner or 'none'), given),
        { action = 'delete', rack = rack.id, model = rack.model, owner = rack.owner, given = given })

    return { ok = true, id = rack.id, given = given }
end

---Place a rack as staff: any model, no item, no owner, optionally restricted to jobs/gangs. The
---placer's confirm (client/racks/placement.lua) sends it, in the player callbacks' shape.
---@param src integer
---@param payload table { model, coords, heading, locked?, access? }
---@return table response
function admin.place(src, payload)
    if not staff(src, 'place') then
        return fail('err.admin_only')
    end

    if not limits.allow(src, 'action') then
        return fail('err.too_fast')
    end

    payload = type(payload) == 'table' and payload or {}

    if type(payload.model) ~= 'string' or not fit.rack(payload.model) then
        return fail('err.bad_model')
    end

    local coords, heading = actions.readPose(payload)

    if not coords then
        return fail('err.bad_spot')
    end

    local pc = actions.pedCoords(src)
    local P = config.Placement

    if not pc or geo.dist(pc, coords) > (P.Range or 4.0) + (P.RangeSlack or 1.5) then
        return fail('err.too_far_place')
    end

    local bucket = GetPlayerRoutingBucket(src)
    local free, why = registry.spotFree(payload.model, coords, heading, bucket)

    if not free then
        return fail('err.spot_' .. tostring(why))
    end

    local acc = admin.readAccess(payload.access)
    local rack = registry.create({
        model = payload.model,
        coords = coords,
        heading = heading,
        bucket = bucket,
        locked = payload.locked ~= false,
        access = acc,
    })

    if not rack then
        return fail('err.save_failed')
    end

    sync.push(rack)
    audit.log('admin', src,
        ('placed staff rack %d (%s)'):format(rack.id, rack.model),
        {
            action = 'place',
            rack = rack.id,
            model = rack.model,
            access = acc,
            locked = rack.locked,
            x = coords.x,
            y = coords.y,
            z = coords.z,
        })

    return { success = true, data = { id = rack.id } }
end


-- ------------------------------------------------------------------------------------------------
-- The console (web/src/admin): every call it makes, by name. Reads build a view; writes change one
-- rack (or one inventory) under the same rules as the player handlers: the slot claims, the removing
-- flag, the database written before anything is handed out and put back when it fails.
-- ------------------------------------------------------------------------------------------------

---@type table<string, fun(src: integer, req: table): table>
local handlers = {}

---@type { at: integer, rows: table[] }|nil The overview's one database read, kept a few seconds:
---the tab refreshes on a timer for as long as it is open and the log does not move that fast.
local recent

function handlers.getOverview()
    if not recent or os.time() - recent.at >= 5 then
        recent = { at = os.time(), rows = store.logPage({}, 8, 0) or {} }
    end

    local out = views.overview()
    out.recent = recent.rows

    return out
end

function handlers.getCatalog()
    return views.catalog()
end

function handlers.getRacks()
    return { list = views.racks() }
end

---@param req table { id }
function handlers.getRack(_, req)
    local rack = live(req.id)

    if not rack then
        return no('err.no_rack')
    end

    return views.rack(rack)
end

---@param req table { q, field }
function handlers.searchWeapons(_, req)
    local field = views.FIELDS[req.field] and req.field or 'any'
    local q = req.q == nil and '' or str(req.q, 64)

    if req.q ~= nil and req.q ~= '' and not q then
        return no('err.bad_request')
    end

    local limit = math.max(1, math.floor(tonumber(CFG.SearchLimit) or 200))
    local list, total = views.searchWeapons(q and q:lower() or nil, field, limit)

    return { list = list, total = total, capped = total > #list }
end

function handlers.getPlayers()
    return { list = views.players() }
end

---@param req table { page?, size?, kind?, q?, rack? }
function handlers.getLogs(_, req)
    local f = {
        kind = str(req.kind, 32),
        q = str(req.q, 64),
        rack = math.tointeger(tonumber(req.rack)),
    }

    if f.kind and not f.kind:match('^[%w_%.]+$') then
        return no('err.bad_request')
    end

    local size = math.max(10, math.min(100, math.floor(tonumber(req.size) or 50)))
    local total = store.logCount(f)
    local kinds = store.logKinds(f.rack)

    if not total or not kinds then
        return no('err.logs_unreadable')
    end

    local pages = math.max(1, math.ceil(total / size))
    local page = math.max(1, math.min(pages, math.floor(tonumber(req.page) or 1)))
    local list = store.logPage(f, size, (page - 1) * size)

    if not list then
        return no('err.logs_unreadable')
    end

    return { list = list, total = total, page = page, size = size, pages = pages, kinds = kinds }
end

---Where an admin going to a rack is put: a step out from its front, at its base, facing it.
---@param src integer
---@param req table { rackId }
function handlers.teleport(src, req)
    local rack = live(req.rackId)

    if not rack then
        return no('err.no_rack')
    end

    local def = fit.rack(rack.model) or {}
    local mn, mx = def.min or { -0.5, -0.2, 0 }, def.max or { 0.5, 0.2, 1 }
    local x, y = geo.toWorld(rack.coords, rack.heading, { (mn[1] + mx[1]) / 2, math.min(mn[2], mx[2]) - 1.0, 0.0 })
    local bucket = GetPlayerRoutingBucket(src)

    audit.log('admin', src, ('went to rack %d'):format(rack.id), { action = 'teleport', rack = rack.id })

    -- Facing the rack is looking along its local +Y, which is the rack's own heading.
    return {
        ok = true,
        x = x,
        y = y,
        z = rack.coords.z,
        h = rack.heading,
        bucket = rack.bucket,
        sameBucket = rack.bucket == bucket,
    }
end

---Lock or unlock any rack, from anywhere.
---@param src integer
---@param req table { rackId, locked }
function handlers.setLocked(src, req)
    local rack = live(req.rackId)

    if not rack then
        return no('err.no_rack')
    end

    if type(req.locked) ~= 'boolean' then
        return no('err.bad_request')
    end

    local want = req.locked

    if rack.locked == want then
        return { ok = true, locked = want }
    end

    rack.locked = want

    if not registry.saveLocked(rack) then
        rack.locked = not want
        return no('err.save_failed')
    end

    sync.push(rack)
    audit.log('admin', src, ('%s rack %d'):format(want and 'locked' or 'unlocked', rack.id),
        { action = 'lock', rack = rack.id, locked = want })

    return { ok = true, locked = want }
end

---Replace a rack's access list (an empty one clears it).
---@param src integer
---@param req table { rackId, access = { jobs = { { name, grade } }, gangs = {...} } }
function handlers.setAccess(src, req)
    local rack = live(req.rackId)

    if not rack then
        return no('err.no_rack')
    end

    -- An absent list is a broken request, not "nobody": clearing one is sending an empty one.
    if type(req.access) ~= 'table' then
        return no('err.bad_access', MAX_ACCESS)
    end

    local access, bad = admin.readAccess(req.access)

    if bad then
        return no('err.bad_access', MAX_ACCESS)
    end

    local before = rack.access
    rack.access = access

    if not registry.saveAccess(rack) then
        rack.access = before
        return no('err.save_failed')
    end

    sync.push(rack)

    local list = views.accessList(access)
    local words = {}

    for _, side in ipairs({ 'jobs', 'gangs' }) do
        for _, e in ipairs(list[side]) do
            words[#words + 1] = ('%s %d'):format(e.name, e.grade)
        end
    end

    audit.log('admin', src,
        ('set the access list of rack %d: %s'):format(rack.id, #words > 0 and table.concat(words, ', ') or 'nobody'),
        { action = 'access', rack = rack.id, access = access })

    return { ok = true, access = list }
end

---Who a transfer names: a player on the server by their server id, or a character by their id
---(on now, or found offline through the framework's own table).
---@param target any
---@return string|nil cid
---@return string|nil name
---@return string|nil why locale key when nobody was found
local function resolveTarget(target)
    local t = str(target, 64)

    if not t then return nil, nil, 'err.bad_request' end

    local id = t:match('^%d+$') and math.tointeger(tonumber(t)) or nil

    if id and GetPlayerName(id) then
        local cid = player.getIdentifier(id)

        if not cid then return nil, nil, 'err.no_identity_target' end

        return cid, player.getName(id)
    end

    if not t:match('^[%w_%-:]+$') then return nil, nil, 'err.no_character' end

    local src = views.online()[t]

    if src then
        return t, player.getName(src)
    end

    local name = player.offlineName(t)

    if name then return t, name end

    return nil, nil, id and 'err.no_player' or 'err.no_character'
end

---Give a rack to a player: they own it (and may lock, unlock and pick it up) from now on.
---@param src integer
---@param req table { rackId, target }
function handlers.transfer(src, req)
    local rack = live(req.rackId)

    if not rack then
        return no('err.no_rack')
    end

    local cid, name, why = resolveTarget(req.target)

    if not cid then
        return no(why)
    end

    if rack.owner == cid then
        return no('err.already_owner')
    end

    local was, wasName = rack.owner, rack.ownerName
    rack.owner, rack.ownerName = cid, name

    if not registry.saveOwner(rack) then
        rack.owner, rack.ownerName = was, wasName
        return no('err.save_failed')
    end

    sync.push(rack)

    local previous = tostring(wasName or was or 'a staff rack')

    audit.log('admin', src,
        ('gave rack %d to %s (%s), was %s'):format(rack.id, tostring(name), cid, previous),
        { action = 'transfer', rack = rack.id, from = was, to = cid })

    return { ok = true, owner = cid, ownerName = name }
end

---Take one stored gun off a rack into the admin's own inventory: the same guarded give a player's
---take goes through (the slot is claimed first, the database written before the give, both put
---back if the give fails), without the range check.
---@param src integer
---@param req table { rackId, slot }
function handlers.takeGun(src, req)
    local rack = live(req.rackId)

    if not rack then
        return no('err.no_rack')
    end

    local index = math.tointeger(tonumber(req.slot))
    local def = fit.rack(rack.model)

    if not index or not (def and def.slots and def.slots[index]) then
        return no('err.bad_slot')
    end

    local res, rec = actions.giveOut(src, rack, index)

    if not rec then
        return { ok = false, err = res.message }
    end

    local serial = weapons.serial(rec.metadata)
    local owner = tostring(rack.ownerName or rack.owner or 'none')

    audit.log('admin', src,
        ('took %s (serial %s) off rack %d slot %d, owner %s'):format(rec.name, serial or 'none', rack.id, index, owner),
        {
            action = 'take',
            rack = rack.id,
            slot = index,
            weapon = rec.name,
            serial = serial,
            owner = rack.owner,
            racked_by = rec.by,
        })

    return { ok = true, label = inventory.label(rec.item) }
end

---Delete a rack from anywhere: its guns go to the admin first (deleteWithReturn).
---@param src integer
---@param req table { rackId }
function handlers.deleteRack(src, req)
    if CFG.AllowDelete == false then
        return no('err.delete_disabled')
    end

    local rack = live(req.rackId)

    if not rack then
        return no('err.no_rack')
    end

    return deleteWithReturn(src, rack)
end

---Give a player rack items.
---@param src integer
---@param req table { target, item, count }
function handlers.giveItem(src, req)
    local item = req.item

    if type(item) ~= 'string' or not config.Racks.Items[item] then
        return no('err.bad_model')
    end

    local target = math.tointeger(tonumber(req.target))

    if not target or not GetPlayerName(target) then
        return no('err.no_player')
    end

    local count = math.max(1, math.min(CFG.MaxGive or 10, math.floor(tonumber(req.count) or 1)))

    if not inventory.canCarry(target, item, count) or not inventory.add(target, item, count) then
        return no('err.cannot_carry')
    end

    local who = player.getName(target)

    audit.log('admin', src,
        ('gave %dx %s to %s'):format(count, item, tostring(who ~= 'Unknown' and who or GetPlayerName(target))),
        { action = 'give', item = item, count = count, target = target })

    return {
        ok = true,
        item = item,
        count = count,
        label = actions.rackLabel(config.Racks.Items[item]),
        targetName = who,
    }
end

---@type table<string, boolean> Handlers that change something: paced as writes, one at a time.
local WRITES = {
    teleport = true,
    setLocked = true,
    setAccess = true,
    transfer = true,
    takeGun = true,
    deleteRack = true,
    giveItem = true,
}

---@type table<integer, string> Staff with a write in flight (waiting on the database), and which.
local busy = {}

---Run one console call for `src`: the staff gate, the pacing, then the handler. A handler that
---throws answers a refusal rather than leaving the page waiting, and is logged.
---@param name string
---@param src integer
---@param req any
---@return table response
function admin.call(name, src, req)
    local fn = handlers[name]

    if not fn then
        return no('err.bad_request')
    end

    if not staff(src, name) then
        return no('err.admin_only')
    end

    local write = WRITES[name] == true

    if write then
        if busy[src] or not limits.allow(src, 'staffWrite', PACE.WriteMs or 400) then
            return no('err.too_fast')
        end

        busy[src] = name
    elseif not limits.burst(src, 'staffRead', PACE.ReadBurst or 12, PACE.ReadPerSecond or 6) then
        return no('err.too_fast')
    end

    local ok, res = pcall(fn, src, type(req) == 'table' and req or {})

    if write then
        busy[src] = nil
    end

    if not ok then
        log.error('admin', "console call '%s' failed for src=%d: %s", name, src, tostring(res))
        return no('err.console_failed')
    end

    return res
end

---Forget a departed admin's write in flight.
---@param src integer
function admin.forget(src)
    busy[src] = nil
end

do
    local named = {}

    for _, name in ipairs(require 'shared.admin_callbacks') do
        named[name] = true
    end

    for name in pairs(handlers) do
        if not named[name] then
            log.error('admin', "handler '%s' is not in shared/admin_callbacks.lua: the console cannot reach it. Add the name.", name)
        end
    end

    for name in pairs(named) do
        if not handlers[name] then
            log.error('admin', "shared/admin_callbacks.lua names '%s' but no handler answers it: the relay will refuse it. "
                .. 'Remove the name or write the handler.', name)
        end
    end
end

for name in pairs(handlers) do
    lib.callback.register('sd-gunracks:server:admin:' .. name, function(src, req)
        return admin.call(name, src, req)
    end)
end

---@return table<string, integer> ms the tabs' refresh periods
local function pollMs()
    local seconds = type(CFG.Poll) == 'table' and CFG.Poll or {}
    local out = {}

    for key, fallback in pairs({ Overview = 10, Racks = 6, Players = 8, Logs = 15 }) do
        out[key:lower()] = math.max(2, math.floor(tonumber(seconds[key]) or fallback)) * 1000
    end

    return out
end

---/gunracks: open the staff console (ox_lib restricts the command to Admin.Group; the staff check
---is asked again here so a principal granted only the configurable ace is still sent away).
lib.addCommand(CFG.Command or 'gunracks', {
    help = locale('admin.command_help'),
    restricted = CFG.Group or 'group.admin',
}, function(source)
    if not source or source <= 0 then return end

    if not actor.isAdmin(source) then return end

    audit.log('admin', source, 'opened the gun rack console', { action = 'open' })
    TriggerClientEvent('sd-gunracks:client:admin:open', source, {
        perms = { admin = true, delete = CFG.AllowDelete ~= false },
        pollMs = pollMs(),
    })
end)

return admin
