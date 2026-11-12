---@type table Client target bridge exposing zone/entity registration helpers and the active system name.
local target = {}

---@type table Tagged debug logger for this file (bridge.shared.debug).
local dprint = require('bridge.shared.debug').tag('bridge:target')

---@type string[] Supported target resources probed in priority order.
local SUPPORTED = { 'ox_target', 'qb-target', 'qtarget' }

---Detects which supported target resource is currently running.
---@return string|nil resource name, or nil if none are started.
local function detect()
    dprint('detecting target resource...')
    for i = 1, #SUPPORTED do
        local state = GetResourceState(SUPPORTED[i])
        dprint('  probe: %-12s state=%s', SUPPORTED[i], state)
        if state == 'started' then
            dprint('selected backend: %s', SUPPORTED[i])
            return SUPPORTED[i]
        end
    end
    dprint('^1no supported target resource found^7')
    return nil
end

---@type string|nil The detected active target resource name.
local active = detect()
if not active then
    error('No target resource found. Install ox_target, qb-target, or qtarget.')
end

dprint('target system active: %s', active)

---Translates ox_target option entries to the qb-target/qtarget shape. ox_-
---target uses `onSelect` + a flat option list; the others want `action` and
---a wrapping `options = {}` field at call time (handled by each Target.add*
---function below).
---@param options table[]
---@return table[]
local function convertOptions(options)
    if active == 'ox_target' then return options end

    local out = {}
    for i = 1, #options do
        local o = options[i]
        out[#out + 1] = {
            type = o.type or 'client',
            event = o.event,
            icon = o.icon,
            label = o.label,
            action = o.onSelect,
            canInteract = o.canInteract,
            distance = o.distance,
            groups = o.groups,
            items = o.items,
        }
    end
    return out
end

---Registers a box-shaped interaction zone at fixed world coordinates.
---@param data table ox_target box-zone data.
---@return any zone The created zone handle/id from the active target resource.
function target.addBoxZone(data)
    dprint('addBoxZone: name=%s coords=%s backend=%s', tostring(data.name), tostring(data.coords), active)
    if active == 'ox_target' then
        local zone = exports.ox_target:addBoxZone(data)
        dprint('addBoxZone: ox_target returned zone=%s', tostring(zone))
        return zone
    end

    local name = data.name or ('box_zone_' .. math.random(100000, 999999))
    local size = data.size or vec3(2, 2, 2)
    local heading = data.rotation or 0

    dprint('addBoxZone: %s — name=%s size=%s heading=%s', active, name, tostring(size), tostring(heading))
    return exports[active]:AddBoxZone(name, data.coords, size.x, size.y, {
        name = name,
        heading = heading,
        debugPoly = data.debug or false,
        minZ = data.coords.z - (size.z / 2),
        maxZ = data.coords.z + (size.z / 2),
    }, {
        options = convertOptions(data.options),
        distance = data.distance or 2.5,
    })
end

---Registers a sphere-shaped interaction zone at fixed world coordinates.
---@param data table ox_target sphere-zone data.
---@return any zone The created zone handle/id from the active target resource.
function target.addSphereZone(data)
    dprint('addSphereZone: name=%s coords=%s radius=%s backend=%s',
        tostring(data.name), tostring(data.coords), tostring(data.radius), active)
    if active == 'ox_target' then
        local zone = exports.ox_target:addSphereZone(data)
        dprint('addSphereZone: ox_target returned zone=%s', tostring(zone))
        return zone
    end

    local name = data.name or ('sphere_zone_' .. math.random(100000, 999999))
    dprint('addSphereZone: %s — name=%s radius=%s', active, name, tostring(data.radius or 1.0))
    return exports[active]:AddCircleZone(name, data.coords, data.radius or 1.0, {
        name = name,
        useZ = true,
        debugPoly = data.debug or false,
    }, {
        options = convertOptions(data.options),
        distance = data.distance or 2.5,
    })
end

---Registers a polygon-shaped interaction zone defined by an array of points.
---@param data table ox_target poly-zone data.
---@return any zone The created zone handle/id from the active target resource.
function target.addPolyZone(data)
    dprint('addPolyZone: name=%s points=%s backend=%s',
        tostring(data.name), tostring(data.points and #data.points or 0), active)
    if active == 'ox_target' then
        local zone = exports.ox_target:addPolyZone(data)
        dprint('addPolyZone: ox_target returned zone=%s', tostring(zone))
        return zone
    end

    local name = data.name or ('poly_zone_' .. math.random(100000, 999999))
    dprint('addPolyZone: %s — name=%s thickness=%s', active, name, tostring(data.thickness or 2))
    return exports[active]:AddPolyZone(name, data.points, {
        name = name,
        debugPoly = data.debug or false,
        minZ = data.coords and data.coords.z - (data.thickness or 2) / 2,
        maxZ = data.coords and data.coords.z + (data.thickness or 2) / 2,
    }, {
        options = convertOptions(data.options),
        distance = data.distance or 2.5,
    })
end

---Attaches target options to a *networked* entity addressed by its net id.
---@param netId number
---@param options table[]
---@return boolean
function target.addEntity(netId, options)
    dprint('addEntity: netId=%s optionCount=%s backend=%s',
        tostring(netId), tostring(options and #options or 0), active)
    if active == 'ox_target' then
        return exports.ox_target:addEntity(netId, options)
    end
    local entity = NetworkGetEntityFromNetworkId(netId)
    dprint('addEntity: %s — entity=%s', active, tostring(entity))
    exports[active]:AddTargetEntity(entity, {
        options = convertOptions(options),
        distance = options.distance or 2.5,
    })
    return true
end

---Attaches target options to a client-local entity (not networked).
---@param entity number Local entity (not networked).
---@param options table[]
---@return boolean
function target.addLocalEntity(entity, options)
    dprint('addLocalEntity: entity=%s optionCount=%s backend=%s',
        tostring(entity), tostring(options and #options or 0), active)
    if active == 'ox_target' then
        return exports.ox_target:addLocalEntity(entity, options)
    end
    exports[active]:AddTargetEntity(entity, {
        options = convertOptions(options),
        distance = options.distance or 2.5,
    })
    return true
end

---Attaches target options to every entity matching one or more model hashes.
---@param models string|number|(string|number)[]
---@param options table[]
---@return boolean
function target.addModel(models, options)
    dprint('addModel: models=%s optionCount=%s backend=%s',
        tostring(type(models) == 'table' and #models or models), tostring(options and #options or 0), active)
    if active == 'ox_target' then
        return exports.ox_target:addModel(models, options)
    end
    exports[active]:AddTargetModel(type(models) == 'table' and models or { models }, {
        options = convertOptions(options),
        distance = options.distance or 2.5,
    })
    return true
end

---Attaches target options to every ped in the world.
---@param options table[]
---@return boolean
function target.addGlobalPed(options)
    dprint('addGlobalPed: optionCount=%s backend=%s', tostring(options and #options or 0), active)
    if active == 'ox_target' then
        return exports.ox_target:addGlobalPed(options)
    end
    exports[active]:AddGlobalPed({
        options = convertOptions(options),
        distance = options.distance or 2.5,
    })
    return true
end

---Attaches target options to every vehicle in the world.
---@param options table[]
---@return boolean
function target.addGlobalVehicle(options)
    dprint('addGlobalVehicle: optionCount=%s backend=%s', tostring(options and #options or 0), active)
    if active == 'ox_target' then
        return exports.ox_target:addGlobalVehicle(options)
    end
    exports[active]:AddGlobalVehicle({
        options = convertOptions(options),
        distance = options.distance or 2.5,
    })
    return true
end

---Attaches target options to every world object.
---@param options table[]
---@return boolean
function target.addGlobalObject(options)
    dprint('addGlobalObject: optionCount=%s backend=%s', tostring(options and #options or 0), active)
    if active == 'ox_target' then
        return exports.ox_target:addGlobalObject(options)
    end
    exports[active]:AddGlobalObject({
        options = convertOptions(options),
        distance = options.distance or 2.5,
    })
    return true
end

---Attaches target options to every other player.
---@param options table[]
---@return boolean
function target.addGlobalPlayer(options)
    dprint('addGlobalPlayer: optionCount=%s backend=%s', tostring(options and #options or 0), active)
    if active == 'ox_target' then
        return exports.ox_target:addGlobalPlayer(options)
    end
    exports[active]:AddGlobalPlayer({
        options = convertOptions(options),
        distance = options.distance or 2.5,
    })
    return true
end

---Removes a previously-registered zone by id.
---@param id any Zone id returned from the matching `add…Zone` call.
---@return boolean
function target.removeZone(id)
    dprint('removeZone: id=%s backend=%s', tostring(id), active)
    if active == 'ox_target' then
        return exports.ox_target:removeZone(id)
    end
    exports[active]:RemoveZone(id)
    return true
end

---Removes a target option from a networked entity.
---@param netId number
---@param label? string Specific option label to remove. Removes all when omitted.
---@return boolean
function target.removeEntity(netId, label)
    dprint('removeEntity: netId=%s label=%s backend=%s', tostring(netId), tostring(label), active)
    if active == 'ox_target' then
        return exports.ox_target:removeEntity(netId, label)
    end
    exports[active]:RemoveTargetEntity(NetworkGetEntityFromNetworkId(netId), label)
    return true
end

---Removes a target option from a client-local entity.
---@param entity number
---@param label? string Specific option label to remove. Removes all when omitted.
---@return boolean
function target.removeLocalEntity(entity, label)
    dprint('removeLocalEntity: entity=%s label=%s backend=%s', tostring(entity), tostring(label), active)
    if active == 'ox_target' then
        return exports.ox_target:removeLocalEntity(entity, label)
    end
    exports[active]:RemoveTargetEntity(entity, label)
    return true
end

---Removes a target option attached via `addModel`.
---@param models string|number|(string|number)[]
---@param label? string Specific option label to remove. Removes all when omitted.
---@return boolean
function target.removeModel(models, label)
    dprint('removeModel: models=%s label=%s backend=%s',
        tostring(type(models) == 'table' and #models or models), tostring(label), active)
    if active == 'ox_target' then
        return exports.ox_target:removeModel(models, label)
    end
    exports[active]:RemoveTargetModel(type(models) == 'table' and models or { models }, label)
    return true
end

---Removes a global ped target option.
---@param label? string Specific option label to remove. Removes all when omitted.
---@return boolean
function target.removeGlobalPed(label)
    dprint('removeGlobalPed: label=%s backend=%s', tostring(label), active)
    if active == 'ox_target' then
        return exports.ox_target:removeGlobalPed(label)
    end
    exports[active]:RemoveGlobalPed(label)
    return true
end

---Removes a global vehicle target option.
---@param label? string Specific option label to remove. Removes all when omitted.
---@return boolean
function target.removeGlobalVehicle(label)
    dprint('removeGlobalVehicle: label=%s backend=%s', tostring(label), active)
    if active == 'ox_target' then
        return exports.ox_target:removeGlobalVehicle(label)
    end
    exports[active]:RemoveGlobalVehicle(label)
    return true
end

---Removes a global object target option.
---@param label? string Specific option label to remove. Removes all when omitted.
---@return boolean
function target.removeGlobalObject(label)
    dprint('removeGlobalObject: label=%s backend=%s', tostring(label), active)
    if active == 'ox_target' then
        return exports.ox_target:removeGlobalObject(label)
    end
    exports[active]:RemoveGlobalObject(label)
    return true
end

---Removes a global player target option.
---@param label? string Specific option label to remove. Removes all when omitted.
---@return boolean
function target.removeGlobalPlayer(label)
    dprint('removeGlobalPlayer: label=%s backend=%s', tostring(label), active)
    if active == 'ox_target' then
        return exports.ox_target:removeGlobalPlayer(label)
    end
    exports[active]:RemoveGlobalPlayer(label)
    return true
end

target.system = active

return target
