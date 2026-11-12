---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Access rules (shared.access): what this viewer may do at each rack.
local access = require 'shared.access'
---@type table Weapon metadata reads (shared.weapons): the public per-slot view.
local weapons = require 'shared.weapons'
---@type table Live racks (server.racks.registry).
local registry = require 'server.racks.registry'
---@type table Player facts from the bridge (server.racks.actor).
local actor = require 'server.racks.actor'

---@type table Sync module; the table returned at end of file.
local sync = {}

-- Players who have asked for their racks at least once, with the bucket and role signature their
-- copy was built for. Only these get pushes (a client still loading has no handler yet), and the
-- watch loop resends a player's whole list when either value moves.
---@type table<integer, { bucket: integer, sig: string }>
local known = {}

---What one viewer may see of a rack: enough to draw it and to decide which options to show. The
---owner, access list, serials, ammo and who racked each gun stay on the server; per slot only the
---weapon name, its attachments (as strings) and its tint go out.
---@param rack Rack
---@param a RackActor the viewer
---@return table view
function sync.view(rack, a)
    local slots = {}
    for i, rec in pairs(rack.slots) do
        slots[i] = weapons.publicSlot(rec)
    end

    return {
        id = rack.id,
        model = rack.model,
        x = rack.coords.x,
        y = rack.coords.y,
        z = rack.coords.z,
        heading = rack.heading,
        locked = rack.locked,
        mine = access.isOwner(rack, a),
        allowed = (access.canUse(rack, a)),
        manage = access.canManage(rack, a),
        forceable = access.canForce(rack, a, config.Interact.Force),
        slots = slots,
    }
end

---The viewer's own flags the client needs for options that do not depend on one rack.
---@param a RackActor
---@return table me { admin, police, forceItem }
local function me(a)
    local F = config.Interact.Force or {}

    return { admin = a.admin, police = a.police, forceItem = F.Enabled and F.Item or false }
end

---Everything one player should have: the racks of their own routing bucket, as seen by them.
---Remembers them as synced, so later pushes reach them.
---@param src integer player server id
---@return table payload { bucket, me, racks }
function sync.payload(src)
    local a = actor.of(src)
    local bucket = GetPlayerRoutingBucket(src)
    local list = {}

    if registry.ready() then
        for _, rack in ipairs(registry.inBucket(bucket)) do
            if not rack.removing then
                list[#list + 1] = sync.view(rack, a)
            end
        end
    end

    known[src] = { bucket = bucket, sig = actor.signature(a) }

    return { bucket = bucket, me = me(a), racks = list }
end

---Send one player their whole list again (bucket change, character / job change, boot).
---@param src integer player server id
function sync.player(src)
    TriggerClientEvent('sd-gunracks:client:sync', src, sync.payload(src))
end

---Resend every synced player's list (after the boot load finishes).
function sync.everyone()
    for src in pairs(known) do
        sync.player(src)
    end
end

---Tell every synced player in the rack's bucket about its new state. Each gets their own view,
---because whether it is theirs (and what they may do with it) differs per player.
---@param rack Rack
function sync.push(rack)
    for src, k in pairs(known) do
        if k.bucket == rack.bucket then
            TriggerClientEvent('sd-gunracks:client:upsert', src, sync.view(rack, actor.of(src)))
        end
    end
end

---Tell every synced player in the rack's bucket that it is gone.
---@param rack Rack the removed rack (still carries its id and bucket)
function sync.drop(rack)
    for src, k in pairs(known) do
        if k.bucket == rack.bucket then
            TriggerClientEvent('sd-gunracks:client:remove', src, rack.id)
        end
    end
end

---One pass of the watch loop: anyone whose routing bucket, character, job, gang or staff status
---changed since their last list gets a fresh one. Cheap enough to run every couple of seconds:
---a bucket read and a few bridge field reads per player.
function sync.watch()
    for src, k in pairs(known) do
        if GetPlayerName(src) == nil then
            known[src] = nil
        else
            local bucket = GetPlayerRoutingBucket(src)
            local sig = actor.signature(actor.of(src))

            if bucket ~= k.bucket or sig ~= k.sig then
                log.debug('sync', 'resync src=%s bucket %s -> %s', src, tostring(k.bucket), tostring(bucket))
                sync.player(src)
            end
        end
    end
end

---Forget a departed player.
---@param src integer
function sync.forget(src)
    known[src] = nil
end

return sync
