"""The ten sd_gunrack_* models, built at real size in metres, with the detail a player standing at arm's length sees:
bevelled joinery, routed edges, felt and leather linings, real hardware (screws, standoffs, flanges, nuts).

Each builder fills a Kit: its parts (Blender objects with bevel modifiers, every face carrying a looks.PAINTS index), the
linear maps that place its pictures (engraved plates, the stencil), its slots and the KINDS of slot it has, and its
collision boxes. build.py merges, unwraps, bakes, fits every vanilla firearm into every kind (tools/props/weapons/
fits.py, against the real meshes), checks each fit against this very geometry, and exports.

Frames (the rack's own; contract: docs/contract.md)
    every rack      metres, +Z up, its FRONT faces -Y
    floor/surface   built round x = 0 near y = 0; build.py moves the origin to the footprint's middle, on the floor
    wall            built with the wall at y = 0 (the rack in -Y) and x = 0 its middle; build.py drops its lowest
                    point onto z = 0
    corner          its origin IS the room's corner (the two walls run out from it at +-45 degrees from -Y): not moved

A slot's frame (fits.py): upright -- origin on the floor of the butt notch, +Y back toward the rest; horizontal -- origin
midway between the hooks, on their support line, on the wall's face; peg -- origin at the peg's root on the board's
face; post -- origin on the deck at the post's foot. The geometry here is built FROM the same numbers the fits use, so a
notch, a rest, a hook and a peg are where the guns were fitted.

Normals: GTA culls back faces. Prisms take counter-clockwise outlines; lathe profiles walk with the solid on their left
(out along the bottom, up the outside, in across the top).
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector

from looks import P
from shapes import TAU, V, box, circle2d, disc, lathe, prism, quad, rect2d, tube

B_WOOD = (0.0025, 3, 35)     # routed / eased wood edges
B_FINE = (0.0010, 2, 35)     # small parts, hardware
B_METAL = (0.0015, 2, 35)    # sheet and tube


class Kit:
    def __init__(self, name, paint_mats):
        self.name = name
        self.mats = paint_mats
        self.parts = []
        self.regions = {}
        self.kinds = {}          # key -> {type, label, params, groups?}
        self.slots = []          # {kind, pos, yaw, focus, radius}
        self.collision = []      # [(lo, hi)]
        self.col_mat = 'WOOD_SOLID_MEDIUM'
        self.mount = 'floor'
        self.label = name
        self.budget = (6000, 40000)
        self.tex = dict(bake=2048, d=2048, n=1024, s=512, ao=0.06)
        self.lod_ratio = 0.3
        self.lod_dist = 60.0
        self.recentre = True

    def part(self, label, bm, bevel=None, recalc=False, weld=False, matrix=None):
        if weld:
            bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=1e-7)
        if recalc:
            bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        me = bpy.data.meshes.new(f'{self.name}.{label}')
        bm.to_mesh(me)
        bm.free()
        for m in self.mats:
            me.materials.append(m)
        ob = bpy.data.objects.new(me.name, me)
        bpy.context.scene.collection.objects.link(ob)
        if bevel:
            w, segs, ang = bevel
            m = ob.modifiers.new('bevel', 'BEVEL')
            m.width = w
            m.segments = segs
            m.limit_method = 'ANGLE'
            m.angle_limit = math.radians(ang)
            m.use_clamp_overlap = True
            m.profile = 0.5
        if matrix is not None:
            ob.matrix_world = matrix
        self.parts.append(ob)
        return ob

    def kind(self, key, type_, label, **params):
        self.kinds[key] = dict(type=type_, label=label, params=params)

    def slot(self, key, pos, yaw=0.0, focus=None, radius=0.10):
        self.slots.append(dict(kind=key, pos=Vector(pos), yaw=float(yaw),
                               focus=Vector(focus if focus is not None else pos), radius=radius))

    def collide(self, lo, hi):
        self.collision.append((Vector(lo), Vector(hi)))

    def plate(self, paint, x0, x1, z0, z1):
        """A picture on a face looking along -y, covering x0..x1, z0..z1."""
        w, h = x1 - x0, z1 - z0
        self.regions[paint] = ((1 / w, 0, 0, -x0 / w), (0, 0, 1 / h, -z0 / h))


# ---- helpers ---------------------------------------------------------------------------------------------------------
YZ = Matrix(((0, 0, 1, 0), (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 0, 1)))       # local (x, y, z) -> world (z, x, y)
XZ = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))      # local (x, y, z) -> world (x, -z, y)


def T(x, y, z):
    return Matrix.Translation((x, y, z))


def Rz(deg):
    return Matrix.Rotation(math.radians(deg), 4, 'Z')


def slab_yz(bm, outline, x0, x1, mi, matrix=None):
    """An outline in (y, z) (counter-clockwise) cut from a board x0..x1 thick: a side panel."""
    M = (matrix or Matrix.Identity(4)) @ YZ
    return prism(bm, outline, x0, x1, mi, M)


def slab_xz(bm, outline, y0, y1, mi, matrix=None):
    """An outline in (x, z) (counter-clockwise, seen from the front) cut from a board y0..y1 thick: a back board."""
    M = (matrix or Matrix.Identity(4)) @ XZ
    return prism(bm, outline, -y1, -y0, mi, M)


def arc(cx, cy, r, a0, a1, n=8):
    """Points on a circle from angle a0 to a1 (degrees), inclusive."""
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * k / n)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * k / n))) for k in range(n + 1)]


def ease(p0, p1, n=10):
    """A smooth S between two points (cosine ease in both coordinates' second), endpoints excluded at the start."""
    out = []
    for k in range(1, n + 1):
        t = k / n
        s = 0.5 - 0.5 * math.cos(math.pi * t)
        out.append((p0[0] + (p1[0] - p0[0]) * s, p0[1] + (p1[1] - p0[1]) * t))
    return out


def along(p0, p1):
    """The matrix that stands a part built along +Z at p0, pointing at p1."""
    d = Vector(p1) - Vector(p0)
    q = Vector((0, 0, 1)).rotation_difference(d.normalized())
    return T(*p0) @ q.to_matrix().to_4x4()


def rod(bm, p0, p1, r, mi, segs=16, ends=('flat', 'flat')):
    """A round bar from p0 to p1; each end flat, domed ('ball') or open (None)."""
    L = (Vector(p1) - Vector(p0)).length
    prof = []
    if ends[0] == 'ball':
        prof += [(0.0, -r)] + [(r * math.sin(t), -r * math.cos(t)) for t in (math.pi / 2 * k / 4 for k in range(1, 4))]
    elif ends[0] == 'flat':
        prof += [(0.0, 0.0)]
    prof += [(r, 0.0), (r, L)]
    if ends[1] == 'ball':
        prof += [(r * math.cos(t), L + r * math.sin(t)) for t in (math.pi / 2 * k / 4 for k in range(1, 4))] + [(0.0, L + r)]
    elif ends[1] == 'flat':
        prof += [(0.0, L)]
    return lathe(bm, prof, segs, mi, matrix=along(p0, p1))


def screw(bm, c, normal, r, mi, slot_mi):
    """A round-headed screw on a face looking along `normal`: a low dome with a slot across it."""
    n = Vector(normal).normalized()
    M = along(c, Vector(c) + n)
    lathe(bm, [(0.0, 0.0), (r, 0.0), (r, r * 0.2), (r * 0.72, r * 0.45), (0.0, r * 0.55)], 14, mi, matrix=M)
    box(bm, (-r * 0.8, -r * 0.12, r * 0.30), (r * 0.8, r * 0.12, r * 0.58), slot_mi, M)


def nut(bm, c, normal, af, h, mi):
    """A hex nut / bolt head on a face looking along `normal`."""
    M = along(c, Vector(c) + Vector(normal))
    rr = af / 2 / math.cos(math.pi / 6)
    pts = [(rr * math.cos(math.pi / 6 + k * math.pi / 3), rr * math.sin(math.pi / 6 + k * math.pi / 3)) for k in range(6)]
    prism(bm, pts, 0.0, h, mi, M)


def sector(bm, r0, r1, a0, a1, z0, z1, mi, n=24):
    """An annular sector (radii r0..r1, angles a0..a1 degrees from -Y toward +X) from z0 to z1."""
    def pt(r, a):
        return (r * math.sin(math.radians(a)), -r * math.cos(math.radians(a)))
    outer = [pt(r1, a0 + (a1 - a0) * k / n) for k in range(n + 1)]
    inner = [pt(r0, a1 - (a1 - a0) * k / n) for k in range(n + 1)] if r0 > 1e-6 else [(0.0, 0.0)]
    pts = outer + inner
    # counter-clockwise seen from +Z: the outer arc runs from a0 to a1 (toward +x from -y: counter-clockwise)
    return prism(bm, pts, z0, z1, mi)


def tray(bm, xs, notch_w, y0, y1, wall, z_floor, z_top, x_end, floor_mi, wall_mi, pad_mi, pad=0.004, z_base=None):
    """A butt tray: a floor slab, front and back walls, dividers between notches (notch centres xs, width notch_w,
    running y0..y1), a pad lining each notch's floor (its top at z_floor), end blocks out to +-x_end."""
    zb = z_base if z_base is not None else z_floor - pad - 0.025
    box(bm, (-x_end, y0 - wall, zb), (x_end, y1 + wall, z_floor - pad), floor_mi)
    box(bm, (-x_end, y0 - wall, z_floor - pad), (x_end, y0, z_top), wall_mi)
    box(bm, (-x_end, y1, z_floor - pad), (x_end, y1 + wall, z_top), wall_mi)
    edges = [-x_end] + [x + s * notch_w / 2 for x in xs for s in (-1, 1)] + [x_end]
    for a, b in zip(edges[0::2], edges[1::2]):
        if b - a > 1e-4:
            box(bm, (a, y0, z_floor - pad), (b, y1, z_top), wall_mi)
    for x in xs:
        box(bm, (x - notch_w / 2, y0, z_floor - pad), (x + notch_w / 2, y1, z_floor), pad_mi)


def comb(bm, xs, rest_w, y_front, y_stop, y_back, z0, z1, x_end, wood_mi, lining_mi, lining=0.003):
    """A rest bar along x with U notches open to the front (-y): solid behind the stop, teeth between notches, the
    notches' back walls lined. The gun touches the lining's face at y_stop."""
    box(bm, (-x_end, y_stop + lining, z0), (x_end, y_back, z1), wood_mi)
    edges = [-x_end] + [x + s * rest_w / 2 for x in xs for s in (-1, 1)] + [x_end]
    for a, b in zip(edges[0::2], edges[1::2]):
        if b - a > 1e-4:
            box(bm, (a, y_front, z0), (b, y_stop + lining, z1), wood_mi)
    for x in xs:
        box(bm, (x - rest_w / 2, y_stop, z0 + 0.002), (x + rest_w / 2, y_stop + lining, z1 - 0.002), lining_mi)


def j_hook(bm, x, y_face, z_line, depth, lip_h, r, mi, plate_mi=None, screw_mi=None):
    """A rubber-dipped J-hook standing out of a face at y_face: an arm whose TOP is the support line z_line, out to
    `depth` (the lip's inside face), a lip rising lip_h above the line, a ball on it; a mounting plate behind."""
    zc = z_line - r
    yl = y_face - depth - r                       # the lip's centre line
    rod(bm, (x, y_face + 0.002, zc), (x, yl, zc), r, mi, 16, ends=(None, None))
    # the bend: a quarter torus from the arm into the lip
    path = [Vector((x, yl + r * 1.2 * (1 - math.sin(t)), zc + r * 1.2 * (1 - math.cos(t)))) for t in
            (math.pi / 2 * k / 6 for k in range(7))]
    tube(bm, path, circle2d(r, 16), mi, caps=(False, False))
    rod(bm, (x, yl, zc + r * 1.2), (x, yl, z_line + lip_h), r, mi, 16, ends=(None, 'ball'))
    if plate_mi is not None:
        box(bm, (x - 0.014, y_face - 0.004, zc - 0.030), (x + 0.014, y_face + 0.0005, zc + 0.012), plate_mi)
        if screw_mi is not None:
            for dz in (-0.022, 0.006):
                screw(bm, (x, y_face - 0.004, zc + dz), (0, -1, 0), 0.0035, screw_mi, P('dark'))


# =====================================================================================================================
# 1. Oak floor rack: eight long guns standing in a felt-lined butt tray, leaning back into a felt-lined comb
# =====================================================================================================================
def oak(k):
    """Golden oak, 0.98 x 0.34 m, 0.72 m tall: shaped side panels with a cove and a crest, a routed plinth, a butt tray
    with felt in every notch, a comb with felt on every stop, a scalloped back rail, turned rosettes on the panels, a
    brass maker's plate."""
    k.label, k.mount = 'Oak Floor Rack', 'floor'
    U = dict(rest_h=0.50, rest_t=0.035, rest_y=0.15, rest_w=0.080, notch_w=0.066, notch_len=0.19)
    k.kind('long', 'upright', 'Long gun', **U)
    N, SP = 8, 0.11
    xs = [(i - (N - 1) / 2) * SP for i in range(N)]
    sy, z0 = -0.04, 0.060                              # notch centre, notch floor
    stop = sy + U['rest_y']
    zr = z0 + U['rest_h']
    XI = 0.46                                          # the panels' inner faces
    OAKX, OAKY, OAKZ, FELT = P('oak_x'), P('oak_y'), P('oak_z'), P('felt_green')

    bm = bmesh.new()                                   # the plinth: a routed base between the panels
    prism(bm, rect2d(2 * XI, 0.34, 0.012, 3), 0.0, 0.028, OAKX, T(0, -0.005, 0))
    k.part('plinth', bm, bevel=(0.004, 3, 35))

    bm = bmesh.new()
    tray(bm, xs, U['notch_w'], sy - U['notch_len'] / 2, sy + U['notch_len'] / 2, 0.02, z0, z0 + 0.05, XI,
         OAKX, OAKX, FELT, z_base=0.028)
    k.part('tray', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # the comb
    comb(bm, xs, U['rest_w'], stop - 0.05, stop, stop + 0.045, zr - U['rest_t'] / 2, zr + U['rest_t'] / 2, XI, OAKX, FELT)
    k.part('comb', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # the back rail, its top scalloped between the slots
    n = int(round(2 * XI / 0.01))

    def scallop(x):
        d = min(abs(x - c) for c in xs)
        return 0.185 - 0.015 * math.cos(2 * math.pi * min(d, SP / 2) / SP)

    top = [(XI - 2 * XI * i / n, scallop(XI - 2 * XI * i / n)) for i in range(n + 1)]
    slab_xz(bm, [(-XI, 0.028), (XI, 0.028)] + top, 0.10, 0.12, OAKX)
    k.part('backrail', bm, bevel=B_WOOD)

    # the side panels: up the back, a rounded crest over the comb, down a cove to the plinth's front
    outline = [(-0.17, 0.0), (0.17, 0.0), (0.17, zr + 0.04)] + arc(0.10, zr + 0.04, 0.07, 0, 180, 12)[1:]
    outline += [(0.03, zr - 0.08)] + ease((0.03, zr - 0.08), (-0.17, 0.10), 16)
    bm = bmesh.new()
    for s in (-1, 1):
        x0, x1 = (XI, XI + 0.03) if s > 0 else (-XI - 0.03, -XI)
        slab_yz(bm, outline, x0, x1, OAKZ)
    k.part('panels', bm, bevel=(0.004, 3, 35))

    bm = bmesh.new()                                   # turned rosettes on the panels' outer faces
    for s in (-1, 1):
        M = along((s * (XI + 0.03), 0.02, 0.30), (s * (XI + 0.04), 0.02, 0.30))
        lathe(bm, [(0.0, 0.0), (0.045, 0.0), (0.045, 0.004), (0.040, 0.007), (0.034, 0.007), (0.030, 0.010),
                   (0.020, 0.012), (0.012, 0.016), (0.0, 0.017)], 48, OAKY, matrix=M)
        # dowel plugs where the tray and the comb are pinned through the panel: end grain, a hair proud
        for y, z in ((sy - 0.06, z0 + 0.02), (sy + 0.06, z0 + 0.02), (stop - 0.02, zr), (stop + 0.025, zr)):
            lathe(bm, [(0.0, 0.0), (0.0065, 0.0), (0.0065, 0.0008), (0.0055, 0.0014), (0.0, 0.0015)], 20, OAKX,
                  matrix=along((s * (XI + 0.0295), y, z), (s * (XI + 1.0), y, z)))
    k.part('rosettes', bm, bevel=None)

    bm = bmesh.new()                                   # a routed bead along the plinth's front and back
    for y in (-0.1745, 0.1645):
        rod(bm, (-XI + 0.004, y, 0.022), (XI - 0.004, y, 0.022), 0.004, OAKX, 12, ends=('ball', 'ball'))
    k.part('bead', bm)

    bm = bmesh.new()                                   # the maker's plate on the tray's front, two brass pins
    yf = sy - U['notch_len'] / 2 - 0.02
    box(bm, (-0.075, yf - 0.0015, z0 + 0.012), (0.075, yf + 0.0002, z0 + 0.040), P('brass'))
    quad(bm, [(-0.072, yf - 0.0016, z0 + 0.015), (0.072, yf - 0.0016, z0 + 0.015), (0.072, yf - 0.0016, z0 + 0.037),
              (-0.072, yf - 0.0016, z0 + 0.037)], P('plate_oak'), (0, -1, 0))
    for x in (-0.066, 0.066):
        screw(bm, (x, yf - 0.0016, z0 + 0.026), (0, -1, 0), 0.0022, P('brass'), P('dark'))
    k.plate('plate_oak', -0.072, 0.072, z0 + 0.015, z0 + 0.037)
    k.part('plate', bm)

    for x in xs:
        k.slot('long', (x, sy, z0), 0.0, focus=(x, sy - 0.03, z0 + 0.30), radius=0.09)
    k.collide((-XI - 0.03, -0.175, 0.0), (XI + 0.03, 0.175, z0 + 0.05))
    k.collide((-XI - 0.03, stop - 0.05, zr - 0.02), (XI + 0.03, stop + 0.05, zr + 0.02))
    for s in (-1, 1):
        k.collide((min(s * XI, s * (XI + 0.03)), -0.17, 0.0), (max(s * XI, s * (XI + 0.03)), 0.17, zr + 0.10))


# =====================================================================================================================
# 2. Steel wall panel: three long guns lying on rubber-dipped J-hooks, a LED bar over it (the second reference image)
# =====================================================================================================================
def panel(k):
    """A 1.10 x 1.10 m galvanised steel plate held 35 mm off the wall on four chrome standoffs, a dark rail along its
    top and bottom, three rows of J-hooks, an aluminium LED bar over the top edge."""
    k.label, k.mount, k.col_mat = 'Steel Wall Panel', 'wall', 'METAL_SOLID_MEDIUM'
    H = dict(hooks=(-0.21, 0.21), hook_w=0.030, lip_y=-0.100, lip_h=0.030, muzzle=-1, gap=0.004)
    k.kind('long', 'horizontal', 'Long gun', **H)
    W, Ht, OFF, TH = 1.10, 1.20, 0.035, 0.006
    yf = -(OFF + TH)                                   # the plate's face
    rows = [0.25, 0.58, 0.91]

    bm = bmesh.new()
    slab_xz(bm, rect2d(W, Ht, 0.025, 4), yf, -OFF, P('galv'), T(0, 0, Ht / 2))
    k.part('plate', bm, bevel=B_METAL)

    bm = bmesh.new()                                   # standoffs: a barrel behind, a domed cap in front
    for x in (-W / 2 + 0.05, W / 2 - 0.05):
        for z in (0.05, Ht - 0.05):
            lathe(bm, [(0.0, 0.0), (0.012, 0.0), (0.012, OFF - 0.0005), (0.0, OFF - 0.0005)], 24, P('chrome'),
                  matrix=along((x, 0.0, z), (x, -1.0, z)))
            lathe(bm, [(0.0, 0.0), (0.013, 0.0), (0.013, 0.008), (0.011, 0.011), (0.006, 0.013), (0.0, 0.0135)], 24,
                  P('chrome'), matrix=along((x, yf, z), (x, yf - 1.0, z)))
    k.part('standoffs', bm)

    bm = bmesh.new()                                   # the rails, top and bottom, on short posts
    for z in (0.030, Ht - 0.030):
        rod(bm, (-W / 2 + 0.03, yf - 0.032, z), (W / 2 - 0.03, yf - 0.032, z), 0.008, P('coat_black'), 20,
            ends=('ball', 'ball'))
        for x in (-W / 2 + 0.11, W / 2 - 0.11):
            rod(bm, (x, yf + 0.001, z), (x, yf - 0.032, z), 0.006, P('coat_black'), 12, ends=(None, None))
            lathe(bm, [(0.0, 0.0), (0.012, 0.0), (0.012, 0.003), (0.0, 0.003)], 20, P('coat_black'),
                  matrix=along((x, yf, z), (x, yf - 1, z)))
    k.part('rails', bm)

    bm = bmesh.new()                                   # the hooks
    for z in rows:
        for hx in H['hooks']:
            j_hook(bm, hx, yf, z, -H['lip_y'], H['lip_h'], 0.007, P('rubber'), P('coat_black'), P('chrome'))
    k.part('hooks', bm, bevel=None)

    bm = bmesh.new()                                   # an LED bar over the top edge: arms, an extrusion, a diffuser
    zt = Ht + 0.03
    for x in (-0.35, 0.35):
        box(bm, (x - 0.008, yf - 0.002, Ht - 0.06), (x + 0.008, yf + 0.0005, Ht - 0.02), P('alu'))
        rod(bm, (x, yf - 0.001, Ht - 0.03), (x, yf - 0.06, zt), 0.005, P('alu'), 12, ends=(None, None))
    prism(bm, rect2d(0.80, 0.045, 0.006, 3), zt - 0.012, zt + 0.012, P('alu'), T(0, yf - 0.075, 0))
    box(bm, (-0.395, yf - 0.095, zt - 0.0135), (0.395, yf - 0.055, zt - 0.011), P('diffuser'))
    for s in (-1, 1):
        box(bm, (s * 0.400 - 0.003, yf - 0.098, zt - 0.014), (s * 0.400 + 0.003, yf - 0.052, zt + 0.014),
            P('plastic_black'))
    k.part('led', bm, bevel=B_FINE)

    for z in rows:
        k.slot('long', (0.0, yf, z), 0.0, focus=(0.0, yf - 0.05, z + 0.02), radius=0.13)
    k.collide((-W / 2, yf, 0.0), (W / 2, 0.0, Ht))


# =====================================================================================================================
# 3. Walnut wall rack: six long guns standing in leather-lined cups on a bracketed shelf, leaning into a notched rail
# =====================================================================================================================
def walnut(k):
    """Walnut: a crested back board, a shelf on two carved brackets with six leather-lined butt cups, a rail with
    leather-lined notches, turned finials, a brass plate."""
    k.label, k.mount = 'Walnut Wall Rack', 'wall'
    U = dict(rest_h=0.50, rest_t=0.035, rest_y=0.15, rest_w=0.080, notch_w=0.066, notch_len=0.19)
    k.kind('long', 'upright', 'Long gun', **U)
    N, SP = 6, 0.115
    xs = [(i - (N - 1) / 2) * SP for i in range(N)]
    BF = -0.022                                        # the back board's face
    stop = BF - 0.065                                  # the rail's notches stop here: far enough off the board
                                                       # that a leaning gun's top clears it (up to 8.5 cm back)
    sy = stop - U['rest_y']
    z0 = 0.035
    zr = z0 + U['rest_h']
    XB = 0.40
    WX, WZ, LEA = P('walnut_x'), P('walnut_z'), P('leather')

    bm = bmesh.new()                                   # the back board, its top a crest
    crest = [(XB, zr + 0.08)] + ease((XB, zr + 0.08), (0.12, zr + 0.13), 10) + arc(0.0, zr + 0.13, 0.12, 0, 180, 16)[1:-1]
    crest += [(-0.12, zr + 0.13)] + ease((-0.12, zr + 0.13), (-XB, zr + 0.08), 10)
    outline = [(-XB, -0.20), (XB, -0.20)] + crest
    slab_xz(bm, outline, BF, 0.0, WZ)
    k.part('board', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # the shelf and its cups
    y0, y1 = sy - U['notch_len'] / 2, sy + U['notch_len'] / 2
    tray(bm, xs, U['notch_w'], y0, y1, 0.018, z0, z0 + 0.045, XB - 0.02, WX, WX, LEA, z_base=0.0)
    box(bm, (-XB + 0.02, y1 + 0.018, 0.0), (XB - 0.02, BF, z0 + 0.045), WX)
    k.part('shelf', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # carved brackets under the shelf
    prof = [(BF, -0.19), (BF, 0.0), (y0 - 0.018, 0.0)] + ease((y0 - 0.018, 0.0), (BF - 0.03, -0.17), 12)
    for x in (-XB + 0.06, XB - 0.06):
        slab_yz(bm, prof, x - 0.014, x + 0.014, WZ)
    k.part('brackets', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # the rail
    comb(bm, xs, U['rest_w'], stop - 0.045, stop, BF, zr - U['rest_t'] / 2, zr + U['rest_t'] / 2, XB - 0.02, WX, LEA)
    for x in (-XB + 0.02, XB - 0.02):                  # its ends rounded off into the board
        lathe(bm, [(0.0, 0.0), (0.024, 0.0), (0.024, 0.006), (0.018, 0.012), (0.0, 0.014)], 32, WX,
              matrix=along((x, (stop - 0.045 + BF) / 2, zr), (x + (1 if x > 0 else -1), (stop - 0.045 + BF) / 2, zr)))
    k.part('rail', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # turned finials on the crest's shoulders
    for x in (-XB + 0.05, XB - 0.05):
        lathe(bm, [(0.0, 0.0), (0.011, 0.0), (0.011, 0.010), (0.008, 0.015), (0.013, 0.030), (0.009, 0.045),
                   (0.005, 0.052), (0.008, 0.058), (0.0, 0.068)], 32, WZ, matrix=T(x, BF / 2, zr + 0.075))
    k.part('finials', bm)

    bm = bmesh.new()                                   # the plate on the shelf's front
    yf = y0 - 0.018
    box(bm, (-0.07, yf - 0.0015, 0.012), (0.07, yf + 0.0002, 0.036), P('brass'))
    quad(bm, [(-0.067, yf - 0.0016, 0.015), (0.067, yf - 0.0016, 0.015), (0.067, yf - 0.0016, 0.033),
              (-0.067, yf - 0.0016, 0.033)], P('plate_walnut'), (0, -1, 0))
    k.plate('plate_walnut', -0.067, 0.067, 0.015, 0.033)
    for x in (-0.062, 0.062):
        screw(bm, (x, yf - 0.0016, 0.024), (0, -1, 0), 0.0022, P('brass'), P('dark'))
    k.part('plate', bm)

    for x in xs:
        k.slot('long', (x, sy, z0), 0.0, focus=(x, sy - 0.03, z0 + 0.30), radius=0.09)
    k.collide((-XB, y0 - 0.02, -0.20), (XB, 0.0, z0 + 0.05))
    k.collide((-XB, stop - 0.05, zr - 0.02), (XB, 0.0, zr + 0.13))


# =====================================================================================================================
# 4. Tactical pegboard: two long guns on hooks, six handguns on pegs, a shelf
# =====================================================================================================================
def pegboard(k):
    """Black powder-coated punched steel, 1.10 x 1.00 m, its edges folded back to the wall: two rows of rubber-dipped
    long-gun hooks, six rubber-dipped pistol pegs, a steel shelf with a lip along the bottom."""
    k.label, k.mount, k.col_mat = 'Tactical Pegboard', 'wall', 'METAL_SOLID_MEDIUM'
    H = dict(hooks=(-0.21, 0.21), hook_w=0.030, lip_y=-0.095, lip_h=0.028, muzzle=-1, gap=0.004)
    G = dict(angle=8.0, gap=0.030, length=0.075, clear=0.003, max_len=0.43)
    k.kind('long', 'horizontal', 'Long gun', **H)
    k.kind('pistol', 'peg', 'Handgun', **G)
    W, Ht, D = 1.10, 1.00, 0.031
    yf = -D

    bm = bmesh.new()                                   # the punched face and the folded edges
    slab_xz(bm, rect2d(W, Ht, 0.004, 2), yf, yf + 0.0025, P('pegboard'), T(0, 0, Ht / 2))
    for s in (-1, 1):
        box(bm, (s * W / 2 - (0.0025 if s > 0 else 0.0), yf, 0.0), (s * W / 2 + (0.0 if s > 0 else 0.0025), 0.0, Ht),
            P('coat_black'))
    box(bm, (-W / 2, yf, 0.0), (W / 2, 0.0, 0.0025), P('coat_black'))
    box(bm, (-W / 2, yf, Ht - 0.0025), (W / 2, 0.0, Ht), P('coat_black'))
    k.part('board', bm, bevel=B_FINE)

    rows, pz = [0.58, 0.86], 0.29
    px = [(i - 2.5) * 0.17 for i in range(6)]
    bm = bmesh.new()
    for z in rows:
        for hx in H['hooks']:
            j_hook(bm, hx, yf, z, -H['lip_y'], H['lip_h'], 0.0055, P('rubber'), P('coat_black'), P('steel'))
    a = math.radians(G['angle'])
    d = Vector((0.0, -math.cos(a), math.sin(a)))
    for x in px:
        root = Vector((x, yf, pz))
        rod(bm, root + d * -0.002, root + d * G['length'], 0.0055, P('rubber'), 16, ends=(None, 'ball'))
        nut(bm, (x, yf, pz), (0, -1, 0), 0.013, 0.006, P('coat_black'))
    k.part('hooks', bm)

    bm = bmesh.new()                                   # the shelf
    zs = 0.06
    box(bm, (-0.50, yf - 0.12, zs - 0.0025), (0.50, yf, zs), P('coat_black'))
    box(bm, (-0.50, yf - 0.12, zs), (0.50, yf - 0.1175, zs + 0.03), P('coat_black'))
    for x in (-0.44, 0.44):
        slab_yz(bm, [(yf, zs - 0.10), (yf, zs), (yf - 0.11, zs)], x - 0.0015, x + 0.0015, P('coat_black'))
    k.part('shelf', bm, bevel=B_FINE)

    for z in rows:
        k.slot('long', (0.0, yf, z), 0.0, focus=(0.0, yf - 0.05, z + 0.02), radius=0.12)
    for x in px:
        k.slot('pistol', (x, yf, pz), 0.0, focus=(x, yf - 0.10, pz - 0.02), radius=0.07)
    k.collide((-W / 2, yf, 0.0), (W / 2, 0.0, Ht))
    k.collide((-0.50, yf - 0.12, zs - 0.01), (0.50, yf, zs + 0.03))


# =====================================================================================================================
# 5. Pistol display board: eight handguns in profile on magnetic mounts, in a walnut frame on charcoal felt
# =====================================================================================================================
def pistols(k):
    """A walnut frame 0.84 x 0.96 m with a stepped moulding and a bead, a charcoal felt field, eight rubber-coated
    magnetic gun mounts (two columns of four), a brass plate along the bottom."""
    k.label, k.mount = 'Pistol Display Board', 'wall'
    F = dict(gap=0.012, muzzle=-1, max_len=0.335)
    k.kind('pistol', 'flat', 'Handgun', **F)
    W, Ht = 0.90, 0.96
    FF = -0.012                                        # the felt's face
    WX, WZ = P('walnut_x'), P('walnut_z')

    def mitred(bm, w_out, h_out, width, y0, y1):
        x1, z1 = w_out / 2, h_out
        xi, zi0, zi1 = x1 - width, width, h_out - width
        sides = [
            ([(-x1, 0.0), (x1, 0.0), (xi, zi0), (-xi, zi0)], WX),              # bottom
            ([(xi, zi0), (x1, 0.0), (x1, z1), (xi, zi1)], WZ),                 # right
            ([(-xi, zi1), (xi, zi1), (x1, z1), (-x1, z1)], WX),                # top
            ([(-x1, 0.0), (-xi, zi0), (-xi, zi1), (-x1, z1)], WZ),             # left
        ]
        for pts, mi in sides:
            slab_xz(bm, pts, y0, y1, mi)

    bm = bmesh.new()
    mitred(bm, W, Ht, 0.055, -0.040, 0.0)
    k.part('frame', bm, bevel=(0.004, 3, 35))
    bm = bmesh.new()
    mitred(bm, W - 0.094, Ht - 0.094, 0.014, -0.030, -0.012)
    k.part('bead', bm, bevel=(0.003, 3, 35), matrix=T(0, 0, 0.047))

    bm = bmesh.new()
    slab_xz(bm, rect2d(W - 0.11, Ht - 0.11, 0.0, 1), FF, 0.0, P('felt_black'), T(0, 0, Ht / 2))
    k.part('felt', bm)

    cols, rows = [-0.185, 0.185], [0.215, 0.42, 0.625, 0.83]
    bm = bmesh.new()                                   # the mounts: a rubber-coated magnet on a screwed base
    for z in rows:
        for cx in cols:
            prism(bm, rect2d(0.056, 0.030, 0.006, 3), 0.0, 0.003, P('coat_black'), along((cx, FF, z), (cx, FF - 1, z)))
            prism(bm, rect2d(0.050, 0.024, 0.008, 4), 0.003, F['gap'], P('rubber'), along((cx, FF, z), (cx, FF - 1, z)))
            for dx in (-0.024, 0.024):
                screw(bm, (cx + dx, FF - 0.003, z), (0, -1, 0), 0.0018, P('chrome'), P('dark'))
    k.part('mounts', bm, bevel=(0.0012, 2, 35))

    bm = bmesh.new()                                   # the plate on the frame's bottom rail
    yp = -0.0405
    box(bm, (-0.11, yp - 0.0015, 0.014), (0.11, yp + 0.0002, 0.042), P('brass'))
    quad(bm, [(-0.107, yp - 0.0016, 0.017), (0.107, yp - 0.0016, 0.017), (0.107, yp - 0.0016, 0.039),
              (-0.107, yp - 0.0016, 0.039)], P('plate_pistols'), (0, -1, 0))
    k.plate('plate_pistols', -0.107, 0.107, 0.017, 0.039)
    for x in (-0.102, 0.102):
        screw(bm, (x, yp - 0.0016, 0.028), (0, -1, 0), 0.0022, P('brass'), P('dark'))
    k.part('plate', bm)

    for z in rows:
        for cx in cols:
            k.slot('pistol', (cx, FF, z), 0.0, focus=(cx, FF - 0.03, z - 0.03), radius=0.08)
    k.collide((-W / 2, -0.046, 0.0), (W / 2, 0.0, Ht))


# =====================================================================================================================
# 6. Armory A-frame: twelve long guns, six a side, butts in rubber trays, leaning on a padded spine
# =====================================================================================================================
def armory(k):
    """An OD green square-tube A-frame 0.92 x 0.74 m, 0.80 m tall: rubber butt trays both sides, a padded spine
    with rubber-lined notches both sides, end caps, a lock bar with a padlock, stencilled end plates."""
    k.label, k.mount, k.col_mat = 'Armory A-Frame', 'floor', 'METAL_SOLID_MEDIUM'
    U = dict(rest_h=0.62, rest_t=0.040, rest_y=0.22, rest_w=0.082, notch_w=0.068, notch_len=0.19, max_lean=22.0)
    k.kind('long', 'upright', 'Long gun', **U)
    N, SP = 6, 0.12
    xs = [(i - (N - 1) / 2) * SP for i in range(N)]
    sy, z0 = 0.28, 0.075
    stop = sy - U['rest_y']                            # 0.06: the spine's stops at y = +-0.06
    zr = z0 + U['rest_h']
    XE = 0.42
    OD, RUB, CAP = P('coat_od'), P('rubber'), P('plastic_black')
    T4 = 0.02                                          # half a 40 mm tube

    bm = bmesh.new()                                   # base: two long rails, two end cross members
    for s in (-1, 1):
        box(bm, (-XE, s * sy - T4, 0.0), (XE, s * sy + T4, 0.04), OD)
    for x in (-XE, XE):
        box(bm, (x - T4, -sy - 0.05, 0.0), (x + T4, sy + 0.05, 0.04), OD)
    k.part('base', bm, bevel=B_METAL)

    bm = bmesh.new()                                   # the trays
    for s in (-1, 1):
        M = Matrix.Identity(4) if s > 0 else Rz(180)
        b2 = bmesh.new()
        tray(b2, xs, U['notch_w'], sy - U['notch_len'] / 2, sy + U['notch_len'] / 2, 0.015, z0, z0 + 0.045, XE - T4,
             RUB, RUB, RUB, z_base=0.04)
        bmesh.ops.transform(b2, matrix=M, verts=b2.verts[:])
        me = bpy.data.meshes.new('tmp')
        b2.to_mesh(me)
        b2.free()
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    k.part('trays', bm, bevel=(0.002, 2, 35))

    bm = bmesh.new()                                   # the legs: from the base's corners up to the spine
    for x in (-XE, XE):
        for s in (-1, 1):
            p0, p1 = Vector((x, s * (sy + 0.03), 0.02)), Vector((x, s * 0.03, zr + 0.04))
            M = along(p0, p1)
            prism(bm, rect2d(0.04, 0.04, 0.004, 2), 0.0, (p1 - p0).length, OD, M)
        box(bm, (x - T4, -0.05, zr + 0.02), (x + T4, 0.05, zr + 0.08), OD)              # the apex block
        box(bm, (x - T4, -sy + 0.05, 0.30), (x + T4, sy - 0.05, 0.34), OD)               # a cross brace
        lathe(bm, [(0.0, 0.0), (0.024, 0.0), (0.024, 0.006), (0.020, 0.009), (0.0, 0.010)], 20, CAP,
              matrix=along((x, 0.0, zr + 0.08), (x, 0.0, zr + 1.0)))
    k.part('legs', bm, bevel=B_METAL)

    bm = bmesh.new()                                   # the spine: a steel beam with rubber notch boards both sides
    box(bm, (-XE, -0.045, zr - 0.017), (XE, 0.045, zr + 0.017), OD)
    for s in (-1, 1):
        b2 = bmesh.new()
        comb(b2, xs, U['rest_w'], -stop - 0.045, -stop, -0.044, zr - U['rest_t'] / 2 + 0.002, zr + U['rest_t'] / 2 - 0.002,
             XE - T4, RUB, RUB)
        if s > 0:
            bmesh.ops.transform(b2, matrix=Rz(180), verts=b2.verts[:])
        me = bpy.data.meshes.new('tmp')
        b2.to_mesh(me)
        b2.free()
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    k.part('spine', bm, bevel=(0.002, 2, 35))

    bm = bmesh.new()                                   # the lock bar over the spine, its hinge, a hasp and a padlock
    zb = zr + 0.055
    box(bm, (-XE + 0.03, -0.012, zb), (XE - 0.03, 0.012, zb + 0.008), P('steel'))
    lathe(bm, [(0.0, 0.0), (0.009, 0.0), (0.009, 0.04), (0.0, 0.04)], 16, P('steel'),
          matrix=along((-XE + 0.01, 0.0, zb + 0.004), (-XE + 1.0, 0.0, zb + 0.004)))
    box(bm, (XE - 0.05, -0.016, zb - 0.03), (XE - 0.03, 0.016, zb + 0.012), P('steel'))       # hasp
    pl = Vector((XE - 0.04, -0.03, zb - 0.045))                                                  # padlock
    box(bm, (pl.x - 0.018, pl.y - 0.008, pl.z - 0.022), (pl.x + 0.018, pl.y + 0.008, pl.z + 0.010), P('brass'))
    path = [Vector((pl.x + 0.011 * math.cos(t), pl.y, pl.z + 0.010 + 0.016 * math.sin(t))) for t in
            (math.pi * kk / 10 for kk in range(11))]
    tube(bm, path, circle2d(0.0032, 12), P('chrome'), caps=(True, True))
    disc(bm, (pl.x, pl.y - 0.0081, pl.z - 0.010), (0, -1, 0), 0.0035, 12, P('dark'))
    k.part('lockbar', bm, bevel=B_FINE)

    bm = bmesh.new()                                   # stencilled end plates between the legs
    for x in (-XE, XE):
        s = 1 if x > 0 else -1
        pts = [(-0.15, 0.36), (0.15, 0.36), (0.07, 0.62), (-0.07, 0.62)]
        slab_yz(bm, pts, x - 0.0015, x + 0.0015, OD)
    quad(bm, [(XE + 0.0016, 0.12, 0.40), (XE + 0.0016, -0.12, 0.40), (XE + 0.0016, -0.12, 0.47),
              (XE + 0.0016, 0.12, 0.47)], P('stencil_armory'), (1, 0, 0))
    k.part('endplates', bm)
    # the stencil faces +x: u runs along -y
    k.regions['stencil_armory'] = ((0, -1 / 0.24, 0, 0.5), (0, 0, 1 / 0.07, -0.40 / 0.07))

    for s, yaw in ((-1, 0.0), (1, 180.0)):
        for x in xs:
            xx = x if s < 0 else -x
            k.slot('long', (xx, s * sy, z0), yaw, focus=(xx, s * (sy + 0.03), z0 + 0.32), radius=0.09)
    k.collide((-XE - T4, -sy - 0.11, 0.0), (XE + T4, sy + 0.11, z0 + 0.045))
    k.collide((-XE - T4, -stop - 0.045, zr - 0.03), (XE + T4, stop + 0.045, zr + 0.08))
    for x in (-XE, XE):
        k.collide((x - T4, -0.10, 0.0), (x + T4, 0.10, zr + 0.08))


# =====================================================================================================================
# 7. Cherry corner rack: five long guns on an arc, butts in a quarter-round tray, leaning into the corner
# =====================================================================================================================
def corner(k):
    """Cherry with tan felt, for a room's corner: a quarter-round plinth and butt tray, side panels along both walls,
    a curved comb, a turned post in the corner."""
    k.label, k.mount = 'Cherry Corner Rack', 'floor'
    k.recentre = False
    U = dict(rest_h=0.50, rest_t=0.035, rest_y=0.15, rest_w=0.080, notch_w=0.066, notch_len=0.17)
    k.kind('long', 'upright', 'Long gun', **U)
    ANG = [-32.0, -16.0, 0.0, 16.0, 32.0]
    RB, z0 = 0.47, 0.06
    RS = RB - U['rest_y']                              # the comb's stops
    zr = z0 + U['rest_h']
    CX, CZ, FELT = P('cherry_x'), P('cherry_z'), P('felt_tan')
    E = 44.0                                           # the wedge's half angle (the walls at 45)

    bm = bmesh.new()
    sector(bm, 0.0, 0.60, -E, E, 0.0, 0.028, CX, 48)
    k.part('plinth', bm, bevel=(0.004, 3, 35))

    # the tray: a ring of pockets, one per slot (radial, notch_w wide, notch_len long)
    bm = bmesh.new()
    sector(bm, RB - U['notch_len'] / 2 - 0.02, RB + U['notch_len'] / 2 + 0.02, -E, E, 0.028, z0 - 0.004, CX, 48)
    sector(bm, RB - U['notch_len'] / 2 - 0.02, RB - U['notch_len'] / 2, -E, E, z0 - 0.004, z0 + 0.045, CX, 48)
    sector(bm, RB + U['notch_len'] / 2, RB + U['notch_len'] / 2 + 0.02, -E, E, z0 - 0.004, z0 + 0.045, CX, 48)
    edges = [-E]
    for a in ANG:
        half = math.degrees(U['notch_w'] / 2 / RB)
        edges += [a - half, a + half]
    edges += [E]
    for a0, a1 in zip(edges[0::2], edges[1::2]):
        sector(bm, RB - U['notch_len'] / 2, RB + U['notch_len'] / 2, a0, a1, z0 - 0.004, z0 + 0.045, CX, 8)
    for a in ANG:
        M = Rz(a) @ T(0, -RB, 0)
        box(bm, (-U['notch_w'] / 2, -U['notch_len'] / 2, z0 - 0.004), (U['notch_w'] / 2, U['notch_len'] / 2, z0), FELT, M)
    k.part('tray', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # the comb: an arc of wood, notches open outward, felt stops
    sector(bm, RS - 0.05, RS + 0.003, -E, E, zr - U['rest_t'] / 2, zr + U['rest_t'] / 2, CX, 48)
    edges = [-E]
    for a in ANG:
        half = math.degrees(U['rest_w'] / 2 / (RS + 0.03))
        edges += [a - half, a + half]
    edges += [E]
    for a0, a1 in zip(edges[0::2], edges[1::2]):
        sector(bm, RS + 0.003, RS + 0.055, a0, a1, zr - U['rest_t'] / 2, zr + U['rest_t'] / 2, CX, 6)
    for a in ANG:
        M = Rz(a) @ T(0, -RS, 0)
        box(bm, (-U['rest_w'] / 2, -0.003, zr - U['rest_t'] / 2 + 0.002), (U['rest_w'] / 2, 0.0,
                                                                         zr + U['rest_t'] / 2 - 0.002), FELT, M)
    k.part('comb', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # the side brackets along the walls: a cove up to the comb
    prof = [(0.0, 0.028), (0.20, 0.028)] + ease((0.20, 0.028), (RS + 0.07, zr - 0.06), 16) + \
           [(RS + 0.07, zr + 0.03)] + arc(RS - 0.015, zr + 0.03, 0.085, 0, 90, 10)[1:] + [(0.0, zr + 0.115)]
    for s in (-1, 1):
        # built along -Y (out from the corner), then turned onto its wall; its thickness inside the room
        x0, x1 = (-0.024, 0.0) if s > 0 else (0.0, 0.024)
        slab_yz(bm, [(-u, z) for u, z in reversed(prof)], x0, x1, CZ, Rz(s * 45.0))
    k.part('panels', bm, bevel=B_WOOD)

    bm = bmesh.new()                                   # the turned post in the corner
    lathe(bm, [(0.0, 0.0), (0.035, 0.0), (0.035, 0.03), (0.026, 0.05), (0.022, 0.30), (0.030, 0.33), (0.022, 0.36),
               (0.020, zr + 0.10), (0.028, zr + 0.13), (0.020, zr + 0.16), (0.0, zr + 0.17)], 40, CZ,
          matrix=T(0.0, -0.06, 0.0))
    k.part('post', bm)

    for a in ANG:
        r = math.radians(a)
        pos = (RB * math.sin(r), -RB * math.cos(r), z0)
        fo = ((RB + 0.03) * math.sin(r), -(RB + 0.03) * math.cos(r), z0 + 0.30)
        k.slot('long', pos, a, focus=fo, radius=0.09)
    k.collide((-0.43, -0.62, 0.0), (0.43, 0.0, z0 + 0.045))
    k.collide((-0.30, -RS - 0.06, zr - 0.02), (0.30, -0.10, zr + 0.02))


# =====================================================================================================================
# 8. Pistol stand: five handguns muzzle-down on rubber-dipped posts (a table-top piece)
# =====================================================================================================================
def stand(k):
    """A black steel base 0.42 x 0.17 m with a rubber deck, five rubber-dipped posts with chrome collars, rubber feet,
    a chrome plate on the front."""
    k.label, k.mount, k.col_mat = 'Pistol Stand', 'surface', 'METAL_SOLID_SMALL'
    G = dict(gap=0.030, height=0.085, clear=0.003, max_len=0.36)
    k.kind('pistol', 'post', 'Handgun', **G)
    k.tex = dict(bake=1024, d=1024, n=512, s=256, ao=0.02)
    k.budget = (3000, 20000)
    k.lod_dist = 40.0
    xs = [(i - 2) * 0.08 for i in range(5)]
    py = 0.03
    deck = 0.019

    bm = bmesh.new()
    prism(bm, rect2d(0.42, 0.17, 0.02, 4), 0.004, 0.015, P('coat_black'))
    prism(bm, rect2d(0.40, 0.15, 0.012, 4), 0.015, deck, P('rubber'))
    k.part('base', bm, bevel=B_FINE)

    bm = bmesh.new()
    for x in xs:
        rod(bm, (x, py, deck - 0.002), (x, py, deck + G['height']), 0.0045, P('rubber'), 16, ends=(None, 'ball'))
        lathe(bm, [(0.0, 0.0), (0.010, 0.0), (0.010, 0.004), (0.007, 0.007), (0.0045, 0.008)], 20, P('chrome'),
              matrix=T(x, py, deck))
    for x in (-0.18, 0.18):
        for y in (-0.06, 0.06):
            lathe(bm, [(0.0, 0.0), (0.012, 0.0), (0.012, 0.004), (0.0, 0.004)], 16, P('rubber'), matrix=T(x, y, 0.0))
    k.part('posts', bm)

    bm = bmesh.new()
    yf = -0.085
    box(bm, (-0.05, yf - 0.0012, 0.006), (0.05, yf + 0.0002, 0.0135), P('chrome'))
    quad(bm, [(-0.048, yf - 0.0013, 0.0065), (0.048, yf - 0.0013, 0.0065), (0.048, yf - 0.0013, 0.013),
              (-0.048, yf - 0.0013, 0.013)], P('plate_stand'), (0, -1, 0))
    k.plate('plate_stand', -0.048, 0.048, 0.0065, 0.013)
    k.part('plate', bm)

    for x in xs:
        k.slot('pistol', (x, py, deck), 0.0, focus=(x, py - 0.05, deck + 0.15), radius=0.06)
    k.collide((-0.21, -0.085, 0.0), (0.21, 0.085, deck))


# =====================================================================================================================
# 9. Industrial pipe rack: four long guns on black iron pipe hooks over weathered boards
# =====================================================================================================================
def pipe(k):
    """Six weathered barn boards 0.96 x 1.30 m, screwed; eight pipe hooks of 3/4" black iron: a floor flange with
    four screws, a nipple out, an elbow up, a short nipple, a cap."""
    k.label, k.mount = 'Industrial Pipe Rack', 'wall'
    R = 0.0135
    H = dict(hooks=(-0.25, 0.25), hook_w=0.030, lip_y=-0.125, lip_h=0.032, muzzle=-1, gap=0.034)   # clear of the flanges
    k.kind('long', 'horizontal', 'Long gun', **H)
    W, BH, GAP, TH = 0.96, 0.212, 0.004, 0.025
    yf = -TH
    BX, IRON = P('barn_x'), P('iron')

    bm = bmesh.new()
    for i in range(6):
        z0 = i * (BH + GAP)
        jitter = (0.004, -0.003, 0.006, -0.002, 0.003, -0.005)[i]
        slab_xz(bm, [(-W / 2 + jitter, z0), (W / 2 + jitter, z0), (W / 2 + jitter, z0 + BH), (-W / 2 + jitter, z0 + BH)],
                yf, 0.0, BX)
    k.part('boards', bm, bevel=(0.004, 2, 35))

    bm = bmesh.new()                                   # screws at the boards' ends
    for i in range(6):
        zc = i * (BH + GAP) + BH / 2
        for x in (-W / 2 + 0.04, W / 2 - 0.04):
            for dz in (-0.05, 0.05):
                screw(bm, (x, yf, zc + dz), (0, -1, 0), 0.0045, IRON, P('dark'))
    k.part('screws', bm)

    rows = [0.27, 0.58, 0.89, 1.20]
    bm = bmesh.new()
    for z in rows:
        zc = z - R
        for hx in H['hooks']:
            # the flange: a disc with a raised hub, four screws
            lathe(bm, [(0.0, 0.0), (0.040, 0.0), (0.040, 0.004), (0.036, 0.007), (0.022, 0.008), (0.020, 0.020),
                       (0.0175, 0.022), (0.0, 0.022)], 40, IRON, matrix=along((hx, yf, zc), (hx, yf - 1, zc)))
            for kk in range(4):
                a = math.radians(45 + 90 * kk)
                screw(bm, (hx + 0.029 * math.cos(a), yf - 0.007, zc + 0.029 * math.sin(a)), (0, -1, 0), 0.004, IRON,
                      P('dark'))
            yv = yf + H['lip_y'] - R                   # the upright's centre line
            re = 0.026                                 # the elbow's bend radius
            rod(bm, (hx, yf - 0.020, zc), (hx, yv + re, zc), R, IRON, 24, ends=(None, None))
            path = [Vector((hx, yv + re - re * math.sin(t), zc + re - re * math.cos(t))) for t in
                    (math.pi / 2 * kk / 8 for kk in range(9))]
            tube(bm, path, circle2d(R + 0.003, 24), IRON, caps=(False, False))
            rod(bm, (hx, yv, zc + re), (hx, yv, z + H['lip_h'] - 0.006), R, IRON, 24, ends=(None, None))
            lathe(bm, [(R + 0.0035, 0.0), (R + 0.0035, 0.012), (R + 0.002, 0.014), (0.0, 0.015)], 24, IRON,
                  matrix=T(hx, yv, z + H['lip_h'] - 0.0115))
            # the fittings' hex shoulders
            for p in ((hx, yf - 0.020, zc),):
                nut(bm, p, (0, -1, 0), 0.036, 0.008, IRON)
    k.part('pipes', bm)

    for z in rows:
        k.slot('long', (0.0, yf, z), 0.0, focus=(0.0, yf - 0.05, z + 0.02), radius=0.13)
    k.collide((-W / 2, yf, 0.0), (W / 2, 0.0, 6 * (BH + GAP)))


# =====================================================================================================================
# 10. Heritage display: one long gun on two brass hooks over a walnut plaque with a leather inlay
# =====================================================================================================================
def heritage(k):
    """A walnut plaque 1.16 x 0.40 m with scooped ends, a raised border, a black leather inlay, two cast brass hooks
    on rosettes, an engraved brass plaque."""
    k.label, k.mount = 'Heritage Display', 'wall'
    H = dict(hooks=(-0.27, 0.27), hook_w=0.026, lip_y=-0.090, lip_h=0.030, muzzle=-1, gap=0.010)
    k.kind('long', 'horizontal', 'Long gun', **H)
    k.tex = dict(bake=2048, d=2048, n=1024, s=512, ao=0.04)
    W, Ht, TH = 1.16, 0.40, 0.028
    yf = -TH - 0.004                                   # the inlay's face (the gun's back rests near it)
    WX = P('walnut_x')

    def shape(w, h, scoop, n=10):
        right = [(w / 2, 0.0)] + ease((w / 2, 0.0), (w / 2 - scoop, h / 2), n) + ease((w / 2 - scoop, h / 2), (w / 2, h), n)
        left = [(-x, z) for x, z in reversed(right)]
        return right + left

    bm = bmesh.new()
    slab_xz(bm, shape(W, Ht, 0.05), -TH, 0.0, WX)
    k.part('plaque', bm, bevel=(0.005, 4, 35))
    bm = bmesh.new()
    slab_xz(bm, shape(W - 0.08, Ht - 0.08, 0.04), -TH - 0.004, -TH, P('leather_black'), T(0, 0, 0.04))
    k.part('inlay', bm, bevel=(0.0015, 2, 35))

    z = 0.25
    bm = bmesh.new()
    for hx in H['hooks']:
        lathe(bm, [(0.0, 0.0), (0.028, 0.0), (0.028, 0.003), (0.024, 0.006), (0.016, 0.008), (0.012, 0.014),
                   (0.0, 0.015)], 40, P('brass'), matrix=along((hx, yf, z - 0.008), (hx, yf - 1, z - 0.008)))
        r = 0.0065
        rod(bm, (hx, yf - 0.010, z - r), (hx, yf + H['lip_y'] + 0.012, z - r), r, P('brass'), 20, ends=(None, None))
        yl = yf + H['lip_y'] - r
        path = [Vector((hx, yl + 0.012 - 0.012 * math.sin(t), z - r + 0.012 - 0.012 * math.cos(t))) for t in
                (math.pi / 2 * kk / 8 for kk in range(9))]
        tube(bm, path, circle2d(r, 20), P('brass'), caps=(False, False))
        rod(bm, (hx, yl, z - r + 0.012), (hx, yl, z + H['lip_h'] - 0.01), r, P('brass'), 20, ends=(None, None))
        lathe(bm, [(0.0, -0.002), (0.006, 0.0), (0.011, 0.006), (0.009, 0.013), (0.0, 0.015)], 20, P('brass'),
              matrix=T(hx, yl, z + H['lip_h'] - 0.012))
    k.part('hooks', bm)

    bm = bmesh.new()
    yp = -TH - 0.004
    box(bm, (-0.10, yp - 0.0015, 0.050), (0.10, yp + 0.0002, 0.085), P('brass'))
    quad(bm, [(-0.097, yp - 0.0016, 0.053), (0.097, yp - 0.0016, 0.053), (0.097, yp - 0.0016, 0.082),
              (-0.097, yp - 0.0016, 0.082)], P('plate_heritage'), (0, -1, 0))
    k.plate('plate_heritage', -0.097, 0.097, 0.053, 0.082)
    for x in (-0.092, 0.092):
        screw(bm, (x, yp - 0.0016, 0.0675), (0, -1, 0), 0.0022, P('brass'), P('dark'))
    k.part('plate', bm)

    k.slot('long', (0.0, yf, z), 0.0, focus=(0.0, yf - 0.05, z + 0.02), radius=0.14)
    k.collide((-W / 2, -TH - 0.004, 0.0), (W / 2, 0.0, Ht))


MODELS = [
    ('sd_gunrack_oak', oak),
    ('sd_gunrack_panel', panel),
    ('sd_gunrack_walnut', walnut),
    ('sd_gunrack_pegboard', pegboard),
    ('sd_gunrack_pistols', pistols),
    ('sd_gunrack_armory', armory),
    ('sd_gunrack_corner', corner),
    ('sd_gunrack_stand', stand),
    ('sd_gunrack_pipe', pipe),
    ('sd_gunrack_heritage', heritage),
]
