-- Rack-space geometry, shared by the client (ghost, zones, drawing) and the server (placement
-- checks). Pure: no natives, so the test harness runs it as is. Rack space follows the contract
-- (docs/contract.md): metres, +Z up, the rack's front faces -Y, and a rack is only ever turned
-- about Z, by its GTA heading.

---@type table Geo module; the table returned at end of file.
local geo = {}

---Read x, y, z out of a vector or a racks.json `[x, y, z]` array alike.
---@param p table|vector3 point
---@return number x, number y, number z
local function xyz(p)
    if type(p) == 'table' and p[1] ~= nil then
        return p[1] + 0.0, (p[2] or 0) + 0.0, (p[3] or 0) + 0.0
    end

    return p.x + 0.0, p.y + 0.0, (p.z or 0) + 0.0
end

geo.xyz = xyz

---A heading folded into [0, 360).
---@param h number|nil degrees
---@return number heading
function geo.heading(h)
    return (tonumber(h) or 0.0) % 360.0
end

---Turn a rack-space point by `heading` and move it to `origin`. GTA's heading turns local +Y onto
---world (-sin h, cos h), which is the ordinary counter-clockwise rotation about Z.
---@param origin table|vector3 the rack's world origin
---@param heading number the rack's heading, degrees
---@param p table|vector3 a point in rack space
---@return number x, number y, number z world position
function geo.toWorld(origin, heading, p)
    local ox, oy, oz = xyz(origin)
    local x, y, z = xyz(p)
    local r = math.rad(heading or 0.0)
    local c, s = math.cos(r), math.sin(r)
    return ox + x * c - y * s, oy + x * s + y * c, oz + z
end

---The heading that turns a wall rack's front (local -Y) onto a wall's outward normal, so its back
---(local +Y) goes into the wall: heading = deg(atan2(nx, -ny)) (docs/contract.md).
---@param nx number wall normal x
---@param ny number wall normal y
---@return number heading degrees in [0, 360)
function geo.wallHeading(nx, ny)
    return geo.heading(math.deg(math.atan(nx, -ny)))
end

---Straight-line distance between two points.
---@param a table|vector3
---@param b table|vector3
---@return number metres
function geo.dist(a, b)
    local ax, ay, az = xyz(a)
    local bx, by, bz = xyz(b)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---A rack's footprint as an oriented box: centre, the two horizontal axes, half sizes along them
---and the z range. `def` is the rack's racks.json entry (its min/max in rack space).
---@param def table racks.json rack { min = {x,y,z}, max = {x,y,z} }
---@param origin table|vector3 the rack's world origin
---@param heading number degrees
---@return table box { cx, cy, ux, uy, vx, vy, hx, hy, z0, z1 }
function geo.box(def, origin, heading)
    local x0, y0, z0 = xyz(def.min or { -0.5, -0.5, 0.0 })
    local x1, y1, z1 = xyz(def.max or { 0.5, 0.5, 1.0 })
    local cx, cy = geo.toWorld(origin, heading, { (x0 + x1) / 2, (y0 + y1) / 2, 0.0 })
    local _, _, oz = xyz(origin)
    local r = math.rad(heading or 0.0)
    local c, s = math.cos(r), math.sin(r)
    return {
        cx = cx, cy = cy,
        ux = c, uy = s, -- local +X in world
        vx = -s, vy = c, -- local +Y in world
        hx = math.abs(x1 - x0) / 2, hy = math.abs(y1 - y0) / 2,
        z0 = oz + math.min(z0, z1), z1 = oz + math.max(z0, z1),
    }
end

---Do two rack boxes intersect? Separating-axis test on the four horizontal edge axes, then the z
---ranges. `margin` shrinks both boxes a little so racks hung edge to edge (or a gun's width apart)
---do not count as overlapping.
---@param a table geo.box
---@param b table geo.box
---@param margin? number metres, default 0.02
---@return boolean overlap
function geo.overlaps(a, b, margin)
    margin = margin or 0.02

    if a.z1 - margin <= b.z0 or b.z1 - margin <= a.z0 then return false end

    local dx, dy = b.cx - a.cx, b.cy - a.cy
    local axes = { { a.ux, a.uy }, { a.vx, a.vy }, { b.ux, b.uy }, { b.vx, b.vy } }
    for i = 1, 4 do
        local nx, ny = axes[i][1], axes[i][2]
        local d = math.abs(dx * nx + dy * ny)
        local ra = a.hx * math.abs(a.ux * nx + a.uy * ny) + a.hy * math.abs(a.vx * nx + a.vy * ny)
        local rb = b.hx * math.abs(b.ux * nx + b.uy * ny) + b.hy * math.abs(b.vx * nx + b.vy * ny)

        if d >= ra + rb - margin then return false end
    end

    return true
end

return geo
