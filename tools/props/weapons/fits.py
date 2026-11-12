"""fits.py -- where each GTA firearm sits in each kind of rack slot, worked out against its real mesh (numpy only).

    import fits
    f = fits.upright(gun, params)      # -> Fit or a refusal string
    f.matrix (4x4, gun model space -> slot frame), f.row() = [px, py, pz, pitch, roll, yaw]

The four kinds of slot, each in its own frame (metres, +Z up, the rack's front is -Y):

  upright     a long gun standing on its butt, leaning back against a rest (floor racks, the walnut wall rack, the
              A-frame). Frame: origin on the floor of the butt notch, in its middle; +Y is back, toward the rest.
              The gun's top (sights) faces back, its magazine and trigger face the room. It leans back until the
              part of it at the rest's height touches the rest's back stop.
  horizontal  a long gun lying on two hooks, its side to the wall, sights up (wall panels). Frame: origin midway
              between the hooks on the line they support at (z = 0), on the wall's face (y = 0); the gun lies in
              -Y. It is slid along the hooks and tipped so it rests on BOTH where the stock and fore-end are solid,
              with its weight between them.
  peg         a handgun slid muzzle-first onto a peg standing out of a board (the barrel over the peg), grip down.
              Frame: origin at the peg's root on the board's face (y = 0); the peg points out along -Y, tipped up.
  post        a handgun standing muzzle-down on a vertical post (the table-top stand), grip toward the room.
              Frame: origin on the stand's deck at the post's foot.

Rotation rows are GTA's rotation order 2 (Blender Euler 'YXZ', x = pitch, y = roll, z = yaw), in degrees: the same
numbers SetEntityRotation / AttachEntityToEntity take with order 2.
"""
import math

import numpy as np

UP = np.array([0.0, 0.0, 1.0])


# ---- rotations -------------------------------------------------------------------------------------------------
def euler_yxz(R):
    """3x3 rotation -> (pitch, roll, yaw) degrees with R = Rz(yaw) @ Rx(pitch) @ Ry(roll)."""
    pitch = math.asin(max(-1.0, min(1.0, R[2, 1])))
    if abs(R[2, 1]) < 0.99999:
        roll = math.atan2(-R[2, 0], R[2, 2])
        yaw = math.atan2(-R[0, 1], R[1, 1])
    else:                                               # (gimbal: fold roll into yaw)
        roll = 0.0
        yaw = math.atan2(R[1, 0], R[0, 0])
    return math.degrees(pitch), math.degrees(roll), math.degrees(yaw)


def matrix_yxz(pitch, roll, yaw):
    p, r, y = (math.radians(a) for a in (pitch, roll, yaw))
    rx = np.array([[1, 0, 0], [0, math.cos(p), -math.sin(p)], [0, math.sin(p), math.cos(p)]])
    ry = np.array([[math.cos(r), 0, math.sin(r)], [0, 1, 0], [-math.sin(r), 0, math.cos(r)]])
    rz = np.array([[math.cos(y), -math.sin(y), 0], [math.sin(y), math.cos(y), 0], [0, 0, 1]])
    return rz @ rx @ ry


def basis(x, z):
    """The rotation taking the gun's +X to `x` and +Z to `z` (Y = Z x X keeps it right-handed)."""
    x = np.asarray(x, float) / np.linalg.norm(x)
    z = np.asarray(z, float)
    z = z - x * x.dot(z)
    z /= np.linalg.norm(z)
    y = np.cross(z, x)
    return np.stack([x, y, z], axis=1)


class Fit:
    def __init__(self, R, t, info=None):
        self.R, self.t, self.info = R, np.asarray(t, float), info or {}

    @property
    def matrix(self):
        m = np.eye(4)
        m[:3, :3] = self.R
        m[:3, 3] = self.t
        return m

    def apply(self, pts):
        return pts @ self.R.T + self.t

    def row(self):
        p, r, y = euler_yxz(self.R)
        return [round(float(v), 4) + 0.0 for v in self.t] + [round(p, 2) + 0.0, round(r, 2) + 0.0, round(y, 2) + 0.0]


def length(gun):
    lo, hi = gun.bbox()
    return float(hi[0] - lo[0])


# ---- upright -------------------------------------------------------------------------------------------------------
UPRIGHT = dict(
    rest_h=0.50,      # the rest's support height over the notch floor (where the gun touches it)
    rest_t=0.035,     # the rest's thickness (the band of the gun that may touch it)
    rest_y=0.15,      # the rest's back stop (y) the gun leans against
    rest_w=0.080,     # the rest notch's width (x): what passes through it must be narrower
    notch_w=0.066,    # the butt notch's width (x)
    notch_len=0.19,   # the butt notch's length (y)
    max_lean=22.0,    # degrees: a gun that has to lean more than this to touch is refused
    min_lean=0.5,     # a gun that already touches standing straighter than this is refused (rest too close)
    reach=0.06,       # how far past the rest's top the gun must go (so it is held, not balanced on it)
)


def upright(gun, P):
    v = gun.points()
    lo, hi = gun.bbox()
    if hi[0] - lo[0] < P['rest_h'] + P['rest_t'] / 2 + P['reach']:
        return 'too short to reach the rest'
    butt = v[v[:, 0] < lo[0] + 0.04]
    cy = (butt[:, 1].min() + butt[:, 1].max()) / 2      # the stock's middle (gun y): centred in the notch's width

    def place(theta):
        th = math.radians(theta)
        R = basis((0.0, math.sin(th), math.cos(th)), (0.0, math.cos(th), -math.sin(th)))
        p = v @ R.T
        t = np.array([-cy, 0.0, -p[:, 2].min()])
        p = p + t
        foot = p[p[:, 2] < 0.05]
        t[1] = -(foot[:, 1].min() + foot[:, 1].max()) / 2
        p[:, 1] += t[1]
        return R, t, p

    def back(theta):
        R, t, p = place(theta)
        band = p[np.abs(p[:, 2] - P['rest_h']) <= P['rest_t'] / 2]
        if not len(band):
            return None, (R, t, p, band)
        return band[:, 1].max() - P['rest_y'], (R, t, p, band)

    f0, _ = back(0.0)
    if f0 is None:
        return 'nothing at the rest height'
    if f0 >= 0:
        return 'touches the rest standing straight'
    a, b = 0.0, P['max_lean']
    fb, _ = back(b)
    if fb is None or fb < 0:
        return 'would lean over %.0f deg' % P['max_lean']
    for _ in range(40):
        m = (a + b) / 2
        fm, _ = back(m)
        if fm is None or fm < 0:
            a = m
        else:
            b = m
    theta = b
    _, (R, t, p, band) = back(theta)
    if theta < P['min_lean']:
        return 'stands too straight (%.1f deg)' % theta
    if np.abs(band[:, 0]).max() > P['rest_w'] / 2 - 0.002:
        return 'too wide for the rest (%.0f mm)' % (np.abs(band[:, 0]).max() * 2000)
    foot = p[p[:, 2] < 0.04]
    if np.abs(foot[:, 0]).max() > P['notch_w'] / 2 - 0.002:
        return 'butt too wide for the notch (%.0f mm)' % (np.abs(foot[:, 0]).max() * 2000)
    if foot[:, 1].max() - foot[:, 1].min() > P['notch_len'] - 0.004:
        return 'butt too long for the notch (%.0f mm)' % ((foot[:, 1].max() - foot[:, 1].min()) * 1000)
    if p[:, 2].max() < P['rest_h'] + P['rest_t'] / 2 + P['reach']:
        return 'does not reach past the rest'
    return Fit(R, t, dict(lean=round(theta, 2), top=round(float(p[:, 2].max()), 3)))


# ---- horizontal ------------------------------------------------------------------------------------------------------
HORIZONTAL = dict(
    hooks=(-0.21, 0.21),  # the hooks' x (frame)
    hook_w=0.030,         # each hook's width along x: the contact patch
    lip_y=-0.100,         # the inside face of the hooks' front lips (y): the gun must lie behind it there
    lip_h=0.030,          # how far the lips rise above the support line
    muzzle=-1,            # -1: muzzle to the left (as seen from the front), +1 to the right
    gap=0.004,            # clearance from the wall's face
    max_tilt=7.0,         # degrees the gun may tip along its length to rest on both hooks
    min_len=None,         # shortest gun (default: hooks span + 0.10)
)


def _com(gun, R, shift):
    """The gun's centre of mass, near enough: the area-weighted centre of its triangles (after R, then shift)."""
    tri = (gun.verts @ R.T - shift)[gun.tris]
    area = np.linalg.norm(np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]), axis=1)
    return (tri.mean(axis=1) * area[:, None]).sum(0) / max(area.sum(), 1e-9)


def horizontal(gun, P):
    x1, x2 = P['hooks']
    span = x2 - x1
    min_len = P['min_len'] or span + 0.10
    if length(gun) < min_len:
        return 'shorter than the hooks need (%.2f m)' % length(gun)
    if P.get('max_len') and length(gun) > P['max_len']:
        return 'longer than the slot allows (%.2f m)' % length(gun)
    s = P['muzzle']
    R0 = basis((float(s), 0.0, 0.0), (0.0, 0.0, 1.0))
    v = gun.points() @ R0.T
    lo, hi = v.min(0), v.max(0)
    shift = np.array([(lo[0] + hi[0]) / 2, hi[1] + P['gap'], 0.0])
    v = v - shift                                                      # bbox centred on x, its back on the wall
    com = _com(gun, R0, shift)
    hw = P['hook_w'] / 2
    best = None
    reach = P.get('slide', 0.14)
    for x0 in np.arange(-reach, reach + 1e-4, 0.0025 if reach < 0.1 else 0.005):
        bottoms = []
        for xh in (x1, x2):
            col = v[np.abs(v[:, 0] + x0 - xh) <= hw]
            if len(col) < 3:
                bottoms = None
                break
            bottoms.append(col[:, 2].min())
        if bottoms is None:
            continue
        b1, b2 = bottoms
        tilt = math.degrees(math.atan2(b2 - b1, span))           # tip it about y so both rest on z = 0
        if abs(tilt) > P['max_tilt']:
            continue
        cx = com[0] + x0
        if P.get('balance', True) and not (x1 + 0.04 < cx < x2 - 0.04):
            continue                                              # its weight must sit between the hooks
        score = abs(x0) * 4 + abs(tilt) / P['max_tilt'] + abs(cx) * 2
        if best is None or score < best[0]:
            best = (score, x0, tilt, b1, b2)
    if best is None:
        return 'no balanced rest on both hooks'
    _, x0, tilt, b1, b2 = best
    # tip by `tilt` about the y axis through the left hook's contact, then lift so both contacts are on z = 0
    a = math.radians(tilt)
    Ry = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
    pivot = np.array([x1, 0.0, b1])
    p = (v + np.array([x0, 0.0, 0.0]) - pivot) @ Ry.T + pivot
    p[:, 2] -= b1
    cols = [p[np.abs(p[:, 0] - xh) <= hw] for xh in (x1, x2)]
    lift = -min(c[:, 2].min() for c in cols)
    p[:, 2] += lift
    R = Ry @ R0
    t = (np.array([x0, 0.0, 0.0]) - np.array([(lo[0] + hi[0]) / 2, hi[1] + P['gap'], 0.0]) - pivot) @ Ry.T + pivot
    t = t + np.array([0.0, 0.0, -b1 + lift])
    check = gun.points() @ R.T + t
    assert np.abs(check - p).max() < 1e-6
    in_front = [c[(c[:, 1] < P['lip_y'] + 0.002) & (c[:, 2] < P['lip_h'])] for c in cols]
    if any(len(c) for c in in_front):
        return 'rides over a hook lip'
    return Fit(R, t, dict(tilt=round(tilt, 2), shift=round(float(x0), 3), low=round(float(p[:, 2].min()), 3),
                          high=round(float(p[:, 2].max()), 3)))


# ---- peg ---------------------------------------------------------------------------------------------------------------
PEG = dict(
    angle=8.0,       # how far the peg tips up from level (degrees)
    gap=0.030,       # the muzzle's distance from the board, along the peg
    length=0.075,    # the peg's length (it must stay inside the barrel)
    clear=0.003,     # nothing of the gun nearer the board than this
    max_len=0.43,    # longest handgun a peg takes
)


def bore(gun):
    """The barrel's end on the bore line (gun space): the front-most surface within 13 mm of the muzzle bone's line."""
    m = gun.muzzle()
    v = gun.points(0.003)
    near = v[np.hypot(v[:, 1] - m[1], v[:, 2] - m[2]) < 0.013]
    end = near[:, 0].max() if len(near) else v[:, 0].max()
    return np.array([end, m[1], m[2]])


def peg(gun, P):
    if length(gun) > P['max_len']:
        return 'too long for a peg (%.2f m)' % length(gun)
    a = math.radians(P['angle'])
    d = np.array([0.0, -math.cos(a), math.sin(a)])            # the peg, out of the board
    R = basis(-d, (0.0, math.sin(a), math.cos(a)))              # the muzzle into the board, sights up
    tip = bore(gun)
    t = d * P['gap'] - R @ tip
    p = gun.points() @ R.T + t
    # whatever stands proud of the muzzle (a front sight, a frame) keeps the gun further out along the peg
    over = p[:, 1].max() + P['clear']
    out = max(0.0, over / math.cos(a))
    if P['gap'] + out > P['length'] - 0.025:
        return 'would sit off the end of the peg (%.0f mm proud of its muzzle)' % (over * 1000)
    t = t + d * out
    p = p + d * out
    return Fit(R, t, dict(low=round(float(p[:, 2].min()), 3), high=round(float(p[:, 2].max()), 3),
                          out=round(float(-p[:, 1].min()), 3), slid=round(out, 4)))


# ---- post ----------------------------------------------------------------------------------------------------------------
POST = dict(
    gap=0.030,       # the muzzle's height over the deck
    height=0.085,    # the post's height (it must stay inside the barrel: gap + depth available)
    clear=0.003,     # nothing of the gun nearer the deck than this
    max_len=0.36,    # longest handgun a post takes
)


def post(gun, P):
    if length(gun) > P['max_len']:
        return 'too long for a post (%.2f m)' % length(gun)
    R = basis((0.0, 0.0, -1.0), (0.0, 1.0, 0.0))               # muzzle down, sights to the back, grip to the room
    tip = bore(gun)
    t = np.array([0.0, 0.0, P['gap']]) - R @ tip
    p = gun.points() @ R.T + t
    up = max(0.0, P['clear'] - p[:, 2].min())               # (anything below the muzzle lifts it up the post)
    if P['gap'] + up > P['height'] - 0.025:
        return 'would sit off the top of the post (%.0f mm below its muzzle)' % (up * 1000)
    t = t + np.array([0.0, 0.0, up])
    p[:, 2] += up
    return Fit(R, t, dict(high=round(float(p[:, 2].max()), 3), front=round(float(-p[:, 1].min()), 3), lift=round(up, 4)))


# ---- flat ----------------------------------------------------------------------------------------------------------------
FLAT = dict(
    gap=0.012,       # the magnet's thickness: the gun's side rests on its face, this far off the board
    muzzle=-1,       # -1: muzzle to the left (seen from the front)
    max_len=0.33,    # longest handgun a mount takes
)


def flat(gun, P):
    """A handgun lying flat in profile on a magnetic mount: sights up, its slide's middle on the magnet (frame origin)."""
    if length(gun) > P['max_len']:
        return 'too long for the mount (%.2f m)' % length(gun)
    R = basis((float(P['muzzle']), 0.0, 0.0), (0.0, 0.0, 1.0))
    v = gun.points()
    tip = bore(gun)
    top = v[v[:, 2] > tip[2] - 0.006]                         # the slide (and barrel) over the bore line
    mid = np.array([(top[:, 0].min() + tip[0]) / 2, 0.0, tip[2]])
    p = v @ R.T
    t = -(R @ mid)
    t[1] = -(p[:, 1].max() + P['gap'])                         # its side on the magnet's face
    p = p + t
    return Fit(R, t, dict(low=round(float(p[:, 2].min()), 3), high=round(float(p[:, 2].max()), 3),
                          left=round(float(p[:, 0].min()), 3), right=round(float(p[:, 0].max()), 3)))


KINDS = {'upright': (upright, UPRIGHT), 'horizontal': (horizontal, HORIZONTAL), 'peg': (peg, PEG), 'post': (post, POST),
         'flat': (flat, FLAT)}
GROUPS = {
    'upright': ['GROUP_RIFLE', 'GROUP_SHOTGUN', 'GROUP_SNIPER', 'GROUP_MG', 'GROUP_SMG'],
    'horizontal': ['GROUP_RIFLE', 'GROUP_SHOTGUN', 'GROUP_SNIPER', 'GROUP_MG', 'GROUP_SMG'],
    'peg': ['GROUP_PISTOL', 'GROUP_STUNGUN', 'GROUP_SMG'],
    'post': ['GROUP_PISTOL', 'GROUP_STUNGUN', 'GROUP_SMG'],
    'flat': ['GROUP_PISTOL', 'GROUP_STUNGUN', 'GROUP_SMG'],
}


def fit(kind, gun, params):
    fn, base = KINDS[kind]
    P = dict(base)
    P.update(params or {})
    if gun.group not in GROUPS[kind]:
        return 'not a %s weapon' % kind
    return fn(gun, P)


def fallback(kind, fits_by_gun, P):
    """The numbers shared/fit.lua places an unknown (addon) weapon by, from its bounding box only: medians of what the
    real meshes gave, as fractions of their boxes."""
    out = {}
    import guns
    rows = []
    for name, f in fits_by_gun.items():
        g = guns.load(name)
        lo, hi = g.bbox()
        rows.append((g, lo, hi, f))
    if not rows:
        return out
    if kind == 'upright':
        out['lean'] = float(np.median([f.info['lean'] for _, _, _, f in rows]))
    if kind == 'horizontal':
        # where the support line sits up the box, and the tilt: level
        out['rest'] = float(np.median([(-(f.t[2]) - lo[2]) / (hi[2] - lo[2]) if False else
                                       ((0 - (f.apply(np.array([[0, 0, lo[2]]]))[0, 2] - f.apply(np.array([[0, 0, 0]]))[0, 2])) / max(hi[2] - lo[2], 1e-6))
                                       for g, lo, hi, f in rows]))
    if kind in ('peg', 'post'):
        out['bore'] = float(np.median([(bore(g)[2] - lo[2]) / max(hi[2] - lo[2], 1e-6) for g, lo, hi, f in rows]))
    return out
