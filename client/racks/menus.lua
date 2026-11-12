---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Client rack mirror (client.racks.state).
local state = require 'client.racks.state'
---@type table Client helpers (client.racks.util): labels, notify, progress bars.
local util = require 'client.racks.util'
---@type table Inventory bridge (bridge.client.inventory): holstering after racking.
local inventory = require 'bridge.client.inventory'
---@type table Police dispatch bridge (bridge.client.alert).
local alert = require 'bridge.client.alert'

---@type table Target/progress config (config.Targets).
local T = config.Targets

---@type table Menus module; the table returned at end of file.
local menus = {}

-- Every option ends in one server callback; the server decides. These functions only add the
-- progress bar before it and the notification after it.

---Await a server callback and show its refusal, if any.
---@param name string callback suffix (sd-gunracks:server:<name>)
---@param payload table|nil
---@return table|nil data the response's data on success, nil on refusal
local function ask(name, payload)
    local res = lib.callback.await('sd-gunracks:server:' .. name, false, payload)

    if res and res.success then
        return res.data or {}
    end

    util.notify((res and res.message) or locale('err.save_failed'), 'error')

    return nil
end

---Put a gun on a slot: progress bar, then the server reads the gun out of that inventory slot.
---@param id integer rack id
---@param index integer slot index
---@param invSlot any inventory slot of the gun (nil where the inventory cannot say)
---@param weapon string the gun's inventory item name
function menus.store(id, index, invSlot, weapon)
    if not util.progress(T.Progress.store, locale('progress.store', util.weaponLabel(weapon)), T.Progress.anim) then
        return
    end

    local data = ask('store', { rackId = id, slot = index, invSlot = invSlot, weapon = weapon })

    if not data then return end

    -- ox disarms on its own when the slot empties
    if inventory.system ~= 'ox_inventory' then
        inventory.holster()
    end

    util.notify(locale('notify.stored', util.weaponLabel(data.name or weapon)), 'success')
end

---The "Choose weapon..." menu: every gun the player carries that this slot takes.
---@param id integer
---@param index integer
function menus.choose(id, index)
    local data = ask('listWeapons', { rackId = id, slot = index })

    if not data then return end

    local list = data.list or {}

    if #list == 0 then
        return util.notify(locale('notify.no_weapons'), 'error')
    end

    local options = {}
    for _, w in ipairs(list) do
        options[#options + 1] = {
            title = w.label or util.weaponLabel(w.weapon),
            description = locale('menu.weapon_desc', w.ammo or 0, w.serial or locale('menu.no_serial')),
            icon = 'gun',
            onSelect = function() menus.store(id, index, w.invSlot, w.weapon) end,
        }
    end

    lib.registerContext({ id = 'sd_gunracks_choose', title = locale('menu.choose_title'), options = options })
    lib.showContext('sd_gunracks_choose')
end

---Take a gun off a slot.
---@param id integer
---@param index integer
function menus.take(id, index)
    local v = state.get(id)
    local s = v and v.slots and v.slots[index]

    if not s then return end

    if not util.progress(T.Progress.take, locale('progress.take', util.weaponLabel(s.name)), T.Progress.anim) then
        return
    end

    local data = ask('take', { rackId = id, slot = index })

    if data then
        util.notify(locale('notify.taken', util.weaponLabel(data.name or s.name)), 'success')
    end
end

---Police: seize a gun off a slot.
---@param id integer
---@param index integer
function menus.seize(id, index)
    local v = state.get(id)
    local s = v and v.slots and v.slots[index]

    if not s then return end

    if not util.progress(T.Progress.take, locale('progress.seize', util.weaponLabel(s.name)), T.Progress.anim) then
        return
    end

    local data = ask('seize', { rackId = id, slot = index })

    if data then
        util.notify(locale('notify.seized', util.weaponLabel(data.name or s.name)), 'success')
    end
end

---The inspect panel: serial, ammo, condition, attachments, who racked it and when.
---@param id integer
---@param index integer
function menus.inspect(id, index)
    local d = ask('inspect', { rackId = id, slot = index })

    if not d then return end

    local hasAttachments = d.attachments and #d.attachments > 0
    local attachments = hasAttachments and table.concat(d.attachments, ', ') or locale('inspect.none')
    local rows = {
        {
            title = locale('inspect.serial'),
            description = d.serial or locale('menu.no_serial'),
            icon = 'barcode',
            readOnly = true,
        },
        {
            title = locale('inspect.ammo'),
            description = tostring(d.ammo or 0),
            icon = 'circle-dot',
            readOnly = true,
        },
        {
            title = locale('inspect.attachments'),
            description = attachments,
            icon = 'puzzle-piece',
            readOnly = true,
        },
        {
            title = locale('inspect.racked_by'),
            description = locale('inspect.racked_at', d.by or '?', d.when or '?'),
            icon = 'user',
            readOnly = true,
        },
    }

    if d.durability then
        table.insert(rows, 3, {
            title = locale('inspect.condition'),
            description = ('%d%%'):format(math.floor(d.durability + 0.5)),
            icon = 'wrench',
            readOnly = true,
            progress = d.durability,
        })
    end

    lib.registerContext({ id = 'sd_gunracks_inspect', title = d.label or util.weaponLabel(d.name), options = rows })
    lib.showContext('sd_gunracks_inspect')
end

---Lock or unlock a rack (owner / admin).
---@param id integer
---@param locked boolean
function menus.setLocked(id, locked)
    local data = ask('setLocked', { rackId = id, locked = locked })

    if data then
        util.notify(locale(locked and 'notify.locked' or 'notify.unlocked'), 'success')
    end
end

---Pick an empty rack back up.
---@param id integer
function menus.pickup(id)
    if not util.progress(T.Progress.pickup, locale('progress.pickup'), T.Progress.anim) then
        return
    end

    local data = ask('pickup', { rackId = id })

    if data then
        util.notify(locale('notify.picked_up'), 'success')
    end
end

---Force a locked rack: the server checks the tool and raises the alarm, then a skill check runs
---(with an animation) and its result goes back to the server.
---@param id integer
function menus.force(id)
    local start = ask('forceStart', { rackId = id })

    if not start then return end

    local anim = T.ForceAnim
    local ped = cache.ped

    if anim and anim.dict and pcall(lib.requestAnimDict, anim.dict, 5000) then
        TaskPlayAnim(ped, anim.dict, anim.clip, 3.0, 3.0, -1, 49, 0, false, false, false)
    end

    local passed = lib.skillCheck(start.difficulty or { 'easy', 'medium' }, start.inputs)

    if anim and anim.dict then
        StopAnimTask(ped, anim.dict, anim.clip, 1.0)
    end

    local res = lib.callback.await('sd-gunracks:server:forceFinish', false, { rackId = id, success = passed == true })

    if not (res and res.success) then
        return util.notify((res and res.message) or locale('err.force_failed'), 'error')
    end

    if res.data and res.data.unlocked then
        util.notify(locale('notify.forced'), 'success')
    elseif res.data and res.data.broke then
        util.notify(locale('notify.force_broke'), 'error')
    else
        util.notify(locale('notify.force_failed'), 'error')
    end
end

---The server tells the forcing player's client to raise the police alert (dispatch resources take
---alerts from the client side, with the street name worked out here).
---@param data table { coords = { x, y, z }, alert = table }
RegisterNetEvent('sd-gunracks:client:policeAlert', function(data)
    if type(data) ~= 'table' or type(data.coords) ~= 'table' then return end

    local payload = {}
    for k, v in pairs(data.alert or {}) do
        payload[k] = v
    end

    payload.coords = vector3(data.coords.x, data.coords.y, data.coords.z)
    alert.send(payload)
end)

return menus
