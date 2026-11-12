"""guns.py -- GTA's weapon models as numpy meshes, read straight from CodeWalker XML (no Blender).

    import guns
    g = guns.load('WEAPON_ASSAULTRIFLE')     # the gun as CreateWeaponObject draws it: body + default components
    g.verts (n, 3) float, g.tris (m, 3) int, in the weapon model's own space (metres; +X toward the muzzle, +Z up)

The XML is CodeWalker XML exported with `vexport`, in the folder the GTA_WEAPONS environment variable names
(<GTA_WEAPONS>/models/<model>.ydr.xml). It is game data and never ships with the resource. Only the high-detail model
is read. A weapon mesh is skinned to its bones, but its vertices are stored in the
model's rest pose, so they are used as they are.

A default component (magazine, a sniper's scope, an Mk II barrel) is a model of its own. The game puts its attach
bone (AAPClip ...) onto the gun's bone of the same job (WAPClip ...): component -> world = gun bone (world) times the
inverse of the component's own attach bone (world, in the component's model).

Meshes are cached as .npz next to the XML (<GTA_WEAPONS>/mesh/), keyed by the XML's size and mtime.
"""
import json
import os
import re
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
WEAPONS_JSON = HERE.parent / 'cache' / 'weapons.json'


def assets():
    """The folder GTA_WEAPONS names, holding models/<model>.ydr.xml (and the mesh/ cache this writes beside it)."""
    root = os.environ.get('GTA_WEAPONS')
    if not root:
        raise RuntimeError(
            "GTA_WEAPONS is not set. Point it at a folder holding the game's weapon models as CodeWalker XML "
            "(models/<model>.ydr.xml), exported with `vexport`. That is game data and never ships with the resource.")
    return Path(root)


def models_dir():
    return assets() / 'models'


_BONE = re.compile(r'<Item>\s*<Name>([^<]+)</Name>.*?<ParentIndex value="(-?\d+)" />.*?'
                   r'<Translation x="([^"]+)" y="([^"]+)" z="([^"]+)" />\s*<Rotation x="([^"]+)" y="([^"]+)" z="([^"]+)" w="([^"]+)" />'
                   r'.*?<Scale x="([^"]+)" y="([^"]+)" z="([^"]+)" />', re.S)


def quat_matrix(x, y, z, w):
    n = x * x + y * y + z * z + w * w
    s = 2.0 / n if n else 0.0
    return np.array([
        [1 - s * (y * y + z * z), s * (x * y - z * w), s * (x * z + y * w)],
        [s * (x * y + z * w), 1 - s * (x * x + z * z), s * (y * z - x * w)],
        [s * (x * z - y * w), s * (y * z + x * w), 1 - s * (x * x + y * y)],
    ])


def bones(xml):
    """{name_lower: 4x4 world matrix (model space)} from the drawable's skeleton."""
    a = xml.find('<Bones>')
    b = xml.find('</Bones>', a)
    if a < 0:
        return {}
    out, mats = {}, []
    for m in _BONE.finditer(xml[a:b]):
        name, parent = m.group(1), int(m.group(2))
        t = [float(v) for v in m.group(3, 4, 5)]
        q = [float(v) for v in m.group(6, 7, 8, 9)]
        local = np.eye(4)
        local[:3, :3] = quat_matrix(*q)
        local[:3, 3] = t
        world = mats[parent] @ local if 0 <= parent < len(mats) else local
        mats.append(world)
        out[name.lower()] = world
    return out


def mesh(xml):
    """The high-detail model's triangles: (verts (n, 3), tris (m, 3))."""
    a = xml.find('<DrawableModelsHigh>')
    b = xml.find('</DrawableModelsHigh>', a)
    if a < 0:
        return np.zeros((0, 3)), np.zeros((0, 3), int)
    part = xml[a:b]
    verts, tris, base = [], [], 0
    for g in re.finditer(r'<VertexBuffer>.*?<Data>(.*?)</Data>.*?<IndexBuffer>\s*<Data>(.*?)</Data>', part, re.S):
        rows = [r.split() for r in g.group(1).strip().split('\n') if r.strip()]
        v = np.array([[float(r[0]), float(r[1]), float(r[2])] for r in rows])
        idx = np.array(g.group(2).split(), dtype=np.int64).reshape(-1, 3)
        verts.append(v)
        tris.append(idx + base)
        base += len(v)
    if not verts:
        return np.zeros((0, 3)), np.zeros((0, 3), int)
    return np.concatenate(verts), np.concatenate(tris)


def _read(model):
    p = models_dir() / f'{model}.ydr.xml'
    mesh_dir = assets() / 'mesh'
    mesh_dir.mkdir(parents=True, exist_ok=True)
    cache = mesh_dir / f'{model}.npz'
    st = p.stat()
    key = np.array([st.st_size, int(st.st_mtime)])
    if cache.exists():
        z = np.load(cache, allow_pickle=True)
        if (z['key'] == key).all():
            return z['verts'], z['tris'], z['bones'].item()
    xml = p.read_text(encoding='utf-8', errors='replace')
    v, t = mesh(xml)
    bs = bones(xml)
    np.savez_compressed(cache, key=key, verts=v, tris=t, bones=np.array(bs, dtype=object))
    return v, t, bs


def sample(verts, tris, spacing):
    """Points on every triangle, at most `spacing` apart along its edges (and through it)."""
    t = verts[tris]
    edge = np.maximum.reduce([np.linalg.norm(t[:, 1] - t[:, 0], axis=1), np.linalg.norm(t[:, 2] - t[:, 1], axis=1),
                              np.linalg.norm(t[:, 0] - t[:, 2], axis=1)])
    n = np.maximum(1, np.ceil(edge / spacing).astype(int))
    out = [verts]
    for k in np.unique(n):
        if k < 2:
            continue
        sel = t[n == k]
        i, j = np.meshgrid(np.arange(k + 1), np.arange(k + 1))
        keep = i + j <= k
        a, b = (i[keep] / k), (j[keep] / k)
        c = 1 - a - b
        pts = sel[:, None, 0] * c[None, :, None] + sel[:, None, 1] * a[None, :, None] + sel[:, None, 2] * b[None, :, None]
        out.append(pts.reshape(-1, 3))
    return np.concatenate(out)


class Gun:
    def __init__(self, name, info, verts, tris, parts, bones):
        self.name, self.info, self.verts, self.tris, self.parts = name, info, verts, tris, parts
        self.bones = bones                     # the body's skeleton: {name_lower: 4x4 world matrix}
        self._cache = {}

    def muzzle(self):
        """The bore's end (the gun_muzzle bone), or the bbox front at mid height when a model has none."""
        m = self.bones.get('gun_muzzle')
        if m is not None:
            return m[:3, 3].copy()
        lo, hi = self.bbox()
        return np.array([hi[0], (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2])

    @property
    def model(self):
        return self.info['model']

    @property
    def group(self):
        return self.info['group']

    def bbox(self):
        return self.verts.min(0), self.verts.max(0)

    def points(self, spacing=0.006):
        """The surface sampled no coarser than `spacing` (vertices, plus a barycentric grid on every triangle): a
        gun's barrel is a few long triangles, so its vertices alone leave whole bands of it empty."""
        key = ('pts', spacing)
        if key not in self._cache:
            self._cache[key] = sample(self.verts, self.tris, spacing)
        return self._cache[key]


_table = None


def table():
    global _table
    if _table is None:
        _table = json.loads(WEAPONS_JSON.read_text(encoding='utf-8'))
    return _table


def load(name):
    """WEAPON_X -> Gun (body + default components, in the body's model space)."""
    info = table()[name]
    v, t, bs = _read(info['model'])
    verts, tris, parts = [v], [t], [(info['model'], len(v), len(t))]
    base = len(v)
    for c in info['components']:
        if not c['model'].startswith('w_') or not (models_dir() / f"{c['model']}.ydr.xml").exists():
            continue
        cv, ct, cb = _read(c['model'])
        if not len(cv):
            continue
        on = bs.get((c['bone'] or '').lower())
        own = cb.get((c['attach'] or '').lower(), np.eye(4))
        if on is None:
            continue
        m = on @ np.linalg.inv(own)
        cv = cv @ m[:3, :3].T + m[:3, 3]
        verts.append(cv)
        tris.append(ct + base)
        parts.append((c['model'], len(cv), len(ct)))
        base += len(cv)
    return Gun(name, info, np.concatenate(verts), np.concatenate(tris), parts, bs)


if __name__ == '__main__':
    import sys
    for n in (sys.argv[1:] or ['WEAPON_ASSAULTRIFLE', 'WEAPON_PUMPSHOTGUN', 'WEAPON_PISTOL']):
        g = load(n)
        lo, hi = g.bbox()
        print(n, g.model, 'parts', g.parts, 'min', np.round(lo, 3), 'max', np.round(hi, 3))
