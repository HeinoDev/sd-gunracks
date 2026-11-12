---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'
---@type table Rack fits (shared.fit): the rack's box and mount.
local fit = require 'shared.fit'
---@type table Rack-space geometry (shared.geo): wall heading, boxes, overlap.
local geo = require 'shared.geo'
---@type table Client rack mirror (client.racks.state): the racks the ghost must not overlap.
local state = require 'client.racks.state'
---@type table Client helpers (client.racks.util): native booleans, labels, notify.
local util = require 'client.racks.util'

---@type table Placer tuning and keys (config.Controls).
local P = config.Controls
---@type table Control ids and the names the strip shows (config.Controls.Keys).
local K = P.Keys
---@type table Placement rules shared with the server (config.Placement).
local PLACE = config.Placement
---@type table Ghost look (config.Draw.Ghost): alpha and the valid / invalid outline colours.
local GHOST = config.Draw.Ghost

---@type table Placement module; the table returned at end of file.
local placement = {}

-- Putting a rack down with the game's own editor gizmo, the keys in configs/client/controls.lua and
-- a strip of what they do (web/src/placer). A see-through copy of the rack starts where the player
-- looks (a wall rack flat against the wall aimed at, a floor or table-top rack on the surface under
-- the crosshair); the gizmo sits at its middle. The player keeps walking and looking about; G puts
-- the cursor out for the gizmo and takes it away again. Only the heading is kept from turning, so a
-- rack stays upright. The outline is green where the server will take it and red where it will not,
-- and Enter only places it while it is green; the server checks everything again (range, spacing,
-- overlap, limits) when it does.

---@type number Metres a step while snapping is on.
local SNAP_MOVE = tonumber(P.SnapMove) or 0.05
---@type number Degrees a step while snapping is on.
local SNAP_TURN = tonumber(P.SnapTurn) or 15.0
---@type number Metres a frame the arrow keys move it.
local NUDGE = tonumber(P.Nudge) or 0.01
---@type number Degrees a notch of the wheel turns it.
local TURN_STEP = tonumber(P.TurnStep) or 5.0
---@type number Metres ahead of the camera a placement starts.
local REACH = tonumber(P.Reach) or 8.0
---@type number Metres off its floor a rack may sit and still be on it.
local FLOAT_TOL = tonumber(P.FloatTolerance) or 0.06
---@type number Metres a wall rack's back may be off its wall and still be on it.
local WALL_TOL = tonumber(P.WallTolerance) or 0.06
---@type number Metres a wall rack is kept off the wall, so its back does not z-fight with it.
local WALL_GAP = 0.003
---@type number Degrees a wall rack may be turned off its wall's heading and still be flat on it.
local WALL_ANGLE = 8.0
---@type number Metres between the ground probes across a rack's footprint (racks are small).
local GROUND_STEP = 0.25

---@class PlacementSession
---@field model string
---@field label string
---@field def table racks.json entry
---@field mount 'floor'|'wall'|'surface'
---@field ghost integer local preview entity
---@field bounds { min: vector3, max: vector3 } the rack's box in its own space (racks.json)
---@field draft { x: number, y: number, z: number, heading: number } the origin as the gizmo leaves it (unsnapped)
---@field admin table|nil { access, locked } when staff place without an item
---@field onFinish fun(placed: boolean)|nil called once when it ends either way
---@field ui table what the keys have switched, the undo history and what the strip shows
---@field busy boolean waiting for the server's answer

---@type PlacementSession|nil The placement in progress (one at a time).
local active = nil

---@type 'move'|'rotate' The gizmo's handle mode as this resource last set it (W / R). The mode is one
---client-wide state the game keeps between placements, and +gizmoTranslation run from a script
---rather than a key press is refused, so it is remembered here instead of forced at each start.
local gizmoMode = 'move'

---@return boolean true while the ghost is up
function placement.isActive()
    return active ~= nil
end

---@param v number
---@param lo number
---@param hi number
---@return number
local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

---@param v number
---@param step number
---@return number v to the nearest step
local function snapTo(v, step)
    return math.floor(v / step + 0.5) * step
end

---@param a number degrees
---@return number a in -180..180, so a turn reads the short way round
local function wrap180(a)
    return (a + 540.0) % 360.0 - 180.0
end

---@param rot vector3 a camera's rotation, degrees (pitch x, heading z)
---@return vector3 the way it looks
local function rotToDir(rot)
    local rz, rx = math.rad(rot.z), math.rad(rot.x)
    local flat = math.abs(math.cos(rx))
    return vector3(-math.sin(rz) * flat, math.cos(rz) * flat, math.sin(rx))
end

---@param heading number degrees
---@return vector3 right (+X)
---@return vector3 forward (+Y): for a rack, its back (its front faces -Y)
local function axes(heading)
    local r = math.rad(heading)
    local c, s = math.cos(r), math.sin(r)
    return vector3(c, s, 0.0), vector3(-s, c, 0.0)
end

---@param t table { x, y, z, heading }
---@param v vector3 a point in the rack's space
---@return vector3 the point in the world
local function toWorld(t, v)
    local R, F = axes(t.heading)
    return vector3(t.x, t.y, t.z) + R * v.x + F * v.y + vector3(0.0, 0.0, v.z)
end

---The nearest thing in the world along a ray, map and props alike (a table counts): the ghost has no
---collision, and the player is left out.
---@param ro vector3
---@param rd vector3 unit direction
---@param reach number metres
---@return vector3|nil hit
---@return vector3|nil normal
local function surfaceHit(ro, rd, reach)
    local to = ro + rd * reach
    local probe = StartExpensiveSynchronousShapeTestLosProbe(ro.x, ro.y, ro.z, to.x, to.y, to.z, 1 + 16, cache.ped, 4)
    local _, hit, at, normal = GetShapeTestResult(probe)

    if not util.yes(hit) then return nil end

    return at, normal
end

---@param t table|nil a transform (the draft's by default)
---@return vector3 the middle of the footprint at its base: what it turns about and sits on the ground by
local function pivot(t)
    local b = active.bounds
    return toWorld(t or active.draft, vector3((b.min.x + b.max.x) * 0.5, (b.min.y + b.max.y) * 0.5, b.min.z))
end

---@return vector3 the middle of the box, in the rack's space: where the gizmo sits
local function centreLocal()
    local b = active.bounds
    return vector3((b.min.x + b.max.x) * 0.5, (b.min.y + b.max.y) * 0.5, (b.min.z + b.max.z) * 0.5)
end

---@param t table|nil
---@return table a copy of a transform (the draft's by default), which later changes leave alone
local function snapshot(t)
    t = t or active.draft
    return { x = t.x, y = t.y, z = t.z, heading = t.heading }
end

---Turn a transform about its footprint's middle rather than its origin, so it spins in place.
---@param t table changed in place
---@param degrees number
local function turnAround(t, degrees)
    local before = pivot(t)

    t.heading = (t.heading + degrees) % 360.0

    local after = pivot(t)

    t.x, t.y = t.x + (before.x - after.x), t.y + (before.y - after.y)
end

---What is shown and placed: the draft, or with snapping on the draft on the grid. A floor rack turns
---in steps with its footprint's middle on a world grid; a wall rack keeps its wall's heading and its
---depth, and steps only up the wall and along it. The gizmo keeps working on the draft, so small
---drags add up.
---@return table transform
local function placed()
    local s = active

    if not s.ui.snap then
        return snapshot()
    end

    local t = snapshot()

    if s.mount == 'wall' then
        local R = axes(t.heading)
        local piv = pivot(t)
        local along = piv.x * R.x + piv.y * R.y
        local d = snapTo(along, SNAP_MOVE) - along
        t.x, t.y, t.z = t.x + R.x * d, t.y + R.y * d, snapTo(t.z, SNAP_MOVE)

        return t
    end

    turnAround(t, snapTo(t.heading, SNAP_TURN) - t.heading)

    local piv = pivot(t)

    t.x, t.y = t.x + (snapTo(piv.x, SNAP_MOVE) - piv.x), t.y + (snapTo(piv.y, SNAP_MOVE) - piv.y)

    return t
end

---@param t table where to show the ghost
local function apply(t)
    SetEntityCoordsNoOffset(active.ghost, t.x, t.y, t.z, false, false, false)
    SetEntityRotation(active.ghost, 0.0, 0.0, t.heading, 2, true)
end

---Keep the transform as it is before a change, for Ctrl+Z.
local function remember()
    local ui = active.ui
    local last = ui.history[#ui.history]
    local now = snapshot()

    if last and last.x == now.x and last.y == now.y and last.z == now.z and last.heading == now.heading then
        return
    end

    ui.history[#ui.history + 1] = now

    if #ui.history > 60 then
        table.remove(ui.history, 1)
    end

    ui.future = {}
end

---@param t table a transform kept for undo, redo or a drag let go of
local function restore(t)
    local d = active.draft
    d.x, d.y, d.z, d.heading = t.x, t.y, t.z, t.heading
end

---@param t table
---@return string key what a cached look at the world was taken for
local function keyOf(t)
    return ('%.3f:%.3f:%.3f:%.2f'):format(t.x, t.y, t.z, t.heading)
end


-- ---- the floor -----------------------------------------------------------------------------------

---The surface under a point, looked for from just above it: a ray straight down (so a table top is
---found as well as the floor), then the game's ground height when the ray finds nothing.
---@param x number
---@param y number
---@param fromZ number
---@return number|nil z
---@return number nz the surface's normal z (1.0 when only the ground height was found)
local function groundAt(x, y, fromZ)
    local hit, n = surfaceHit(vector3(x, y, fromZ), vector3(0.0, 0.0, -1.0), 6.0)

    if hit then return hit.z, n.z end

    local found, z = GetGroundZFor_3dCoord(x, y, fromZ, false)

    if util.yes(found) then return z, 1.0 end

    return nil, 0.0
end

---The highest and lowest surface under the whole footprint, and the steepest of it, probed on a grid
---corners and all, from a little above the rack's base. Kept while the transform is unchanged.
---@param t table
---@return number|nil top
---@return number|nil low
---@return number flattest normal z found under it, the least of them
local function footprintGround(t)
    local s = active
    local key = keyOf(t)
    local g = s.ui.ground

    if g and g.key == key then return g.top, g.low, g.nz end

    local mn, mx = s.bounds.min, s.bounds.max
    local cols = clamp(math.ceil((mx.x - mn.x) / GROUND_STEP), 1, 6)
    local rows = clamp(math.ceil((mx.y - mn.y) / GROUND_STEP), 1, 4)
    local from = pivot(t).z + 0.75
    local top, low, nz = nil, nil, 1.0

    for i = 0, cols do
        for j = 0, rows do
            local p = toWorld(t, vector3(mn.x + (mx.x - mn.x) * i / cols, mn.y + (mx.y - mn.y) * j / rows, mn.z))
            local z, n = groundAt(p.x, p.y, from)

            if z then
                top = top and math.max(top, z) or z
                low = low and math.min(low, z) or z
                nz = math.min(nz, n)
            end
        end
    end

    s.ui.ground = { key = key, top = top, low = low, nz = nz }

    return top, low, nz
end

---Sit the base on the highest surface under the footprint, so nothing of it is buried.
---@return boolean dropped false when there is nothing under it
local function dropToGround()
    local top = footprintGround(active.draft)

    if not top then return false end

    active.draft.z = top - active.bounds.min.z

    return true
end


-- ---- the wall ------------------------------------------------------------------------------------

---Look straight back from in front of a wall rack (along its local +Y, into the wall) at one point
---across its width, at half its height. The probe starts a little in front of the back plane, and
---further out when that finds nothing (the rack pushed into the wall).
---@param t table
---@param lx number local x of the probe
---@return vector3|nil hit
---@return vector3|nil normal
---@return number|nil gap metres from the back plane (local y = 0) to the wall: + behind it, - in front
local function wallProbe(t, lx)
    local b = active.bounds
    local mid = (b.min.z + b.max.z) * 0.5
    local _, F = axes(t.heading)

    for _, out in ipairs({ 0.35, 1.2 }) do
        local from = toWorld(t, vector3(lx, -out, mid))
        local hit, n = surfaceHit(from, F, out + 0.85)

        if hit then
            return hit, n, #(hit - from) - out
        end
    end

    return nil
end

---Flatten a wall rack onto the wall behind it: its heading from the wall's normal, its back on the
---wall, its height and place along the wall kept.
---@param t table changed in place
---@return boolean flushed false when no wall was found behind it
local function flushToWall(t)
    local b = active.bounds
    local cx = (b.min.x + b.max.x) * 0.5
    local hit, n = wallProbe(t, cx)

    if not hit or math.abs(n.z) > (PLACE.WallNormalZ or 0.3) then return false end

    local mid = (b.min.z + b.max.z) * 0.5

    t.heading = geo.wallHeading(n.x, n.y)

    local R = axes(t.heading)

    -- The probe ran down the rack's centre line, which sits cx along from its origin.
    t.x = hit.x + n.x * WALL_GAP - R.x * cx
    t.y = hit.y + n.y * WALL_GAP - R.y * cx
    t.z = hit.z - mid

    return true
end

---Does the probe at local x `lx` find a wall within WALL_TOL of the rack's back, upright enough
---and turned the way the rack is?
---@param t table
---@param lx number
---@return boolean
local function wallBehind(t, lx)
    local hit, n, gap = wallProbe(t, lx)

    if not hit or math.abs(gap) > WALL_TOL then return false end

    if math.abs(n.z) > (PLACE.WallNormalZ or 0.3) then return false end

    return math.abs(wrap180(geo.wallHeading(n.x, n.y) - t.heading)) <= WALL_ANGLE
end

---Is a wall rack flat on a wall all the way across: three probes (both ends and the middle) each find
---a wall within WALL_TOL of its back, upright enough, and turned the way the rack is. Kept while the
---transform is unchanged.
---@param t table
---@return boolean flat
local function onWall(t)
    local s = active
    local key = keyOf(t)
    local w = s.ui.wall

    if w and w.key == key then return w.flat end

    local b = s.bounds
    local inset = math.min(0.05, (b.max.x - b.min.x) * 0.25)
    local flat = true

    for _, lx in ipairs({ b.min.x + inset, (b.min.x + b.max.x) * 0.5, b.max.x - inset }) do
        if not wallBehind(t, lx) then
            flat = false
            break
        end
    end

    s.ui.wall = { key = key, flat = flat }

    return flat
end

---Put the rack back on its surface (the Surface key, and every move while Stick is on): a wall rack
---flat onto the wall behind it, a floor or table-top rack down onto what is under it.
---@return boolean done
local function toSurface()
    if active.mount == 'wall' then
        return flushToWall(active.draft)
    end

    return dropToGround()
end


-- ---- may it go here ------------------------------------------------------------------------------

---Does a rack at this pose overlap one already in the world (the server's rule, on the client's
---copy of the racks)?
---@param t table
---@return boolean overlap
local function overlapsAny(t)
    local coords = vector3(t.x, t.y, t.z)
    local box = geo.box(active.def, coords, t.heading)

    for _, v in pairs(state.all()) do
        local pos = vector3(v.x, v.y, v.z)

        if geo.dist(coords, pos) < (PLACE.MinDistance or 0.3) then return true end

        local other = fit.rack(v.model)

        if other and geo.overlaps(box, geo.box(other, pos, v.heading)) then return true end
    end

    return false
end

---Everything wrong with where the rack is, as { key, text } for the strip; empty when it may go
---here. Range and overlap are the server's own rules; the surface checks are the client's (the
---server cannot see walls).
---@param t table
---@return { key: string, text: string }[]
local function problems(t)
    local s = active
    local out = {}

    local function add(key, ...)
        out[#out + 1] = { key = key, text = locale('placement.' .. key, ...) }
    end

    if geo.dist(GetEntityCoords(cache.ped), vector3(t.x, t.y, t.z)) > (PLACE.Range or 4.0) then
        add('too_far')
    end

    if s.mount == 'wall' then
        if not onWall(t) then
            add('need_wall', K.Surface[2])
        end
    else
        local top, _, nz = footprintGround(t)
        local base = t.z + s.bounds.min.z

        if not top then
            add('no_surface')
        elseif base - top > FLOAT_TOL then
            add('floating', ('%.2f'):format(base - top), K.Surface[2])
        elseif top - base > FLOAT_TOL then
            add('sunk', K.Surface[2])
        elseif nz < (PLACE.FloorNormalZ or 0.7) then
            add(s.mount == 'surface' and 'need_surface' or 'need_floor')
        end
    end

    if overlapsAny(t) then
        add('overlap')
    end

    return out
end


-- ---- the gizmo -----------------------------------------------------------------------------------

---@type string The layout DrawGizmo reads its matrix in.
local MATRIX = '<ffffffffffffffff'

---@return string matrix the gizmo's, at the middle of the rack: right, forward, up, position
local function gizmoMatrix()
    local d = active.draft
    local R, F = axes(d.heading)
    local c = toWorld(d, centreLocal())
    local buf = string.blob(64)

    return buf:blob_pack(1, MATRIX,
        R.x, R.y, R.z, 0.0,
        F.x, F.y, F.z, 0.0,
        0.0, 0.0, 1.0, 0.0,
        c.x, c.y, c.z, 1.0)
end

---Run the gizmo this frame and fold what it changed back into the draft: where it is and its heading
---only. The rings' pitch and roll are let go, so the rack stays upright.
---@return boolean changed
local function gizmoFrame()
    local s = active
    local d = s.draft
    local buf = gizmoMatrix()
    local changed = Citizen.InvokeNative(0xEB2EDCA2, buf, 'sd_gunracks_placer', Citizen.ReturnResultAnyway())

    if not changed then return false end

    local m = { buf:blob_unpack(1, MATRIX) }
    local fx, fy = m[5], m[6]
    local heading = d.heading

    if math.abs(fx) + math.abs(fy) > 1e-4 then
        heading = math.deg(math.atan(-fx, fy)) % 360.0
    end

    local before = snapshot()
    local cl = centreLocal()
    local R, F = axes(heading)
    local off = R * cl.x + F * cl.y

    d.heading = heading
    d.x, d.y, d.z = m[13] - off.x, m[14] - off.y, m[15] - cl.z

    -- A floor rack dragged straight up or down is meant to be off the floor: it stops sticking to it.
    -- (A wall rack goes up and down its wall, which Stick keeps it on.)
    if s.mount ~= 'wall' then
        local dz = d.z - before.z

        if math.abs(dz) > 1e-4 and math.abs(d.x - before.x) + math.abs(d.y - before.y) < 1e-4 then
            s.ui.stick = false
        end
    end

    return true
end

---The cursor out for the gizmo, or away. Enter/LeaveCursorMode share one counter with every other
---resource on the client, so this only ever undoes what it did itself (`shown`).
---@param on boolean
local function setCursor(on)
    local ui = active.ui
    local shown = ui.cursor and not ui.looking -- (looking about: the cursor is on, but out of the way)

    ui.cursor, ui.looking = on, false

    if on == shown then return end

    if on then
        EnterCursorMode()
    else
        LeaveCursorMode()
    end
end

---The right button held looks about: the cursor goes while it is held and comes back when it is let go.
---@param held boolean
local function lookAround(held)
    local ui = active.ui

    if held == (ui.looking == true) or not ui.cursor or ui.drag then return end

    ui.looking = held

    if held then
        LeaveCursorMode()
    else
        EnterCursorMode()
    end
end


-- ---- drawing -------------------------------------------------------------------------------------

---@param key table a Keys entry { control, name }
---@return boolean pressed this frame (the control is held off, so it is read as disabled)
local function pressed(key)
    return util.yes(IsDisabledControlJustPressed(0, key[1]))
end

---@param a vector3
---@param b vector3
---@param c integer[]
---@param alpha integer|nil
local function line(a, b, c, alpha)
    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, c[1], c[2], c[3], alpha or 255)
end

---A triangle drawn from both sides, so it shows from above and below.
local function tri(a, b, c, col, alpha)
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, col[1], col[2], col[3], alpha)
    DrawPoly(c.x, c.y, c.z, b.x, b.y, b.z, a.x, a.y, a.z, col[1], col[2], col[3], alpha)
end

local function quad(a, b, c, d, col, alpha)
    tri(a, b, c, col, alpha)
    tri(a, c, d, col, alpha)
end

---A dashed line, dashes and gaps the same length.
local function dashed(a, b, dash, col, alpha)
    local len = #(b - a)

    if len < 1e-3 then return end

    local d = (b - a) / len
    local t = 0.0

    while t < len do
        line(a + d * t, a + d * math.min(len, t + dash), col, alpha)
        t = t + dash * 2
    end
end

---A faint box round the rack in its outline colour, a chevron out from its front, and for a floor
---rack its footprint shaded on the floor and a dashed drop line while it floats.
---@param t table
---@param valid boolean
local function drawAssembly(t, valid)
    local s = active
    local col = valid and GHOST.Valid or GHOST.Invalid
    local mn, mx = s.bounds.min, s.bounds.max
    local corners = {
        vector3(mn.x, mn.y, mn.z),
        vector3(mx.x, mn.y, mn.z),
        vector3(mx.x, mx.y, mn.z),
        vector3(mn.x, mx.y, mn.z),
        vector3(mn.x, mn.y, mx.z),
        vector3(mx.x, mn.y, mx.z),
        vector3(mx.x, mx.y, mx.z),
        vector3(mn.x, mx.y, mx.z),
    }
    local c = {}

    for i, v in ipairs(corners) do
        c[i] = toWorld(t, v)
    end

    -- The bottom face, the top face, then the four uprights.
    local edges = {
        { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
        { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
        { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
    }
    local edgeAlpha = valid and 90 or 170

    for _, e in ipairs(edges) do
        line(c[e[1]], c[e[2]], col, edgeAlpha)
    end

    local R, F = axes(t.heading)
    local lift = vector3(0.0, 0.0, 0.01)

    if s.mount ~= 'wall' then
        local piv = pivot(t)
        local top = footprintGround(t)

        if top then
            lift = vector3(0.0, 0.0, top - piv.z + 0.01)
            quad(c[1] + lift, c[2] + lift, c[3] + lift, c[4] + lift, col, 45)

            if piv.z - top > FLOAT_TOL then
                dashed(piv, vector3(piv.x, piv.y, top + 0.01), 0.06, col, 220)
            end
        end
    end

    -- The front faces -Y: the chevron points out of it, so the way the rack faces is never a guess.
    local front = toWorld(t, vector3((mn.x + mx.x) * 0.5, mn.y, mn.z)) - F * 0.08 + lift
    local w = clamp((mx.x - mn.x) * 0.12, 0.06, 0.18)
    tri(front - F * w, front + R * w * 0.8, front - R * w * 0.8, col, 170)
end


-- ---- the strip -----------------------------------------------------------------------------------

---@param data table what the strip shows, or { active = false } to take it down
local function hud(data)
    SendNUIMessage({ action = 'sd-gunracks:placer:hud', data = data })
end

---@type table The key names the strip shows (configs/client/controls.lua).
local KEY_NAMES = {
    cursor = K.Cursor[2],
    snap = K.Snap[2],
    stick = K.Stick[2],
    surface = K.Surface[2],
    undo = K.Undo[2],
    confirm = K.Confirm[2],
    cancel = K.Cancel[2],
    move = (P.Gizmo or {}).Move or 'W',
    rotate = (P.Gizmo or {}).Rotate or 'R',
    axes = (P.Gizmo or {}).Axes or 'Q',
}

---@type integer
local lastHud = 0

---Send the strip (twenty times a second), with what a drag has done so far while one is under way.
---@param t table
local function pushHud(t)
    local now = GetGameTimer()

    if now - lastHud < 50 then return end

    lastHud = now

    local s = active
    local ui = s.ui
    local d = ui.drag
    local readout, handle

    if d and d.changed then
        local turned = wrap180(t.heading - d.start.heading)

        if math.abs(turned) > 0.05 then
            handle, readout = 'rotate', ('%+.1f°'):format(turned)
        else
            local a, b = pivot(d.start), pivot(t)
            handle, readout = 'move', ('%.2f m'):format(#(b - a))
        end
    end

    hud({
        active = true,
        label = s.label,
        mount = s.mount,
        x = t.x,
        y = t.y,
        z = t.z,
        heading = t.heading,
        mode = ui.mode,
        space = ui.space,
        snap = ui.snap,
        stick = ui.stick,
        cursor = ui.cursor and not ui.looking,
        handle = handle,
        dragging = readout ~= nil,
        readout = readout,
        valid = #ui.problems == 0,
        warnings = ui.problems,
        snapMove = SNAP_MOVE,
        snapTurn = SNAP_TURN,
        keys = KEY_NAMES,
    })
end


-- ---- the session ---------------------------------------------------------------------------------

---End the placement: the ghost goes, the strip comes down, the cursor is handed back, and whoever
---started it is told. Safe to call twice.
---@param placedIt boolean the server took it
---@param notifyServer boolean tell the server a player's placement was abandoned (frees their session)
local function finish(placedIt, notifyServer)
    local s = active

    if not s then return end

    setCursor(false)
    active = nil

    if s.ghost and util.yes(DoesEntityExist(s.ghost)) then
        DeleteEntity(s.ghost)
    end

    SetModelAsNoLongerNeeded(joaat(s.model))
    hud({ active = false })

    if notifyServer and not s.admin then
        TriggerServerEvent('sd-gunracks:server:cancelPlacement')
    end

    if s.onFinish then
        local ok, err = pcall(s.onFinish, placedIt)

        if not ok then
            log.error('placement', 'onFinish failed: %s', tostring(err))
        end
    end
end

---Give up the current placement (a used rack item never left the inventory).
---@param quiet? boolean skip the "cancelled" notification (resource stop)
function placement.cancel(quiet)
    if not active then return end

    finish(false, true)

    if not quiet then
        util.notify(locale('placement.cancelled'))
    end
end

---Send the pose to the server; the rack appears through the normal sync when it is accepted.
---Placement ends either way: a refusal is explained and a rack item stays in the inventory.
---@param s PlacementSession
---@param t table the pose shown (snapped) when Enter was pressed
local function confirm(s, t)
    local payload = { coords = { x = t.x, y = t.y, z = t.z }, heading = t.heading }
    local res

    if s.admin then
        payload.model = s.model
        payload.access = s.admin.access
        payload.locked = s.admin.locked
        res = lib.callback.await('sd-gunracks:server:adminPlace', false, payload)
    else
        res = lib.callback.await('sd-gunracks:server:place', false, payload)
    end

    if active ~= s then return end

    local ok = res and res.success == true

    finish(ok, false)

    if ok then
        util.notify(locale('placement.placed', s.label), 'success')
    else
        util.notify((res and res.message) or locale('err.save_failed'), 'error')
    end
end

---Every frame while placing: hold off the controls, then snap, stick, the surface key, undo and redo,
---the arrow nudges, the gizmo, the ghost, its outline and the strip, and Enter or Backspace.
---@param s PlacementSession
local function loop(s)
    local held = {}

    while active == s do
        local ui = s.ui
        local d = s.draft
        local dt = GetFrameTime()

        for _, c in ipairs(P.Disable) do
            DisableControlAction(0, c, true)
        end

        DisablePlayerFiring(cache.playerId, true)

        local ped = cache.ped

        if util.yes(IsEntityDead(ped)) or util.yes(IsPedInAnyVehicle(ped, false)) then
            placement.cancel()
            return
        end

        local shift = util.yes(IsControlPressed(0, K.Shift[1]))
        local ctrl = util.yes(IsDisabledControlPressed(0, K.Ctrl[1]))

        if not s.busy then
            if pressed(K.Cursor) and not ui.drag then
                setCursor(not ui.cursor)
            end

            if pressed(K.Snap) then
                ui.snap = not ui.snap
            end

            if pressed(K.Stick) then
                ui.stick = not ui.stick

                if ui.stick then
                    remember()
                    toSurface()
                end
            end

            if pressed(K.Surface) then
                remember()

                if not toSurface() then
                    local key = s.mount == 'wall' and 'placement.no_wall_behind' or 'placement.no_surface'

                    util.notify(locale(key), 'error')
                end
            end

            if not ui.drag and ctrl and pressed(K.Undo) and #ui.history > 0 then
                ui.future[#ui.future + 1] = snapshot()
                restore(table.remove(ui.history))
            elseif not ui.drag and ctrl and pressed(K.Redo) and #ui.future > 0 then
                ui.history[#ui.history + 1] = snapshot()
                restore(table.remove(ui.future))
            end

            -- The arrows: a floor rack moves along its own axes; a wall rack goes up and down its
            -- wall and along it, never into it.
            local R, F = axes(d.heading)
            local step = NUDGE * (shift and 5.0 or 1.0) * math.max(1.0, dt * 60.0)
            local up = vector3(0.0, 0.0, step)
            local wall = s.mount == 'wall'
            local moves = {
                { K.Up, wall and up or F * step },
                { K.Down, wall and up * -1.0 or F * -step },
                { K.Right, R * step },
                { K.Left, R * -step },
                { K.PageUp, up },
                { K.PageDown, up * -1.0 },
            }

            for _, m in ipairs(moves) do
                if util.yes(IsDisabledControlPressed(0, m[1])) then
                    if not held[m[1]] then
                        remember()
                        held[m[1]] = true
                    end

                    d.x, d.y, d.z = d.x + m[2].x, d.y + m[2].y, d.z + m[2].z

                    if not wall and (m[1] == K.PageUp or m[1] == K.PageDown) then
                        ui.stick = false
                    elseif ui.stick then
                        toSurface()
                    end
                else
                    held[m[1]] = nil
                end
            end

            if gizmoFrame() then
                if ui.drag then
                    ui.drag.changed = true
                end

                if ui.stick then
                    toSurface()
                end
            end
        end

        local t = placed()

        apply(t)
        ui.problems = problems(t)

        local valid = #ui.problems == 0
        local col = valid and GHOST.Valid or GHOST.Invalid

        SetEntityDrawOutlineColor(col[1], col[2], col[3], col[4])
        drawAssembly(t, valid)
        pushHud(t)

        if not s.busy then
            local cancel = pressed(K.Cancel)
                or util.yes(IsDisabledControlJustPressed(0, 200))
                or util.yes(IsDisabledControlJustPressed(0, 322))

            if not ui.drag and valid and pressed(K.Confirm) then
                s.busy = true -- set here, not in confirm: the thread only starts next tick
                CreateThread(function() confirm(s, t) end)
            elseif cancel then
                if ui.drag then
                    -- Backspace in the middle of a drag puts it back where the drag began, and goes on.
                    restore(ui.drag.start)
                    ui.drag.start = snapshot()
                    ui.drag.changed = false
                else
                    placement.cancel()
                    return
                end
            end
        end

        Wait(0)
    end
end

-- The gizmo's inputs are key mappings (Settings > Key Bindings > FiveM), because the game's gizmo
-- hears only its +gizmo* commands. The wheel and the right button are key mappings too: with the
-- cursor out the game swallows the wheel before any control sees it, and the gizmo is only any use
-- with the cursor out.

lib.addKeybind({
    name = 'sd_gunracks_gizmo_select',
    description = locale('placement.key_select'),
    defaultMapper = 'MOUSE_BUTTON',
    defaultKey = 'MOUSE_LEFT',
    onPressed = function()
        if not active or active.busy then return end

        remember()
        active.ui.drag = { start = snapshot(), changed = false }
        ExecuteCommand('+gizmoSelect')
    end,
    onReleased = function()
        ExecuteCommand('-gizmoSelect')

        if not active then return end

        local ui = active.ui

        -- A click that moved nothing leaves no undo step behind.
        if ui.drag and not ui.drag.changed and #ui.history > 0 then
            table.remove(ui.history)
        end

        ui.drag = nil
    end,
})

lib.addKeybind({
    name = 'sd_gunracks_gizmo_move',
    description = locale('placement.key_move'),
    defaultKey = (P.Gizmo or {}).Move or 'W',
    onPressed = function()
        if not active then return end

        gizmoMode = 'move'
        active.ui.mode = gizmoMode
        ExecuteCommand('+gizmoTranslation')
    end,
    onReleased = function() ExecuteCommand('-gizmoTranslation') end,
})

lib.addKeybind({
    name = 'sd_gunracks_gizmo_rotate',
    description = locale('placement.key_rotate'),
    defaultKey = (P.Gizmo or {}).Rotate or 'R',
    onPressed = function()
        if not active then return end

        gizmoMode = 'rotate'
        active.ui.mode = gizmoMode
        ExecuteCommand('+gizmoRotation')
    end,
    onReleased = function() ExecuteCommand('-gizmoRotation') end,
})

---Turn the rack a step. Shift 15 degrees, Ctrl 1, snapping on the snap angle. A wall rack stuck to
---its wall keeps the wall's heading, so the wheel leaves it be.
---@param dir integer 1 or -1
local function wheelTurn(dir)
    if not active or active.busy or active.ui.drag then return end

    if active.mount == 'wall' and active.ui.stick then return end

    remember()

    local step = TURN_STEP

    if active.ui.snap then
        step = SNAP_TURN
    elseif util.yes(IsDisabledControlPressed(0, K.Ctrl[1])) then
        step = 1.0
    elseif util.yes(IsControlPressed(0, K.Shift[1])) then
        step = 15.0
    end

    turnAround(active.draft, dir * step)
end

lib.addKeybind({
    name = 'sd_gunracks_gizmo_turn_left',
    description = locale('placement.key_turn_left'),
    defaultMapper = 'MOUSE_WHEEL',
    defaultKey = 'IOM_WHEEL_UP',
    onPressed = function() wheelTurn(1) end,
})

lib.addKeybind({
    name = 'sd_gunracks_gizmo_turn_right',
    description = locale('placement.key_turn_right'),
    defaultMapper = 'MOUSE_WHEEL',
    defaultKey = 'IOM_WHEEL_DOWN',
    onPressed = function() wheelTurn(-1) end,
})

lib.addKeybind({
    name = 'sd_gunracks_gizmo_look',
    description = locale('placement.key_look'),
    defaultMapper = 'MOUSE_BUTTON',
    defaultKey = 'MOUSE_RIGHT',
    onPressed = function()
        if active then
            lookAround(true)
        end
    end,
    onReleased = function()
        if active then
            lookAround(false)
        end
    end,
})

lib.addKeybind({
    name = 'sd_gunracks_gizmo_space',
    description = locale('placement.key_axes'),
    defaultKey = (P.Gizmo or {}).Axes or 'Q',
    onPressed = function()
        if not active then return end

        active.ui.space = active.ui.space == 'local' and 'world' or 'local'
        ExecuteCommand('+gizmoLocal')
    end,
    onReleased = function() ExecuteCommand('-gizmoLocal') end,
})

---@param at vector3 where it goes
---@param pc vector3 the player
---@return number heading that turns the rack's front (-Y) to the player
local function headingToFace(at, pc)
    local dx, dy = pc.x - at.x, pc.y - at.y

    if math.abs(dx) < 0.001 and math.abs(dy) < 0.001 then return 0.0 end

    return math.deg(math.atan(dx, -dy)) % 360.0
end

---Where a new placement starts: where the camera looks. A wall rack aimed at a wall goes flat on it,
---centred on the crosshair; a floor or table-top rack goes on the surface there, facing the player.
---@param s PlacementSession
local function startPose(s)
    local ro = GetFinalRenderedCamCoord()
    local rd = rotToDir(GetFinalRenderedCamRot(2))
    local hit, n = surfaceHit(ro, rd, REACH)
    local pc = GetEntityCoords(cache.ped)
    local at = hit or (ro + rd * math.min(REACH, 3.0))
    local b = s.bounds

    if s.mount == 'wall' and hit and math.abs(n.z) <= (PLACE.WallNormalZ or 0.3) then
        s.draft = { x = 0.0, y = 0.0, z = 0.0, heading = geo.wallHeading(n.x, n.y) }

        local R = axes(s.draft.heading)
        local cx = (b.min.x + b.max.x) * 0.5

        s.draft.x = at.x + n.x * WALL_GAP - R.x * cx
        s.draft.y = at.y + n.y * WALL_GAP - R.y * cx
        s.draft.z = at.z - (b.min.z + b.max.z) * 0.5

        return
    end

    s.draft = { x = at.x, y = at.y, z = at.z, heading = headingToFace(at, pc) }

    if s.mount == 'wall' then
        -- Not aimed at a wall: held up where the camera looks, red until Alt puts it on one.
        s.draft.z = at.z + 0.5
        return
    end

    -- The middle of the footprint goes where the camera looks, not the rack's origin.
    local piv = pivot()

    s.draft.x, s.draft.y = s.draft.x + (at.x - piv.x), s.draft.y + (at.y - piv.y)
    dropToGround()
end

---Enter placement mode for one rack model: a see-through, collision-less ghost where the player
---looks, then the gizmo. `opts.admin` (staff, no item) confirms through the admin callback instead;
---`opts.onFinish(placed)` is called once when it ends, placed or not.
---@param model string
---@param opts? { admin?: { access?: table, locked?: boolean }, onFinish?: fun(placed: boolean) }
---@return boolean started
function placement.start(model, opts)
    opts = opts or {}

    local function refuse(key)
        util.notify(locale(key), 'error')

        if opts.onFinish then
            pcall(opts.onFinish, false)
        end

        return false
    end

    if active then
        return refuse('placement.already')
    end

    local def = fit.rack(model)

    if not def then
        return refuse('err.bad_model')
    end

    local hash = joaat(model)

    if not pcall(lib.requestModel, hash, config.Draw.LoadTimeout or 10000) then
        log.error('placement', 'model %s did not load', model)
        return refuse('err.bad_model')
    end

    local mn, mx = def.min or { -0.5, -0.2, 0.0 }, def.max or { 0.5, 0.2, 1.0 }
    local s = {
        model = model,
        label = util.rackLabel(model),
        def = def,
        mount = def.mount or 'floor',
        bounds = { min = vector3(mn[1], mn[2], mn[3]), max = vector3(mx[1], mx[2], mx[3]) },
        admin = opts.admin,
        onFinish = opts.onFinish,
        busy = false,
        ui = {
            mode = gizmoMode,
            space = 'world',
            snap = false,
            stick = true,
            cursor = false,
            looking = false,
            drag = nil,
            history = {},
            future = {},
            problems = {},
        },
    }

    active = s
    startPose(s)

    local d = s.draft
    local ghost = CreateObjectNoOffset(hash, d.x, d.y, d.z, false, false, false)

    if not ghost or ghost == 0 or not util.yes(DoesEntityExist(ghost)) then
        active = nil
        SetModelAsNoLongerNeeded(hash)
        return refuse('err.bad_model')
    end

    s.ghost = ghost

    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    SetEntityInvincible(ghost, true)
    SetEntityCanBeDamaged(ghost, false)
    SetEntityAlpha(ghost, GHOST.Alpha or 170, false)
    SetEntityDrawOutline(ghost, true)
    SetEntityDrawOutlineShader(1)
    apply(d)

    CreateThread(function()
        -- A few frames first: whatever NUI had the mouse (the inventory the item was used from, the
        -- console) has to have let it go, or the cursor this asks for comes up hidden.
        Wait(150)

        if active ~= s then return end

        setCursor(true)
        loop(s)
    end)

    return true
end

---The server accepted a rack item use: open placement for its model.
---@param data table { model, item }
RegisterNetEvent('sd-gunracks:client:startPlacement', function(data)
    if type(data) ~= 'table' or type(data.model) ~= 'string' then return end

    placement.start(data.model)
end)

return placement
