---@type table State module; the table returned at end of file.
local state = {}

-- The client's copy of the racks in its own routing bucket, exactly as the server described them
-- (server/racks/sync.lua sync.view): position, lock state, what this player may do there, and per
-- slot only the weapon name, attachments and tint. Nothing here is trusted by the server.
---@type table<integer, table> Rack views by id.
local racks = {}

---@type table This player's own flags: { admin, police, forceItem }.
local me = { admin = false, police = false, forceItem = false }

---Replace everything with a fresh list from the server (first load, bucket or job change).
---@param payload table { bucket, me, racks = { view... } }
---@return table<integer, boolean> previous the ids held before, so the caller can despawn the gone ones
function state.replace(payload)
    local previous = {}
    for id in pairs(racks) do
        previous[id] = true
    end

    racks = {}
    for _, view in ipairs(payload.racks or {}) do
        racks[view.id] = view
    end

    me = payload.me or me

    return previous
end

---Insert or update one rack.
---@param view table
---@return boolean isNew
function state.upsert(view)
    local isNew = racks[view.id] == nil
    racks[view.id] = view

    return isNew
end

---Forget one rack.
---@param id integer
function state.remove(id)
    racks[id] = nil
end

---One rack view, or nil.
---@param id integer
---@return table|nil
function state.get(id)
    return racks[id]
end

---Every rack view (live table; treat as read-only).
---@return table<integer, table>
function state.all()
    return racks
end

---This player's own flags.
---@return table { admin, police, forceItem }
function state.me()
    return me
end

return state
