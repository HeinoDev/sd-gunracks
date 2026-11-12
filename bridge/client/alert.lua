---@type table Tagged debug logger for the alert bridge; gated under 'bridge:alert' (bridge.shared.debug).
local dprint = require('bridge.shared.debug').tag('bridge:alert')

---@type table Client police-dispatch bridge exposing the alert API.
local alert = {}

---@type string[] Supported dispatch resources, probed in priority order.
local SUPPORTED = {
    'linden_outlawalert',
    'cd_dispatch',
    'fd_dispatch',
    'ps-dispatch',
    'qs-dispatch',
    'core_dispatch',
    'origen_police',
    'codem-dispatch',
    'tk_dispatch',
}

---@alias AlertContext { coords: vector3, location: string, gender: string, jobs: string[] }

---Player gender label for dispatches that surface it.
---@return string
local function getGender()
    return IsPedMale(PlayerPedId()) and 'Male' or 'Female'
end

---"Street" or "Street & Cross" label at the given coords.
---@param coords vector3
---@return string
local function streetLabel(coords)
    local s1, s2 = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local label = GetStreetNameFromHashKey(s1)
    if s2 and s2 ~= 0 then
        local cross = GetStreetNameFromHashKey(s2)
        if cross and cross ~= '' then
            label = label .. ' & ' .. cross
        end
    end
    return label
end

---@type table<string, fun(data: table, ctx: AlertContext)> Per-dispatch payload builders.
local HANDLERS = {
    ['linden_outlawalert'] = function(data, ctx)
        TriggerServerEvent('wf-alerts:svNotify', {
            dispatchData = {
                displayCode = data.displayCode,
                description = data.description,
                isImportant = 0,
                recipientList = ctx.jobs,
                length = '10000',
                infoM = 'fa-info-circle',
                info = data.message,
            },
            caller = 'Citizen',
            coords = ctx.coords,
        })
    end,

    ['cd_dispatch'] = function(data, ctx)
        TriggerServerEvent('cd_dispatch:AddNotification', {
            job_table = ctx.jobs,
            coords = ctx.coords,
            title = data.title,
            message = data.message .. ' on ' .. ctx.location,
            flash = 0,
            unique_id = math.random(999999999),
            sound = 1,
            blip = {
                sprite = data.sprite,
                scale = data.scale,
                colour = data.colour,
                flashes = false,
                text = data.blipText,
                time = 5,
                radius = 0,
            },
        })
    end,

    ['fd_dispatch'] = function(data, ctx)
        TriggerServerEvent('fd_dispatch:events:addAlert', {
            title = data.title or 'Alert',
            description = data.description or (data.message .. ' on ' .. ctx.location),
            blip = {
                sprite = data.sprite or 52,
                color = data.colour or 1,
                scale = data.scale or 1.0,
                time = data.blipTime or (15 * 1000),
            },
            groups = data.groups or ctx.jobs,
            priority = data.priority or 1,
            code = data.displayCode or data.code or '10-99',
            location = ctx.location,
            metadata = data.metadata or {},
            isEmergency = data.isEmergency or false,
        })
    end,

    ['ps-dispatch'] = function(data, ctx)
        TriggerServerEvent('ps-dispatch:server:notify', {
            message = data.title,
            codeName = data.dispatchcodename,
            code = data.displayCode,
            icon = 'fas fa-info-circle',
            priority = 2,
            coords = ctx.coords,
            gender = ctx.gender,
            street = ctx.location,
            jobs = ctx.jobs,
        })
    end,

    ['qs-dispatch'] = function(data, ctx)
        TriggerServerEvent('qs-dispatch:server:CreateDispatchCall', {
            job = ctx.jobs,
            callLocation = ctx.coords,
            callCode = { code = data.displayCode, snippet = data.description },
            message = data.message .. ' on ' .. ctx.location,
            flashes = false,
            blip = {
                sprite = data.sprite,
                scale = data.scale,
                colour = data.colour,
                flashes = true,
                text = data.blipText,
                time = (6 * 60 * 1000),
            },
        })
    end,

    ['core_dispatch'] = function(data, ctx)
        TriggerServerEvent('core_dispatch:addCall',
            data.displayCode,
            data.description,
            { { icon = 'fa-info-circle', info = data.message } },
            { ctx.coords.x, ctx.coords.y, ctx.coords.z },
            ctx.jobs,
            10000,
            data.sprite,
            data.colour
        )
    end,

    ['origen_police'] = function(data, ctx)
        TriggerServerEvent('SendAlert:police', {
            coords = ctx.coords,
            title = data.message,
            type = data.displayCode,
            message = data.description,
            job = 'police',
        })
    end,

    ['codem-dispatch'] = function(data, ctx)
        exports['codem-dispatch']:CustomDispatch({
            type = 'Illegal',
            header = data.title,
            text = data.message .. ' on ' .. ctx.location,
            code = data.displayCode,
        })
    end,

    ['tk_dispatch'] = function(data, ctx)
        exports.tk_dispatch:addCall({
            title = data.title,
            code = data.displayCode,
            message = data.message,
            coords = ctx.coords,
            jobs = ctx.jobs,
            blip = {
                sprite = data.sprite,
                scale = data.scale,
                colour = data.colour,
                text = data.blipText,
            },
            playSound = data.playSound,
        })
    end,
}

---Picks the active dispatch resource once at load (first started in SUPPORTED).
---@return string|nil name
local function detect()
    dprint('detecting installed dispatch resource...')
    for i = 1, #SUPPORTED do
        local name = SUPPORTED[i]
        local state = GetResourceState(name)
        dprint('  probe: %-20s state=%s', name, tostring(state))
        if state == 'started' then
            return name
        end
    end
    return nil
end

---@type string|nil Active dispatch resource name, or nil if none started.
local activeName = detect()
alert.system = activeName

if activeName then
    dprint('^2detected ^3%s^7 — police alerts will route through this resource', activeName)
else
    dprint('^3no recognised dispatch resource started^7 — alert.send will no-op')
end

---Sends a police dispatch alert through the detected dispatch resource. No-ops
---(with a debug line) when no supported dispatch is installed. Coords default to
---the player; jobs default to { 'police' }.
---@param data { displayCode?: string, code?: string, title?: string, message?: string, description?: string, sprite?: number, scale?: number, colour?: number, blipText?: string, dispatchcodename?: string, jobs?: string[], coords?: vector3, playSound?: boolean, groups?: string[], priority?: number, metadata?: table, blipTime?: number, isEmergency?: boolean }
function alert.send(data)
    if not activeName then
        dprint('send: no dispatch resource active — ignoring alert (title=%s)', tostring(data and data.title))
        return
    end

    data = data or {}
    local coords = data.coords or GetEntityCoords(PlayerPedId())
    local ctx = {
        coords = coords,
        location = streetLabel(coords),
        gender = getGender(),
        jobs = data.jobs or { 'police' },
    }

    dprint('send: routing to %s (code=%s title=%s)', activeName, tostring(data.displayCode or data.code), tostring(data.title))
    HANDLERS[activeName](data, ctx)
end

_G.Alert = alert

return alert
