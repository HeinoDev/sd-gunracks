-- Weapon names and metadata, read the same way on both sides. Pure: no natives. ox_inventory and
-- qb-style inventories describe a weapon differently (ox: `metadata.serial`, `metadata.components`
-- as item names; qb: `info.serie`, `info.attachments[].component` as COMPONENT_ names), so every
-- read of a stored gun's details goes through here.

---@type table Weapons module; the table returned at end of file.
local weapons = {}

---@type integer Most component strings sent to clients for one gun (a real gun carries a handful).
local MAX_COMPONENTS = 16

---A weapon name in the one spelling the fits use: UPPERCASE (qb names its weapon items lowercase).
---@param name any
---@return string|nil name or nil when not a non-empty string
function weapons.normalise(name)
    if type(name) ~= 'string' or name == '' then return nil end

    return name:upper()
end

---Is this item name a weapon at all (WEAPON_*)?
---@param name any
---@return boolean
function weapons.isWeapon(name)
    local n = weapons.normalise(name)
    return n ~= nil and n:sub(1, 7) == 'WEAPON_'
end

---Is this weapon barred from every rack (configs/shared/weapons.lua Blacklist)?
---@param name any
---@param cfg table config.Weapons
---@return boolean
function weapons.blocked(name, cfg)
    local n = weapons.normalise(name)
    return n == nil or ((cfg and cfg.Blacklist) or {})[n] == true
end

---The attachments a gun carries, as strings: ox_inventory component item names
---(`metadata.components`) or qb COMPONENT_ names (`info.attachments[].component`). Anything that
---is not a string is dropped, and the list is capped, because this goes to every client nearby.
---@param metadata table|nil the gun's inventory metadata
---@return string[] components
function weapons.components(metadata)
    local out = {}

    if type(metadata) ~= 'table' then return out end

    if type(metadata.components) == 'table' then
        for _, c in ipairs(metadata.components) do
            if type(c) == 'string' and #out < MAX_COMPONENTS then
                out[#out + 1] = c
            end
        end
    end

    if type(metadata.attachments) == 'table' then
        for _, a in ipairs(metadata.attachments) do
            local c = type(a) == 'table' and a.component or a

            if type(c) == 'string' and #out < MAX_COMPONENTS then
                out[#out + 1] = c
            end
        end
    end

    return out
end

---The readable attachment names for an inspect panel: qb carries a label per attachment; ox only
---the component item name, which the caller turns into a label through the inventory.
---@param metadata table|nil
---@param label fun(item: string): string item-label lookup
---@return string[] labels
function weapons.componentLabels(metadata, label)
    local out = {}

    if type(metadata) ~= 'table' then return out end

    if type(metadata.components) == 'table' then
        for _, c in ipairs(metadata.components) do
            if type(c) == 'string' then
                out[#out + 1] = label(c)
            end
        end
    end

    if type(metadata.attachments) == 'table' then
        for _, a in ipairs(metadata.attachments) do
            if type(a) == 'table' and (a.label or a.component) then
                out[#out + 1] = tostring(a.label or a.component)
            end
        end
    end

    return out
end

---The gun's tint index (0 = the default finish).
---@param metadata table|nil
---@return integer tint
function weapons.tint(metadata)
    local t = type(metadata) == 'table' and tonumber(metadata.tint) or nil
    return t and math.floor(t) or 0
end

---The gun's serial number, if it has one (ox: serial, qb: serie).
---@param metadata table|nil
---@return string|nil serial
function weapons.serial(metadata)
    if type(metadata) ~= 'table' then return nil end

    local s = metadata.serial or metadata.serie
    return s ~= nil and tostring(s) or nil
end

---Rounds loaded in the gun.
---@param metadata table|nil
---@return integer ammo
function weapons.ammo(metadata)
    local a = type(metadata) == 'table' and tonumber(metadata.ammo) or nil
    return a and math.floor(a) or 0
end

---What every client may know about a stored gun: just enough to draw it. The serial, ammo, owner
---and who racked it stay on the server.
---@param rec table stored slot { name, metadata, ... }
---@return table view { name, components, tint }
function weapons.publicSlot(rec)
    return {
        name = rec.name,
        components = weapons.components(rec.metadata),
        tint = weapons.tint(rec.metadata),
    }
end

---Deep copy of a plain data table (inventory metadata), so a stored gun never shares tables with
---the inventory that handed it over.
---@param v any
---@return any copy
function weapons.copy(v)
    if type(v) ~= 'table' then return v end

    local out = {}
    for k, x in pairs(v) do
        out[k] = weapons.copy(x)
    end

    return out
end

return weapons
