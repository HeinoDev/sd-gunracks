-- Who may do what at a rack. Pure: the server builds the actor from the bridge (server/racks/
-- actor.lua) and is the only side whose answer counts; the client never sees another rack's
-- access list, only the yes/no the server worked out for it.
--
-- The rules: the owner always may. A locked rack also opens to admins and to the jobs/gangs on its
-- access list (admin-placed racks, e.g. an armoury). An unlocked rack is open to anyone standing
-- at it. Only the owner or an admin may lock, unlock or pick a rack up.

---@class RackActor
---@field identifier string|nil character id (citizenid / ESX identifier)
---@field admin boolean holds the admin ace
---@field police boolean may seize (configs/server/interact.lua Seize.Jobs)
---@field job { name: string, grade: integer }|nil
---@field gang { name: string, grade: integer }|nil

---@type table Access module; the table returned at end of file.
local access = {}

---Is the actor this rack's owner? Admin-placed racks have no owner, so nobody is.
---@param rack table { owner }
---@param actor RackActor
---@return boolean
function access.isOwner(rack, actor)
    return rack.owner ~= nil and actor.identifier ~= nil and rack.owner == actor.identifier
end

---Does one of the actor's groups appear on the rack's access list at a high enough grade?
---@param list table|nil { [name] = minGrade }
---@param group table|nil { name, grade }
---@return boolean
local function grants(list, group)
    if type(list) ~= 'table' or type(group) ~= 'table' or not group.name then return false end

    local min = list[group.name]

    if min == nil then return false end

    return (tonumber(group.grade) or 0) >= (tonumber(min) or 0)
end

---Is the actor on the rack's job/gang access list?
---@param rack table { access = { jobs = {}, gangs = {} } | nil }
---@param actor RackActor
---@return boolean
function access.inGroups(rack, actor)
    local a = rack.access

    if type(a) ~= 'table' then return false end

    return grants(a.jobs, actor.job) or grants(a.gangs, actor.gang)
end

---May the actor store into / take from this rack?
---@param rack table { owner, locked, access }
---@param actor RackActor
---@return boolean allowed
---@return string|nil why 'owner' | 'admin' | 'open' | 'group'
function access.canUse(rack, actor)
    if access.isOwner(rack, actor) then return true, 'owner' end

    if actor.admin then return true, 'admin' end

    if not rack.locked then return true, 'open' end

    if access.inGroups(rack, actor) then return true, 'group' end

    return false, nil
end

---May the actor lock, unlock or pick up this rack?
---@param rack table { owner }
---@param actor RackActor
---@return boolean
function access.canManage(rack, actor)
    return access.isOwner(rack, actor) or actor.admin == true
end

---May the actor try to force this rack's lock? Only a locked rack they cannot already open, and
---only a player-owned one unless the config lets admin racks be forced too.
---@param rack table { owner, locked, access }
---@param actor RackActor
---@param cfg table|nil config.Interact.Force (server) - nil on the client, where only the lock state matters
---@return boolean
function access.canForce(rack, actor, cfg)
    if cfg and not cfg.Enabled then return false end

    if not rack.locked or access.canUse(rack, actor) then return false end

    if rack.owner == nil and not (cfg and cfg.AdminRacks) then return false end

    return true
end

return access
