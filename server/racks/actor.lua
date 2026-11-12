---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Player bridge (bridge.server.player): identifier + character name.
local player = require 'bridge.server.player'
---@type table Job bridge (bridge.server.job): job name + grade.
local job = require 'bridge.server.job'
---@type table Gang bridge (bridge.server.gang): gang name + grade (qb only; nil on ESX).
local gang = require 'bridge.server.gang'

---@type table Actor module; the table returned at end of file.
local actor = {}

---@type table Staff config (config.Admin): the command and the extra ace.
local ADMIN = config.Admin or {}

---@type string The ace lib.addCommand grants the admin group for the /gunracks command
---(configs/server/admin.lua explains why it is asked about rather than `group.admin` itself).
local COMMAND_ACE = 'command.' .. (ADMIN.Command or 'gunracks')

---@type string|nil The configurable staff ace (configs/server/admin.lua Ace), when one is set.
local STAFF_ACE = (type(ADMIN.Ace) == 'string' and ADMIN.Ace ~= '') and ADMIN.Ace or nil

---Is this player staff: do they hold the configured staff ace or the command's ace?
---IsPlayerAceAllowed answers the NUMBER 1 on this platform (false when refused), so the answer is
---read for truthiness, never compared with `true`.
---@param src integer player server id
---@return boolean
function actor.isAdmin(src)
    if STAFF_ACE and IsPlayerAceAllowed(src, STAFF_ACE) then return true end

    if IsPlayerAceAllowed(src, COMMAND_ACE) then return true end

    return false
end

---May someone with this job seize from racks (configs/server/interact.lua Seize)?
---@param j table|nil { name, grade }
---@return boolean
local function isPolice(j)
    local S = config.Interact.Seize or {}

    if not S.Enabled or not j or not j.name then return false end

    local min = (S.Jobs or {})[j.name]

    return min ~= nil and (j.grade or 0) >= (tonumber(min) or 0)
end

---Everything the access rules need to know about a player, read from the bridge once per
---request: character id and name, staff ace, job, gang, and whether they may seize.
---@param src integer player server id
---@return RackActor actor
function actor.of(src)
    local jobName = job.getName(src)
    local gangName = gang.getName(src)
    local j = jobName and { name = jobName, grade = tonumber(job.getGrade(src)) or 0 } or nil
    local g = gangName and { name = gangName, grade = tonumber(gang.getGrade(src)) or 0 } or nil

    return {
        src = src,
        identifier = player.getIdentifier(src),
        name = player.getName(src),
        admin = actor.isAdmin(src),
        police = isPolice(j),
        job = j,
        gang = g,
    }
end

---A string that changes whenever anything a player's rack view depends on changes (character,
---job, gang, grade, staff), so the sync loop can tell when to resend their racks.
---@param a RackActor
---@return string signature
function actor.signature(a)
    return ('%s|%s:%s|%s:%s|%s'):format(
        tostring(a.identifier),
        a.job and a.job.name or '-', a.job and a.job.grade or 0,
        a.gang and a.gang.name or '-', a.gang and a.gang.grade or 0,
        a.admin and 'A' or '-')
end

return actor
