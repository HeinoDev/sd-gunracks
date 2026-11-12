---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Rack fits (shared.fit): labels, mounts and slots of each model.
local fit = require 'shared.fit'
---@type table Weapon metadata reads (shared.weapons): serials, ammo, attachments.
local weapons = require 'shared.weapons'
---@type table Live racks (server.racks.registry).
local registry = require 'server.racks.registry'
---@type table Inventory bridge (bridge.server.inventory): item labels.
local inventory = require 'bridge.server.inventory'
---@type table Player bridge (bridge.server.player): who is on, by character.
local player = require 'bridge.server.player'
---@type table Job bridge (bridge.server.job): the Players tab's job column.
local job = require 'bridge.server.job'
---@type table Gang bridge (bridge.server.gang): the Players tab's gang column.
local gang = require 'bridge.server.gang'

---@type table Views module; the table returned at end of file.
local views = {}

-- What the staff console reads, built from the live registry (and the bridge for who is on). Every
-- shape here is the page's (web/src/types.ts): lists are arrays, an access list is two arrays of
-- { name, grade }, absent fields are simply nil. Nothing here changes anything.

---Everyone on the server: server id by character id, so a rack can say whether its owner is on.
---@return table<string, integer> online character id -> server id
function views.online()
    local out = {}
    for _, s in ipairs(GetPlayers()) do
        local src = math.tointeger(tonumber(s))
        local ok, cid = pcall(player.getIdentifier, src)

        if src and ok and cid then
            out[cid] = src
        end
    end

    return out
end

---An access list ({ jobs = { name = minGrade }, gangs = {...} }) as the page reads one: two arrays
---of { name, grade }, sorted by name.
---@param access table|nil
---@return { jobs: table[], gangs: table[] }
function views.accessList(access)
    local out = { jobs = {}, gangs = {} }

    if type(access) ~= 'table' then return out end

    for _, side in ipairs({ 'jobs', 'gangs' }) do
        for name, grade in pairs(type(access[side]) == 'table' and access[side] or {}) do
            out[side][#out[side] + 1] = { name = name, grade = math.tointeger(tonumber(grade)) or 0 }
        end

        table.sort(out[side], function(a, b) return a.name < b.name end)
    end

    return out
end

---How many slots a model has.
---@param model string
---@return integer
local function slotCount(model)
    local def = fit.rack(model)

    return def and def.slots and #def.slots or 0
end

---One rack as the Racks tab lists it.
---@param rack Rack
---@param online table<string, integer> views.online()
---@return table row
function views.rackRow(rack, online)
    local def = fit.rack(rack.model) or {}

    return {
        id = rack.id,
        model = rack.model,
        label = def.label or rack.model,
        mount = def.mount or 'floor',
        owner = rack.owner,
        ownerName = rack.ownerName,
        ownerOnline = rack.owner ~= nil and online[rack.owner] ~= nil,
        bucket = rack.bucket,
        x = rack.coords.x,
        y = rack.coords.y,
        z = rack.coords.z,
        h = rack.heading,
        locked = rack.locked,
        access = views.accessList(rack.access),
        stored = registry.storedCount(rack),
        slots = slotCount(rack.model),
        createdAt = rack.createdAt,
        busy = next(rack.claims) ~= nil,
    }
end

---Every rack still standing (not mid-delete), by id.
---@return Rack[]
local function standing()
    local out = {}
    for _, r in pairs(registry.all()) do
        if not r.removing then
            out[#out + 1] = r
        end
    end

    table.sort(out, function(a, b) return a.id < b.id end)

    return out
end

---Every rack as the Racks tab lists it.
---@return table[] rows
function views.racks()
    local online = views.online()
    local out = {}
    for _, r in ipairs(standing()) do
        out[#out + 1] = views.rackRow(r, online)
    end

    return out
end

---One stored gun as the rack's Slots card shows it.
---@param rec table stored slot { name, item, metadata, by, byName, at }
---@return table gun
local function gunOf(rec)
    local md = rec.metadata

    return {
        name = rec.name,
        item = rec.item,
        label = inventory.label(rec.item),
        serial = weapons.serial(md),
        ammo = weapons.ammo(md),
        durability = inventory.durabilityOf(md),
        attachments = weapons.componentLabels(md, inventory.label),
        tint = weapons.tint(md),
        by = rec.by,
        byName = rec.byName,
        at = rec.at,
    }
end

---One rack, all of it: its row and every slot with the gun in it.
---@param rack Rack
---@return table detail { rack, slots = { { index, kind, kindLabel, gun?, busy } } }
function views.rack(rack)
    local def = fit.rack(rack.model) or {}
    local slots = {}
    for i, s in ipairs(def.slots or {}) do
        local kind = (def.kinds or {})[s.kind] or {}
        local rec = rack.slots[i]

        slots[i] = {
            index = i,
            kind = s.kind,
            kindLabel = kind.label or s.kind,
            gun = rec and gunOf(rec) or nil,
            busy = rack.claims[i] == true,
        }
    end

    return { rack = views.rackRow(rack, views.online()), slots = slots }
end

---Every rack model, for the Place tab and the give forms.
---@return table catalog { models = { { model, item, label, mount, slots, kinds } }, maxGive }
function views.catalog()
    local models = {}
    for item, model in pairs(config.Racks.Items) do
        local def = fit.rack(model)

        if def then
            local counts, order = {}, {}
            for _, s in ipairs(def.slots or {}) do
                local label = ((def.kinds or {})[s.kind] or {}).label or s.kind

                if not counts[label] then
                    order[#order + 1] = label
                end

                counts[label] = (counts[label] or 0) + 1
            end

            local kinds = {}
            for i, label in ipairs(order) do
                kinds[i] = { label = label, count = counts[label] }
            end

            models[#models + 1] = {
                model = model,
                item = item,
                label = def.label or model,
                mount = def.mount or 'floor',
                slots = #(def.slots or {}),
                kinds = kinds,
            }
        end
    end

    table.sort(models, function(a, b) return a.label < b.label end)

    return { models = models, maxGive = (config.Admin or {}).MaxGive or 10 }
end

---The Overview tab's figures. `recent` is the caller's (it is a database read).
---@return table overview
function views.overview()
    local racks, guns, slots, locked, staff, restricted = 0, 0, 0, 0, 0, 0
    local owners, buckets, byModel = {}, {}, {}
    for _, r in ipairs(standing()) do
        local stored, n = registry.storedCount(r), slotCount(r.model)

        racks, guns, slots = racks + 1, guns + stored, slots + n

        if r.locked then
            locked = locked + 1
        end

        if r.owner then
            owners[r.owner] = true
        else
            staff = staff + 1
        end

        if r.access and (next(r.access.jobs or {}) or next(r.access.gangs or {})) then
            restricted = restricted + 1
        end

        buckets[r.bucket] = true

        local m = byModel[r.model]

        if not m then
            m = { model = r.model, label = (fit.rack(r.model) or {}).label or r.model, count = 0, guns = 0, slots = 0 }
            byModel[r.model] = m
        end

        m.count, m.guns, m.slots = m.count + 1, m.guns + stored, m.slots + n
    end

    local models = {}
    for _, m in pairs(byModel) do
        models[#models + 1] = m
    end

    table.sort(models, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end

        return a.label < b.label
    end)

    local function count(set)
        local n = 0
        for _ in pairs(set) do
            n = n + 1
        end

        return n
    end

    return {
        racks = racks,
        guns = guns,
        slots = slots,
        locked = locked,
        open = racks - locked,
        staff = staff,
        restricted = restricted,
        owners = count(owners),
        buckets = count(buckets),
        online = #GetPlayers(),
        byModel = models,
    }
end

---@type table<string, boolean> What the Weapons tab may search in.
views.FIELDS = { any = true, weapon = true, serial = true, owner = true, by = true }

---Every stored gun matching a search, newest racked first.
---@param q string|nil lowercase search term; nil or '' matches everything
---@param field string one of views.FIELDS
---@param limit integer most rows returned
---@return table[] hits
---@return integer total how many matched in all
function views.searchWeapons(q, field, limit)
    local function has(...)
        if not q or q == '' then return true end

        for i = 1, select('#', ...) do
            local v = select(i, ...)

            if v ~= nil and tostring(v):lower():find(q, 1, true) then return true end
        end

        return false
    end

    local hits = {}
    for _, r in ipairs(standing()) do
        local def = fit.rack(r.model) or {}
        for index, rec in pairs(r.slots) do
            local label = inventory.label(rec.item)
            local serial = weapons.serial(rec.metadata)
            local match

            if field == 'weapon' then
                match = has(rec.name, label)
            elseif field == 'serial' then
                match = has(serial)
            elseif field == 'owner' then
                match = has(r.owner, r.ownerName)
            elseif field == 'by' then
                match = has(rec.by, rec.byName)
            else
                match = has(rec.name, label, serial, r.owner, r.ownerName, rec.by, rec.byName)
            end

            if match then
                hits[#hits + 1] = {
                    rackId = r.id,
                    rackLabel = def.label or r.model,
                    model = r.model,
                    slot = index,
                    name = rec.name,
                    label = label,
                    serial = serial,
                    ammo = weapons.ammo(rec.metadata),
                    owner = r.owner,
                    ownerName = r.ownerName,
                    by = rec.by,
                    byName = rec.byName,
                    at = rec.at or 0,
                    bucket = r.bucket,
                    x = r.coords.x,
                    y = r.coords.y,
                    z = r.coords.z,
                }
            end
        end
    end

    table.sort(hits, function(a, b)
        if a.at ~= b.at then
            return a.at > b.at
        end

        if a.rackId ~= b.rackId then
            return a.rackId < b.rackId
        end

        return a.slot < b.slot
    end)

    local total = #hits
    for i = total, limit + 1, -1 do
        hits[i] = nil
    end

    return hits, total
end

---Everyone on the server, with their racks.
---@return table[] rows { src, name, username, cid, job, jobGrade, gang, gangGrade, guns, racks }
function views.players()
    local online = views.online()
    local byOwner = {}
    for _, r in ipairs(standing()) do
        if r.owner then
            byOwner[r.owner] = byOwner[r.owner] or {}
            table.insert(byOwner[r.owner], r)
        end
    end

    local out = {}
    for _, s in ipairs(GetPlayers()) do
        local src = math.tointeger(tonumber(s))

        if src then
            local okId, cid = pcall(player.getIdentifier, src)

            cid = okId and cid or nil

            local okName, name = pcall(player.getName, src)
            local racks, guns = {}, 0

            for _, r in ipairs(cid and byOwner[cid] or {}) do
                local row = views.rackRow(r, online)
                racks[#racks + 1] = row
                guns = guns + row.stored
            end

            out[#out + 1] = {
                src = src,
                name = (okName and name ~= 'Unknown') and name or GetPlayerName(src),
                username = GetPlayerName(src),
                cid = cid,
                job = job.getName(src),
                jobGrade = tonumber(job.getGrade(src)) or 0,
                gang = gang.getName(src),
                gangGrade = tonumber(gang.getGrade(src)) or 0,
                guns = guns,
                racks = racks,
            }
        end
    end

    table.sort(out, function(a, b) return a.src < b.src end)

    return out
end

return views
