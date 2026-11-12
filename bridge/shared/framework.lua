---@class FrameworkInfo
---@field name 'qb'|'esx' Detected framework identifier.
---@field isQbx boolean True when the qb backend is actually Qbox (qbx_core providing qb-core).
---@field core any Live core object (`exports['qb-core']:GetCoreObject()` or ESX shared object).

---@type table Tagged debug logger for this file (bridge.shared.debug).
local dprint = require('bridge.shared.debug').tag('bridge:framework')

---Detects which framework is running and returns a populated `FrameworkInfo`
---table, or nil if neither qb-core nor es_extended is started. Qbox counts as
---'qb': qbx_core `provide`s qb-core, so the compat core object resolves through
---the same export — `isQbx` is stamped so modules can prefer qbx-native
---exports (e.g. qbx_vehicles) when they exist.
---@return FrameworkInfo|nil
local function detect()
    dprint('probing for framework...')
    dprint('  qb-core state=%s (qbx_core state=%s)', GetResourceState('qb-core'), GetResourceState('qbx_core'))
    if GetResourceState('qb-core') == 'started' then
        local isQbx = GetResourceState('qbx_core') == 'started'
        dprint('selected backend: qb (isQbx=%s)', tostring(isQbx))
        return { name = 'qb', isQbx = isQbx, core = exports['qb-core']:GetCoreObject() }
    end
    dprint('  es_extended state=%s', GetResourceState('es_extended'))
    if GetResourceState('es_extended') == 'started' then
        dprint('selected backend: esx')
        return { name = 'esx', isQbx = false, core = exports['es_extended']:getSharedObject() }
    end
    dprint('^1no supported framework found — qb-core and es_extended both not started^7')
    return nil
end

---@type FrameworkInfo|nil Detected framework descriptor, or nil if none is started.
local info = detect()

if not info then
    error([[
        ^1CRITICAL ERROR: No supported framework detected!^0
        ^3This resource requires one of the following frameworks:^0
        - QBCore / Qbox (qb-core / qbx_core)
        - ESX (es_extended)

        Please ensure your framework is started before this resource.
    ]])
end

dprint('framework resolved: name=%s core=%s', info.name, tostring(info.core))
print(('^2[SD-GUNRACKS]^0 Framework detected: ^3%s%s^0'):format(info.name, info.isQbx and ' (qbox)' or ''))

return info
