"""Shape helpers: the bmesh primitives the parts are built from.

`polar` is a lathe whose radius may vary round the turn (for hex heads with chamfers); `disc` is a flat filled
circle. Every face gets a material index `mi`: here that is a paint index (atlas.PAINTS), not a Cycles material.
"""
import math

import bmesh  # noqa: F401  (kept for builders that import * from here)
from mathutils import Matrix, Vector

TAU = math.tau
UP = Vector((0.0, 0.0, 1.0))


def V(*a):
    return Vector(a)


def ring(centre, side, up, w, h, n=32, power=2.0, turn=0.0):
    pts = []
    for k in range(n):
        a = TAU * k / n + turn
        ca, sa = math.cos(a), math.sin(a)
        x = w * math.copysign(abs(ca) ** (2.0 / power), ca)
        y = h * math.copysign(abs(sa) ** (2.0 / power), sa)
        pts.append(centre + side * x + up * y)
    return pts


def skin(bm, rings, mi=0, closed=True, caps=(True, True), smooth=True, wrap=False):
    verts = [[bm.verts.new(p) for p in r] for r in rings]
    n = len(verts[0])
    faces = []
    span = len(verts) if wrap else len(verts) - 1
    for i in range(span):
        a, b = verts[i], verts[(i + 1) % len(verts)]
        for k in range(n if closed else n - 1):
            j = (k + 1) % n
            f = bm.faces.new((a[k], a[j], b[j], b[k]))
            f.material_index = mi
            f.smooth = smooth
            faces.append(f)
    if closed and not wrap:
        if caps[0]:
            f = bm.faces.new(list(reversed(verts[0])))
            f.material_index = mi
            faces.append(f)
        if caps[1]:
            f = bm.faces.new(verts[-1])
            f.material_index = mi
            faces.append(f)
    return faces


def lathe(bm, profile, segs=64, mi=0, a0=0.0, a1=TAU, matrix=None, smooth=True, mis=None):
    """A turned part: `profile` (r, z) spun round Z. `mis[i]` (optional) paints the band from point i to i+1."""
    full = abs(a1 - a0 - TAU) < 1e-6
    steps = segs if full else segs + 1
    M = matrix or Matrix.Identity(4)
    cols = []
    for r, z in profile:
        if r < 1e-7:
            v = bm.verts.new(M @ Vector((0, 0, z)))
            cols.append([v] * steps)
        else:
            col = []
            for k in range(steps):
                a = a0 + (a1 - a0) * k / segs
                col.append(bm.verts.new(M @ Vector((r * math.cos(a), r * math.sin(a), z))))
            cols.append(col)
    faces = []
    for i in range(len(cols) - 1):
        a, b = cols[i], cols[i + 1]
        for k in range(segs):
            j = (k + 1) % steps if full else k + 1
            quad = [a[k], a[j], b[j], b[k]]
            uniq = []
            for v in quad:
                if v not in uniq:
                    uniq.append(v)
            if len(uniq) < 3:
                continue
            f = bm.faces.new(uniq)
            f.material_index = mis[i] if mis else mi
            f.smooth = smooth
            faces.append(f)
    return faces


def frames(path, up_hint=None, closed=False):
    n = len(path)
    out = []
    up = up_hint or UP
    side = None
    for i in range(n):
        if closed:
            t = (path[(i + 1) % n] - path[i - 1]).normalized()
        else:
            t = (path[min(i + 1, n - 1)] - path[max(i - 1, 0)]).normalized()
        if i == 0:
            side = t.cross(up)
            if side.length < 1e-6:
                side = t.cross(Vector((1, 0, 0)))
            side.normalize()
        else:
            side = (side - t * t.dot(side)).normalized()
        out.append((t, side, t.cross(side).normalized()))
    return out


def tube(bm, path, profile, mi=0, closed=False, caps=(True, True), up_hint=None, scale=None, smooth=True):
    rings = []
    for i, (p, (t, side, up)) in enumerate(zip(path, frames(path, up_hint, closed))):
        s = scale[i] if scale else 1.0
        rings.append([p + side * (a * s) + up * (b * s) for a, b in profile])
    return skin(bm, rings, mi, closed=True, caps=caps, wrap=closed, smooth=smooth)


def circle2d(r, n=16):
    return [(r * math.cos(TAU * k / n), r * math.sin(TAU * k / n)) for k in range(n)]


def rect2d(w, h, r=0.0, n=4):
    if r <= 0:
        return [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
    pts = []
    for cx, cy, a in ((w / 2 - r, -h / 2 + r, -90), (w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90),
                      (-w / 2 + r, -h / 2 + r, 180)):
        for k in range(n + 1):
            ang = math.radians(a + 90.0 * k / n)
            pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    return pts


def prism(bm, outline, z0, z1, mi=0, matrix=None, smooth=False, caps=(True, True), side_mi=None):
    M = matrix or Matrix.Identity(4)
    lo = [bm.verts.new(M @ Vector((x, y, z0))) for x, y in outline]
    hi = [bm.verts.new(M @ Vector((x, y, z1))) for x, y in outline]
    n = len(outline)
    faces = []
    if caps[0]:
        faces.append(bm.faces.new(list(reversed(lo))))
    if caps[1]:
        faces.append(bm.faces.new(hi))
    for f in faces:
        f.material_index = mi
        f.smooth = smooth
    for k in range(n):
        j = (k + 1) % n
        f = bm.faces.new((lo[k], lo[j], hi[j], hi[k]))
        f.material_index = mi if side_mi is None else side_mi
        f.smooth = smooth
        faces.append(f)
    return faces


def box(bm, lo, hi, mi=0, matrix=None):
    if isinstance(mi, Matrix):
        mi, matrix = (matrix or 0), mi
    outline = [(lo[0], lo[1]), (hi[0], lo[1]), (hi[0], hi[1]), (lo[0], hi[1])]
    return prism(bm, outline, lo[2], hi[2], mi, matrix)


def grid(bm, nu, nv, at, mi=0, closed_u=False, smooth=True):
    cols = nu if closed_u else nu + 1
    verts = [[bm.verts.new(at(i / nu, j / nv)) for i in range(cols)] for j in range(nv + 1)]
    faces = []
    for j in range(nv):
        for i in range(nu):
            i2 = (i + 1) % cols
            f = bm.faces.new((verts[j][i], verts[j][i2], verts[j + 1][i2], verts[j + 1][i]))
            f.material_index = mi
            f.smooth = smooth
            faces.append(f)
    return faces


def hexagon(bm, centre, axis, r, length, mi=0, chamfer=True):
    """A hex nut or bolt head on `axis` (r = corner radius)."""
    side = axis.cross(Vector((0, 0, 1)) if abs(axis.z) < 0.9 else Vector((1, 0, 0))).normalized()
    up = axis.cross(side).normalized()
    r0 = ring(centre, side, up, r, r, 6, 2.0, math.pi / 6)
    pts = [r0, [p + axis * length for p in r0]]
    if chamfer:
        top = ring(centre + axis * (length + r * 0.18), side, up, r * 0.82, r * 0.82, 6, 2.0, math.pi / 6)
        pts.append(top)
    return skin(bm, pts, mi, smooth=False)


# ---- additions ---------------------------------------------------------------------------------------

def hex_radius(af, a):
    """Distance from the axis to a hexagon's side at angle `a`, the hexagon `af` across flats, a flat facing a=0."""
    apothem = af / 2
    seg = (a + math.pi / 6) % (math.pi / 3) - math.pi / 6
    return apothem / math.cos(seg)


def polar(bm, rings, segs, mis, matrix=None, smooth=None, cap0=None, cap1=None):
    """Like `lathe`, but every ring is (r_of_angle, z): r_of_angle(a) -> radius, so a ring can be a hexagon, a
    circle, or a hexagon clipped by a circle (a chamfered nut). mis[i] paints band i; smooth[i] (default all
    True) smooths it. cap0/cap1 = paint of a flat face closing the first/last ring (None = open)."""
    M = matrix or Matrix.Identity(4)
    angles = [TAU * k / segs for k in range(segs)]
    cols = []
    for rf, z in rings:
        col = []
        for a in angles:
            r = rf(a) if callable(rf) else rf
            col.append(bm.verts.new(M @ Vector((r * math.cos(a), r * math.sin(a), z))))
        cols.append(col)
    def prism_band(i):
        # a hex body: both rings follow the same non-round outline, so the band is flat sides; shade it flat, which
        # also keeps a chamfer's smoothing from bleeding into the flats
        r0, r1 = rings[i][0], rings[i + 1][0]
        if not (callable(r0) and callable(r1)):
            return False
        samples = [TAU * k / 24 for k in range(24)]
        same = all(abs(r0(a) - r1(a)) < 1e-9 for a in samples)
        round_ = max(r0(a) for a in samples) - min(r0(a) for a in samples) < 1e-7
        return same and not round_

    hard = bm.faces.layers.int.get('hardflat') or bm.faces.layers.int.new('hardflat')
    faces = []
    for i in range(len(cols) - 1):
        a, b = cols[i], cols[i + 1]
        flat = prism_band(i)
        for k in range(segs):
            j = (k + 1) % segs
            f = bm.faces.new((a[k], a[j], b[j], b[k]))
            f.material_index = mis[i]
            f.smooth = (True if smooth is None else smooth[i]) and not flat
            if flat:
                f[hard] = 1                     # build.merge keeps these flat after smoothing by angle
            faces.append(f)
    if cap0 is not None:
        f = bm.faces.new(list(reversed(cols[0])))
        f.material_index = cap0
        f.smooth = False
        faces.append(f)
    if cap1 is not None:
        f = bm.faces.new(cols[-1])
        f.material_index = cap1
        f.smooth = False
        faces.append(f)
    return faces


def disc(bm, centre, normal, r, segs=12, mi=0):
    """A flat filled circle facing `normal`."""
    n = Vector(normal).normalized()
    side = n.cross(Vector((0, 0, 1)) if abs(n.z) < 0.9 else Vector((1, 0, 0))).normalized()
    up = n.cross(side).normalized()
    pts = [Vector(centre) + side * (r * math.cos(TAU * k / segs)) + up * (r * math.sin(TAU * k / segs))
           for k in range(segs)]
    f = bm.faces.new([bm.verts.new(p) for p in pts])
    f.material_index = mi
    f.smooth = False
    f.normal_update()
    if f.normal.dot(n) < 0:
        f.normal_flip()
    return [f]


def quad(bm, pts, mi, normal, smooth=False):
    """One flat face through `pts`, turned to face `normal`."""
    f = bm.faces.new([bm.verts.new(Vector(p)) for p in pts])
    f.material_index = mi
    f.smooth = smooth
    f.normal_update()
    if f.normal.dot(Vector(normal)) < 0:
        f.normal_flip()
    return f
