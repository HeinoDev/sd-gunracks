---@type table Detected framework descriptor (bridge.shared.framework).
local framework = require 'bridge.shared.framework'

---@type table Player resolution helpers (bridge.server.player).
local player_mod = require 'bridge.server.player'

---@type table Tagged debug logger for this file (bridge.shared.debug).
local dprint = require('bridge.shared.debug').tag('bridge:gang')

---@type table Gang helper module returned to consumers.
local gang = {}

dprint('module load — framework: %s (gang API is QBCore-only)', tostring(framework.name))

---Returns the player's current gang name (QBCore only).
---@param source number
---@return string|nil
function gang.getName(source)
    dprint('getName: src=%s', tostring(source))
    local p = player_mod.get(source)
    if not p then
        dprint('getName: player not found for src=%s — returning nil', tostring(source))
        return nil
    end
    if framework.name == 'qb' then
        local name = p.PlayerData.gang and p.PlayerData.gang.name or nil
        dprint('getName: src=%s (QBCore) → %s', tostring(source), tostring(name))
        return name
    end
    dprint('getName: ESX has no gang — returning nil for src=%s', tostring(source))
    return nil
end

---Returns the player's current gang grade level (QBCore only).
---@param source number
---@return integer
function gang.getGrade(source)
    dprint('getGrade: src=%s', tostring(source))
    local p = player_mod.get(source)
    if not p then
        dprint('getGrade: player not found for src=%s — returning 0', tostring(source))
        return 0
    end
    if framework.name == 'qb' then
        local grade = p.PlayerData.gang and p.PlayerData.gang.grade and p.PlayerData.gang.grade.level or 0
        dprint('getGrade: src=%s (QBCore) → %d', tostring(source), grade)
        return grade
    end
    dprint('getGrade: ESX has no gang grade — returning 0 for src=%s', tostring(source))
    return 0
end

---Predicate: does the player have `gangName` at grade ≥ `minGrade`?
---@param source number
---@param gangName string
---@param minGrade? integer Default 0.
---@return boolean
function gang.has(source, gangName, minGrade)
    minGrade = minGrade or 0
    dprint('has: src=%s gangName=%s minGrade=%d', tostring(source), tostring(gangName), minGrade)
    local p = player_mod.get(source)
    if not p then
        dprint('has: player not found for src=%s — returning false', tostring(source))
        return false
    end

    if framework.name == 'qb' then
        local data = p.PlayerData.gang
        if data and data.name == gangName then
            local grade = data.grade and data.grade.level or 0
            local result = grade >= minGrade
            dprint('has: src=%s QBCore gang=%s grade=%d minGrade=%d → %s', tostring(source), tostring(data.name), grade, minGrade, tostring(result))
            return result
        end
        dprint('has: src=%s QBCore gang mismatch (current=%s wanted=%s) → false', tostring(source), tostring(data and data.name), tostring(gangName))
    else
        dprint('has: framework %s has no gang — returning false for src=%s', tostring(framework.name), tostring(source))
    end
    return false
end

---Convenience: returns true if the player matches any
---`{ name=..., minGrade=? }` entry. Empty list returns true (default-allow).
---@param source number
---@param options { name: string, minGrade?: integer }[]
---@return boolean
function gang.hasAny(source, options)
    dprint('hasAny: src=%s options count=%d', tostring(source), options and #options or 0)
    if not options or #options == 0 then
        dprint('hasAny: empty options list — default-allow → true')
        return true
    end
    for i = 1, #options do
        if gang.has(source, options[i].name, options[i].minGrade or 0) then
            dprint('hasAny: src=%s matched option[%d] name=%s → true', tostring(source), i, tostring(options[i].name))
            return true
        end
    end
    dprint('hasAny: src=%s no match found → false', tostring(source))
    return false
end

return gang
