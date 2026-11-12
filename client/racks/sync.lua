---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Client rack mirror (client.racks.state).
local state = require 'client.racks.state'
---@type table Rack drawing (client.racks.spawn): stream points, props, guns.
local spawn = require 'client.racks.spawn'

---@type table Sync module; the table returned at end of file.
local sync = {}

---Apply a full list from the server (first load, a routing-bucket change, a job/character change):
---racks no longer in it are removed, new ones tracked, the rest redrawn where they changed.
---@param payload table|nil { bucket, me, racks }
function sync.apply(payload)
    if type(payload) ~= 'table' then return end

    local previous = state.replace(payload)
    for id in pairs(previous) do
        if not state.get(id) then
            spawn.untrack(id)
        end
    end

    for id in pairs(state.all()) do
        if previous[id] then
            spawn.refresh(id)
        else
            spawn.track(id)
        end
    end

    log.debug('sync', 'bucket %s: %d racks', tostring(payload.bucket), #(payload.racks or {}))
end

---Ask the server for this player's racks (resource start / join).
function sync.request()
    sync.apply(lib.callback.await('sd-gunracks:server:getRacks', false))
end

---The whole list again.
---@param payload table
RegisterNetEvent('sd-gunracks:client:sync', function(payload)
    sync.apply(payload)
end)

---One rack was placed or changed.
---@param view table
RegisterNetEvent('sd-gunracks:client:upsert', function(view)
    if type(view) ~= 'table' or not view.id then return end

    if state.upsert(view) then
        spawn.track(view.id)
    else
        spawn.refresh(view.id)
    end
end)

---One rack was removed.
---@param id integer
RegisterNetEvent('sd-gunracks:client:remove', function(id)
    spawn.untrack(id)
    state.remove(id)
end)

return sync
