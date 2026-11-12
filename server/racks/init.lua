---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Server persistence (server.racks.store): schema bootstrap.
local store = require 'server.racks.store'
---@type table Live racks (server.racks.registry): the boot load.
local registry = require 'server.racks.registry'
---@type table Per-bucket client sync (server.racks.sync).
local sync = require 'server.racks.sync'
---@type table Per-player request pacing (server.racks.limits).
local limits = require 'server.racks.limits'
---@type table Authoritative player handlers (server.racks.actions).
local actions = require 'server.racks.actions'
---@type table Staff handlers, the console's callbacks and the /gunracks command (server.racks.admin).
local admin = require 'server.racks.admin'
---@type table Audit-log helper (server.racks.audit): the log table's retention.
local audit = require 'server.racks.audit'
---@type table Inventory bridge (bridge.server.inventory): usable rack items.
local inventory = require 'bridge.server.inventory'
---@type table Player bridge (bridge.server.player): the character-loaded hook.
local player = require 'bridge.server.player'
-- Loaded for side effects: GetRacks / GetRack / CreateRack / DeleteRack self-register.
require 'server.racks.exports'

-- Boot: make sure the table exists, load every rack into memory, then resend the list to anyone
-- who asked while the load was still running (they were given an empty one). Then the audit table,
-- and its retention pass, now and every Logs.Database.PruneEveryMinutes.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)

    if not ok then
        log.error(nil, 'schema bootstrap failed: %s', err)
        return
    end

    math.randomseed(os.time())

    local n = registry.load()

    log.info(nil, 'loaded %d gun racks', n)
    sync.everyone()

    -- The audit table after the racks, so a failure here costs the Logs tab and nothing else.
    local okLog, errLog = pcall(store.ensureLogSchema)

    if not okLog then
        log.error(nil, 'log table bootstrap failed (the console will have no Logs): %s', errLog)
        return
    end

    local every = math.max(1, math.floor(tonumber(((config.Logs or {}).Database or {}).PruneEveryMinutes) or 60)) * 60000

    while true do
        local okPrune, errPrune = pcall(audit.prune)

        if not okPrune then
            log.error('audit', 'log prune failed: %s', errPrune)
        end

        Wait(every)
    end
end)

-- Authoritative callbacks: thin delegates into server.racks.actions / server.racks.admin, which own
-- the validation and every change (each handler is documented there).
lib.callback.register('sd-gunracks:server:getRacks', function(src)
    return sync.payload(src)
end)

lib.callback.register('sd-gunracks:server:place', function(src, payload)
    return actions.place(src, payload)
end)

lib.callback.register('sd-gunracks:server:store', function(src, payload)
    return actions.store(src, payload)
end)

lib.callback.register('sd-gunracks:server:take', function(src, payload)
    return actions.take(src, payload)
end)

lib.callback.register('sd-gunracks:server:seize', function(src, payload)
    return actions.seize(src, payload)
end)

lib.callback.register('sd-gunracks:server:inspect', function(src, payload)
    return actions.inspect(src, payload)
end)

lib.callback.register('sd-gunracks:server:listWeapons', function(src, payload)
    return actions.listWeapons(src, payload)
end)

lib.callback.register('sd-gunracks:server:setLocked', function(src, payload)
    return actions.setLocked(src, payload)
end)

lib.callback.register('sd-gunracks:server:pickup', function(src, payload)
    return actions.pickup(src, payload)
end)

lib.callback.register('sd-gunracks:server:forceStart', function(src, payload)
    return actions.forceStart(src, payload)
end)

lib.callback.register('sd-gunracks:server:forceFinish', function(src, payload)
    return actions.forceFinish(src, payload)
end)

-- The staff placer's confirm. The console's own calls (sd-gunracks:server:admin:<name>) register
-- themselves in server.racks.admin, behind its staff gate and pacing.
lib.callback.register('sd-gunracks:server:adminPlace', function(src, payload)
    return admin.place(src, payload)
end)

---The player left placement mode without placing; drop their session.
RegisterNetEvent('sd-gunracks:server:cancelPlacement', function()
    actions.cancelPlacement(source)
end)

-- Every rack item opens placement mode for its model. The handler gets the inventory slot the item
-- was used from where the inventory reports it, so the confirm removes that exact item.
for item in pairs(config.Racks.Items) do
    inventory.registerUsable(item, function(src, used, _inv, slot)
        -- ox passes the slot number; qb-style backends pass the used item row, which carries it.
        local invSlot = (type(slot) == 'table' and slot.slot) or slot or (type(used) == 'table' and used.slot) or nil
        actions.beginPlacement(src, item, invSlot)
    end)
end

-- A character loaded (or was switched): their view depends on who they are, so resend it.
player.onLoaded(function(src)
    sync.player(src)
end)

---Forget everything kept per player when they leave (server ids are reused).
---@param _reason string disconnect reason (unused)
AddEventHandler('playerDropped', function(_reason)
    local src = source

    sync.forget(src)
    limits.forget(src)
    actions.forget(src)
    admin.forget(src)
end)

-- The watch loop: anyone who changed routing bucket, character, job or gang gets their rack list
-- rebuilt. Coarse on purpose; nothing here is frame-sensitive.
CreateThread(function()
    while true do
        Wait((config.Sync and config.Sync.PollMs) or 2000)

        if registry.ready() then
            local ok, err = pcall(sync.watch)

            if not ok then
                log.error('sync', 'watch pass failed: %s', err)
            end
        end
    end
end)
