---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Weapon names and metadata helpers (shared.weapons).
local weapons = require 'shared.weapons'

-- Where a gun sits in a rack's slot. The numbers come from data/racks.json, which tools/props/build.py writes: every
-- vanilla firearm was fitted into every kind of slot against its real mesh and checked against the rack's own
-- geometry, so a vanilla gun is placed exactly. An addon gun (configs/shared/weapons.lua Extra) has no measured fit:
-- it is placed from its model's bounding box with the same rules (tools/props/weapons/fits.py), using the medians the
-- real guns gave for that kind of slot (racks.json kinds[*].fallback). Pure apart from LoadResourceFile.
--
-- Frames: a rack's own space is metres, +Z up, its front -Y. A slot's frame is `pos` + `yaw` degrees about Z in it.
-- A fit row is [px, py, pz, pitch, roll, yaw] of the weapon object in the slot's frame, rotation order 2 (the game's:
-- R = Rz(yaw) Rx(pitch) Ry(roll)). Because a slot only turns about Z, a fit's rotation in the rack's space is the
-- same pitch and roll with the slot's yaw added.

---@type table Fit module; the table returned at end of file.
local fit = {}

---@type table|nil racks.json `racks`, decoded once.
local racks

---@return table racks keyed by model name
function fit.racks()
    if not racks then
        local data = lib.loadJson('data.racks')
        racks = data and data.racks or {}
    end

    return racks
end

---@param model string rack model name
---@return table|nil rack the rack's data (label, mount, min, max, slots, kinds, fits)
function fit.rack(model)
    return fit.racks()[model]
end

---The slot and its kind.
---@param model string
---@param slot integer 1-based slot index
---@return table|nil slot, table|nil kind
local function slotOf(model, slot)
    local r = fit.rack(model)
    local s = r and r.slots[slot]

    if not s then return nil, nil end

    return s, r.kinds[s.kind]
end

---May this weapon go in this slot? A measured fit, or an addon gun whose configured group the slot's kind takes;
---never a blacklisted one.
---@param model string rack model
---@param slot integer 1-based slot index
---@param weapon string weapon item name (any case)
---@return boolean
function fit.accepts(model, slot, weapon)
    local name = weapons.normalise(weapon)

    if not name or weapons.blocked(name, config.Weapons) then return false end

    local s, kind = slotOf(model, slot)
    local r = fit.rack(model)

    if not s or not kind or not r then return false end

    if r.fits[s.kind] and r.fits[s.kind][name] then return true end

    local group = (config.Weapons.Extra or {})[name]

    if not group then return false end

    for _, g in ipairs(kind.groups or {}) do
        if g == group then return true end
    end

    return false
end

-- ---- small 3x3 maths (rows of columns: m[r][c]) ------------------------------------------------------------------
local rad, deg, sin, cos, asin, atan = math.rad, math.deg, math.sin, math.cos, math.asin, math.atan

---@return number[][] the rotation whose columns are the gun's X, Y, Z axes given its X and (unnormalised) Z
local function basis(x, z)
    local lx = math.sqrt(x[1] ^ 2 + x[2] ^ 2 + x[3] ^ 2)
    x = { x[1] / lx, x[2] / lx, x[3] / lx }
    local d = x[1] * z[1] + x[2] * z[2] + x[3] * z[3]
    z = { z[1] - x[1] * d, z[2] - x[2] * d, z[3] - x[3] * d }
    local lz = math.sqrt(z[1] ^ 2 + z[2] ^ 2 + z[3] ^ 2)
    z = { z[1] / lz, z[2] / lz, z[3] / lz }
    local y = { z[2] * x[3] - z[3] * x[2], z[3] * x[1] - z[1] * x[3], z[1] * x[2] - z[2] * x[1] }
    return { { x[1], y[1], z[1] }, { x[2], y[2], z[2] }, { x[3], y[3], z[3] } }
end

local function mul(m, p)
    return { m[1][1] * p[1] + m[1][2] * p[2] + m[1][3] * p[3],
             m[2][1] * p[1] + m[2][2] * p[2] + m[2][3] * p[3],
             m[3][1] * p[1] + m[3][2] * p[2] + m[3][3] * p[3] }
end

---(pitch, roll, yaw) degrees of R = Rz(yaw) Rx(pitch) Ry(roll), as tools/props/weapons/fits.py euler_yxz.
local function euler(m)
    local s = math.max(-1, math.min(1, m[3][2]))

    if math.abs(s) < 0.99999 then
        return deg(asin(s)), deg(atan(-m[3][1], m[3][3])), deg(atan(-m[1][2], m[2][2]))
    end

    return deg(asin(s)), 0.0, deg(atan(m[2][1], m[1][1]))
end

---The 8 corners of a box.
local function corners(lo, hi)
    local out = {}
    for _, x in ipairs({ lo.x, hi.x }) do
        for _, y in ipairs({ lo.y, hi.y }) do
            for _, z in ipairs({ lo.z, hi.z }) do
                out[#out + 1] = { x, y, z }
            end
        end
    end

    return out
end

local function bounds(pts)
    local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for _, p in ipairs(pts) do
        for i = 1, 3 do
            if p[i] < lo[i] then
                lo[i] = p[i]
            end

            if p[i] > hi[i] then
                hi[i] = p[i]
            end
        end
    end

    return lo, hi
end

-- ---- an addon gun from its box, per type of slot (the same rules as fits.py, a box standing in for the mesh) ------
local placeBy = {}

---Standing on its butt, leaning back by the median lean: the butt's middle on the notch, its lowest point on its floor.
function placeBy.upright(lo, hi, fb)
    local th = rad(fb.lean or 6.0)
    local R = basis({ 0, sin(th), cos(th) }, { 0, cos(th), -sin(th) })
    local pts = {}
    for i, c in ipairs(corners(lo, hi)) do
        pts[i] = mul(R, c)
    end

    local blo = bounds(pts)
    local butt = {}
    for _, c in ipairs(corners(lo, hi)) do
        if c[1] == lo.x then
            butt[#butt + 1] = mul(R, c)
        end
    end

    local flo, fhi = bounds(butt)
    return R, { -(lo.y + hi.y) / 2, -(flo[2] + fhi[2]) / 2, -blo[3] }
end

---Lying on its hooks, level, its box's bottom the median distance under the support line, its side on the wall.
function placeBy.horizontal(lo, hi, fb)
    local m = fb.muzzle or -1
    local R = basis({ m, 0, 0 }, { 0, 0, 1 })
    local pts = {}
    for i, c in ipairs(corners(lo, hi)) do
        pts[i] = mul(R, c)
    end

    local blo, bhi = bounds(pts)
    local h = hi.z - lo.z
    return R, { -(blo[1] + bhi[1]) / 2, -(bhi[2] + (fb.gap or 0.004)), -blo[3] - (fb.rest or 0.5) * h }
end

---The barrel's end on its bore line, from the box: the front face, the median bore height up it.
local function tip(lo, hi, fb)
    return { hi.x, (lo.y + hi.y) / 2, lo.z + (fb.bore or 0.7) * (hi.z - lo.z) }
end

function placeBy.peg(lo, hi, fb)
    local a = rad(fb.angle or 8.0)
    local d = { 0, -cos(a), sin(a) }
    local R = basis({ 0, cos(a), -sin(a) }, { 0, sin(a), cos(a) })
    local p = mul(R, tip(lo, hi, fb))
    local g = fb.gap or 0.03
    return R, { d[1] * g - p[1], d[2] * g - p[2], d[3] * g - p[3] }
end

function placeBy.post(lo, hi, fb)
    local R = basis({ 0, 0, -1 }, { 0, 1, 0 })
    local p = mul(R, tip(lo, hi, fb))
    return R, { -p[1], -p[2], (fb.gap or 0.03) - p[3] }
end

function placeBy.flat(lo, hi, fb)
    local m = fb.muzzle or -1
    local R = basis({ m, 0, 0 }, { 0, 0, 1 })
    local t = tip(lo, hi, fb)
    local mid = mul(R, { (lo.x + hi.x) / 2, 0, t[3] })
    local pts = {}
    for i, c in ipairs(corners(lo, hi)) do
        pts[i] = mul(R, c)
    end

    local _, bhi = bounds(pts)
    return R, { -mid[1], -(bhi[2] - mid[2] + (fb.gap or 0.012)) - mid[2], -mid[3] }
end

---Where a weapon object goes on a rack, in the rack's own space (AttachEntityToEntity's offset and rotation, order 2).
---@param model string rack model
---@param slot integer 1-based slot index
---@param weapon string weapon item name
---@param dmin? vector3 the weapon model's GetModelDimensions minimum (only needed for addon guns)
---@param dmax? vector3 and maximum
---@return vector3|nil offset, vector3|nil rotation (pitch, roll, yaw)
function fit.place(model, slot, weapon, dmin, dmax)
    local name = weapons.normalise(weapon)
    local s, kind = slotOf(model, slot)
    local r = fit.rack(model)

    if not name or not s or not kind or not r then return nil, nil end

    local row = r.fits[s.kind] and r.fits[s.kind][name]

    if not row then
        if not (dmin and dmax and placeBy[kind.type] and fit.accepts(model, slot, name)) then
            return nil, nil
        end

        local R, t = placeBy[kind.type](dmin, dmax, kind.fallback or {})
        local p, rl, y = euler(R)
        row = { t[1], t[2], t[3], p, rl, y }
    end

    local yaw = rad(s.yaw or 0.0)
    local c, sn = cos(yaw), sin(yaw)
    local px, py = row[1] * c - row[2] * sn, row[1] * sn + row[2] * c
    return vector3(s.pos[1] + px, s.pos[2] + py, s.pos[3] + row[3]),
        vector3(row[4], row[5], row[6] + (s.yaw or 0.0))
end

return fit
