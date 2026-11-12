---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Rack fits (shared.fit): which models exist.
local fit = require 'shared.fit'
---@type table Client helpers (client.racks.util): native booleans, notify.
local util = require 'client.racks.util'
---@type table The placer (client.racks.placement): staff racks put down from the Place tab.
local placement = require 'client.racks.placement'

---@type table Admin module; the table returned at end of file.
local admin = {}

-- The staff console (web/src/admin), opened by /gunracks. What it lists comes from the server, so
-- what staff edit is what the server holds and not this client's copy of it. Every change is the
-- server's to allow (the staff ace is checked there, on every call, and every call is paced and
-- logged); this file only carries calls there and back, puts street names on the racks it lists,
-- moves the admin when they go to a rack, and steps the console aside for the placer.

---@type boolean Whether the console is up and holding NUI focus.
local open = false
---@type table|nil What the console was last opened with ({ perms, pollMs }): what it is opened with
---again when it has only stepped aside for the placer.
local lastPayload

---@type string[] Every console call the server answers (shared/admin_callbacks.lua).
local RELAYED = require 'shared.admin_callbacks'

---@type table<string, boolean> Calls this file answers itself, after asking the server.
local OWN = { teleport = true }

---@param name string server callback after 'sd-gunracks:server:admin:'
---@param data any
---@return table res { ok, err? } or what the handler answered
local function relay(name, data)
    local ok, res = pcall(lib.callback.await, 'sd-gunracks:server:admin:' .. name, false, data)

    if not ok or type(res) ~= 'table' then
        log.warn('admin', "'%s' did not come back from the server: %s", name, tostring(res))
        return { ok = false, err = locale('err.no_answer') }
    end

    return res
end

---@type table<string, { street: string|nil, zone: string|nil }> Street and area by rounded position:
---racks do not move, and the console asks for the same ones every few seconds.
local places = {}

---Put the street and the area a rack (or a stored gun's rack) stands in on its row. Cheap game
---lookups, from the coords the server sent; cached by position.
---@param row table|nil with x, y, z
local function name(row)
    if type(row) ~= 'table' or not tonumber(row.x) or not tonumber(row.y) then return end

    local x, y, z = row.x + 0.0, row.y + 0.0, (tonumber(row.z) or 0.0) + 0.0
    local key = ('%d:%d:%d'):format(math.floor(x), math.floor(y), math.floor(z))
    local p = places[key]

    if not p then
        local streetHash = GetStreetNameAtCoord(x, y, z)
        local street = streetHash and streetHash ~= 0 and GetStreetNameFromHashKey(streetHash) or nil
        local zoneLabel = GetLabelText(GetNameOfZone(x, y, z))
        p = {
            street = (street and street ~= '') and street or nil,
            zone = (zoneLabel and zoneLabel ~= '' and zoneLabel ~= 'NULL') and zoneLabel or nil,
        }
        places[key] = p
    end

    row.street, row.zone = p.street, p.zone
end

---Name the places in an answer that lists racks.
---@param what string the call
---@param res table its answer
---@return table res
local function placesIn(what, res)
    if what == 'getRacks' or what == 'searchWeapons' then
        for _, row in ipairs(type(res.list) == 'table' and res.list or {}) do
            name(row)
        end
    elseif what == 'getRack' then
        name(res.rack)
    elseif what == 'getPlayers' then
        for _, p in ipairs(type(res.list) == 'table' and res.list or {}) do
            for _, row in ipairs(type(p.racks) == 'table' and p.racks or {}) do
                name(row)
            end
        end
    end

    return res
end

---@param payload table|nil { perms, pollMs } as the server assembled it
local function openPanel(payload)
    if open or placement.isActive() then return end

    open = true
    lastPayload = payload
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'sd-gunracks:admin:open',
        data = {
            perms = (type(payload) == 'table' and payload.perms) or {},
            pollMs = (type(payload) == 'table' and payload.pollMs) or nil,
        },
    })
    log.debug('admin', 'console opened')
end

local function closePanel()
    if not open then return end

    open = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'sd-gunracks:admin:close', data = {} })
    log.debug('admin', 'console closed')
end

---The server opens the console when staff type /gunracks.
---@param payload { perms: table, pollMs: table }|nil
RegisterNetEvent('sd-gunracks:client:admin:open', function(payload)
    openPanel(payload)
end)

RegisterNUICallback('admin:close', function(_, cb)
    closePanel()
    cb({ ok = true })
end)

for _, call in ipairs(RELAYED) do
    if not OWN[call] then
        RegisterNUICallback('admin:' .. call, function(data, cb)
            if not open then
                return cb({ ok = false, err = locale('err.console_closed') })
            end

            local res = relay(call, data)

            cb(res.ok == false and res or placesIn(call, res))
        end)
    end
end

---@type integer Milliseconds the ground has to stream in before the move gives up looking for it.
local GROUND_MS = 8000

---Stand the admin where the server said: in front of the rack, facing it. The height given is the
---rack's base (a wall rack's is up the wall), so the ground near it is looked for, the car held still
---while it streams in (a frozen driver in a free car falls through the map with it).
---@param x number
---@param y number
---@param z number
---@param h number heading to face
local function goTo(x, y, z, h)
    local ped = cache.ped
    local held = cache.vehicle or ped

    SetPedCoordsKeepVehicle(ped, x, y, z + 1.0)
    FreezeEntityPosition(held, true)

    local landed
    local deadline = GetGameTimer() + GROUND_MS

    repeat
        RequestCollisionAtCoord(x, y, z)

        if util.yes(HasCollisionLoadedAroundEntity(held)) then
            local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 1.5, false)

            if util.yes(found) and math.abs(groundZ - z) <= 4.0 then
                landed = groundZ
            end
        end

        if not landed then
            Wait(50)
        end
    until landed or GetGameTimer() >= deadline

    if landed then
        SetPedCoordsKeepVehicle(ped, x, y, landed + 0.05)
    else
        log.warn('admin', 'no ground came in at %.1f, %.1f; let go at the rack\'s height', x, y)
    end

    SetEntityHeading(held, h)
    FreezeEntityPosition(held, false)
end

---Go to a rack: the server says where (and logs it), then the admin is moved there.
RegisterNUICallback('admin:teleport', function(data, cb)
    if not open then
        return cb({ ok = false, err = locale('err.console_closed') })
    end

    local res = relay('teleport', type(data) == 'table' and data or {})

    if not res.ok then
        return cb(res)
    end

    local x, y, z, h = tonumber(res.x), tonumber(res.y), tonumber(res.z), tonumber(res.h)

    if not (x and y and z) then
        return cb({ ok = false, err = locale('err.no_answer') })
    end

    CreateThread(function() goTo(x, y, z, h or 0.0) end)
    cb({ ok = true, bucket = res.bucket, sameBucket = res.sameBucket })
end)

---Staff placing a rack from the Place tab: the console steps aside for the placer, and comes back
---up when the rack is placed or put away. The server checks the model and the access list again
---when the placer confirms (adminPlace).
RegisterNUICallback('admin:place', function(data, cb)
    if not open then
        return cb({ ok = false, err = locale('err.console_closed') })
    end

    data = type(data) == 'table' and data or {}

    local model = data.model

    if type(model) ~= 'string' or not fit.rack(model) then
        return cb({ ok = false, err = locale('err.bad_model') })
    end

    if placement.isActive() then
        return cb({ ok = false, err = locale('placement.already') })
    end

    local payload = lastPayload

    closePanel()
    cb({ ok = true })

    placement.start(model, {
        admin = { access = type(data.access) == 'table' and data.access or nil, locked = data.locked ~= false },
        onFinish = function()
            -- Back up a moment after the placer let go of the cursor, for the same reason it waits
            -- before taking it: the two share one counter with every other resource.
            SetTimeout(150, function() openPanel(payload) end)
        end,
    })
end)

---Close the console and hand focus back (resource stop).
function admin.cleanup()
    closePanel()
end

return admin
