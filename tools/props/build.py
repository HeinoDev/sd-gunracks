"""build.py -- builds every sd_gunrack_* model and writes the resource's stream/ and data/racks.json.

    blender -b -P tools/props/build.py [-- options]

(NOT --factory-startup: the Sollumz extension must load.) Options after `--`:
    only=sd_gunrack_oak,sd_gunrack_panel   build just those (stream/ and racks.json keep the others' last build)
    bake=512                               bake small, to iterate on a look quickly
    nofit                                  skip fitting the weapons (keeps racks.json's last fits for the racks built)

Before it: `python tools/props/pictures.py` (the plates), `node tools/props/textures/fetch.mjs` (the photographs, once),
and the weapon table and meshes (tools/props/readme.md, "The weapons").

Per rack:
  1. models.py builds its parts; they are merged into one mesh (modifiers applied), sharp edges by angle, then weighted
     normals (face area) so bevelled flats shade flat and the bevels catch the light.
  2. bake.py unwraps it (Smart UV Project) and bakes its looks.py materials: AO, then albedo, spec, gloss and the
     tangent-space normal. dds.py writes them: <name>_d DXT1, <name>_n BC5 (ATI2), <name>_s DXT5 (sqrt(spec) in RGB,
     gloss in alpha), embedded in the .ydr.
  3. The origin is moved where the contract (docs/contract.md) says: a floor or surface rack's to its footprint's
     middle on the floor, a wall rack's to its bottom-centre on the wall (y untouched), the corner rack's stays its
     corner. Its slots and collision boxes move with it.
  4. Every firearm in tools/props/cache/weapons.json is fitted into every kind of slot the rack has (weapons/fits.py,
     against the gun's real mesh), then checked against THIS rack's mesh at every slot of that kind: a fit whose gun
     goes more than PIERCE into the rack anywhere is dropped (reported with how deep and where).
  5. One normal_spec.sps material, a medium LOD (Decimate), box collision; Sollumz exports it GEN8 native and makes
     its archetype. Then the ytyp (Sollumz export_ytyp_io), data/racks.json and tools/props/cache/build_report.json.
"""
import importlib
import json
import math
import os
import sys
import time
import traceback

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
for p in (HERE, os.path.join(HERE, 'weapons')):
    if p not in sys.path:
        sys.path.insert(0, p)

import bake  # noqa: E402
import dds  # noqa: E402
import fits  # noqa: E402
import guns  # noqa: E402
import jsonfmt  # noqa: E402
import looks  # noqa: E402
import models  # noqa: E402
import zones  # noqa: E402

RESOURCE = os.path.dirname(os.path.dirname(HERE))  # sd-gunracks (this file is tools/props/build.py)
STREAM = os.path.join(RESOURCE, 'stream')
DATA = os.path.join(RESOURCE, 'data')
CACHE = os.path.join(HERE, 'cache')
TEX = os.path.join(CACHE, 'tex')
PICTURES = os.path.join(HERE, 'textures', 'pictures')
SZ = 'bl_ext.user_default.sollumz'
YTYP = 'sd_gunracks'
SPEC_MULT, FALLOFF, BUMPINESS = 1.0, 100.0, 1.0
PIERCE = 0.004            # how far a fitted gun may sink into the rack's surface (felt, rubber, a contact) before it is
                          # a clash
SAMPLE = 0.008            # the gun's surface sampled this fine for the clash check
SERVER_BUILD_PACKS_AFTER = ('mp2024_02',)   # DLC packs newer than b3258 (the server's build): not fitted
MAX_LEN = 1.5             # longer than this is a broken model (a stray vertex), not a gun


def sz(path):
    return importlib.import_module(SZ + '.' + path)


def check_sollumz():
    try:
        importlib.import_module(SZ)
        bpy.ops.sollumz.export_assets.get_rna_type()
        bpy.ops.sollumz.converttodrawable.get_rna_type()
    except Exception as err:
        raise SystemExit(f'Sollumz is not loaded ({err}). Run Blender WITHOUT --factory-startup.')


def wipe():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)


def tidy():
    for store in (bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.node_groups):
        for block in list(store):
            if block.users == 0:
                store.remove(block)


def log(*a):
    print(*a, flush=True)


# --- one model --------------------------------------------------------------------------------------------------------
def merge(kit):
    """The kit's parts, modifiers applied, as one object (materials = paint placeholders, index = paint)."""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    bm = bmesh.new()
    kit.part_tris = {}
    for ob in kit.parts:
        me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
        me.transform(ob.matrix_world)
        if ob.matrix_world.determinant() < 0:
            me.flip_normals()
        kit.part_tris[ob.name.split('.', 1)[1]] = sum(len(p.vertices) - 2 for p in me.polygons)
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    for ob in kit.parts:
        bpy.data.objects.remove(ob, do_unlink=True)
    me = bpy.data.meshes.new(kit.name + '.work')
    bm.to_mesh(me)
    bm.free()
    for m in kit.mats:
        me.materials.append(m)
    ob = bpy.data.objects.new(kit.name + '.work', me)
    bpy.context.scene.collection.objects.link(ob)
    me.set_sharp_from_angle(angle=math.radians(30))   # also makes every face smooth
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    wn = ob.modifiers.new('wn', 'WEIGHTED_NORMAL')
    wn.keep_sharp = True
    wn.weight = 50
    wn.mode = 'FACE_AREA'
    bpy.ops.object.modifier_apply(modifier=wn.name)
    return ob


def load_dds(path, data):
    img = bpy.data.images.load(path)
    img.name = os.path.basename(path)            # Sollumz names an embedded texture after the image file
    img.colorspace_settings.name = 'Non-Color' if data else 'sRGB'
    img.pack()
    return img


def gta_material(name, d, n, s):
    mat = sz('ydr.shader_materials').create_shader('normal_spec.sps')
    mat.name = name
    nt = mat.node_tree
    for node_name, img in (('DiffuseSampler', d), ('BumpSampler', n), ('SpecSampler', s)):
        node = nt.nodes[node_name]
        node.image = img
        node.texture_properties.embedded = True
    nt.nodes['bumpiness'].set('X', BUMPINESS)
    nt.nodes['specularIntensityMult'].set('X', SPEC_MULT)
    nt.nodes['specularFalloffMult'].set('X', FALLOFF)
    nt.nodes.active = nt.nodes['DiffuseSampler']
    return mat


def save_png(path, rgb):
    h, w, _ = rgb.shape
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=False)
    px = np.ones((h, w, 4), np.float32)
    px[:, :, :3] = np.clip(rgb, 0, 255)[::-1] / 255.0
    img.pixels.foreach_set(px.ravel())
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()
    bpy.data.images.remove(img)


def write_maps(name, maps, cfg):
    """The baked arrays as the three DDS files; returns their paths."""
    d = bake.downsample(maps['albedo'], cfg['d'])
    n = bake.downsample(maps['normal'], cfg['n'])
    sp = bake.downsample(maps['spec'][:, :, 0], cfg['s'])
    gl = bake.downsample(maps['gloss'][:, :, 0], cfg['s'])
    paths = {k: os.path.join(TEX, f'{name}_{k}.dds') for k in 'dns'}
    dds.write_bc1(paths['d'], bake.to_srgb(d))
    dds.write_bc5(paths['n'], n)
    spec = np.zeros(sp.shape + (4,), np.float32)
    spec[:, :, :3] = (np.sqrt(np.clip(sp, 0, 1)) * 255.0)[:, :, None]
    spec[:, :, 3] = np.clip(gl, 0, 1) * 255.0
    dds.write_bc3(paths['s'], spec)
    save_png(os.path.join(TEX, f'{name}_d.png'), bake.to_srgb(d))
    save_png(os.path.join(TEX, f'{name}_n.png'), (n * 0.5 + 0.5) * 255.0)
    save_png(os.path.join(TEX, f'{name}_s.png'), np.stack([np.sqrt(np.clip(sp, 0, 1)) * 255, gl * 255, gl * 0], axis=2))
    return paths


def make_lod(ob, ratio):
    tmp = bpy.data.objects.new(ob.name + '.lodsrc', ob.data.copy())
    bpy.context.scene.collection.objects.link(tmp)
    m = tmp.modifiers.new('dec', 'DECIMATE')
    m.decimate_type = 'COLLAPSE'
    m.ratio = ratio
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    lod = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
    lod.name = ob.name + '.medium'
    src = tmp.data
    bpy.data.objects.remove(tmp, do_unlink=True)
    bpy.data.meshes.remove(src)
    return lod


def add_collision(drawable, boxes, material, name):
    SollumType = sz('sollumz_properties').SollumType
    cm = sz('ybn.collision_materials')
    mh = sz('tools.meshhelper')
    bh = sz('tools.boundhelper')
    index = {m.name: i for i, m in enumerate(cm.collisionmats)}[material]
    comp = bpy.data.objects.new(name + '.col', None)
    comp.empty_display_size = 0
    comp.sollum_type = SollumType.BOUND_COMPOSITE
    bpy.context.scene.collection.objects.link(comp)
    comp.parent = drawable
    for i, (lo, hi) in enumerate(boxes):
        me = bpy.data.meshes.new(f'{name}.col.{i}')
        mh.create_box_from_extents(me, lo, hi)
        ob = bpy.data.objects.new(me.name, me)
        ob.sollum_type = SollumType.BOUND_BOX
        bpy.context.scene.collection.objects.link(ob)
        ob.parent = comp
        bh.apply_flag_preset(ob, 0)
        mat = cm.create_collision_material_from_index(index)
        mat.name = f'{name}.col_{material.lower()}'
        me.materials.append(mat)


def file_facts(path):
    ok = os.path.isfile(path)
    return {'exists': ok, 'size': os.path.getsize(path) if ok else 0,
            'magic': open(path, 'rb').read(4).decode('latin1') if ok else None}


def r4(v):
    return [round(float(c), 4) + 0.0 for c in v]


# --- the origin ------------------------------------------------------------------------------------------------------
def recentre(kit, ob):
    me = ob.data
    co = np.empty(len(me.vertices) * 3, np.float32)
    me.vertices.foreach_get('co', co)
    co = co.reshape(-1, 3)
    lo, hi = co.min(0), co.max(0)
    if not kit.recentre:
        shift = Vector((0.0, 0.0, 0.0))
    elif kit.mount == 'wall':
        shift = Vector((-(lo[0] + hi[0]) / 2, 0.0, -lo[2]))
    else:
        shift = Vector((-(lo[0] + hi[0]) / 2, -(lo[1] + hi[1]) / 2, -lo[2]))
    me.transform(Matrix.Translation(shift))
    for s in kit.slots:
        s['pos'] = s['pos'] + shift
        s['focus'] = s['focus'] + shift
    kit.collision = [(a + shift, b + shift) for a, b in kit.collision]
    return shift, Vector(lo) + shift, Vector(hi) + shift


# --- the weapons -----------------------------------------------------------------------------------------------------
_points = {}


def gun_points(name):
    if name not in _points:
        g = guns.load(name)
        _points[name] = (g, g.points(SAMPLE))
    return _points[name]


def slot_matrix(s):
    return np.array(Matrix.Translation(s['pos']) @ Matrix.Rotation(math.radians(s['yaw']), 4, 'Z'))


RAYS = [Vector(v).normalized() for v in ((0.31, 0.27, 0.91), (-0.83, 0.41, -0.38), (0.22, -0.95, 0.19))]


def inside(bvh, v, reach=0.25):
    """Is point v inside the rack's solid? Three rays in fixed, unrelated directions vote: inside when the first
    surface a ray meets faces along the ray (it is met from behind). Two of three must agree, so a ray that grazes an
    edge cannot decide it alone (the nearest face's normal on its own misjudges points off edges and corners)."""
    votes = 0
    for d in RAYS:
        hit, hn, _, _ = bvh.ray_cast(v, d, reach)
        if hit is not None and hn.dot(d) > 0:
            votes += 1
    return votes >= 2


def pierce(bvh, pts, lo, hi):
    """How deep the deepest of `pts` lies inside the rack's solid (0 if none), and where."""
    near = pts[np.all((pts > lo - 0.01) & (pts < hi + 0.01), axis=1)]
    worst, where = 0.0, None
    for p in near:
        v = Vector(p)
        loc, nrm, _, dist = bvh.find_nearest(v, 0.05)
        if loc is None or dist <= worst or (v - loc).dot(nrm) >= 0:
            continue
        if inside(bvh, v):
            worst, where = dist, p
    return worst, where


def own_peg(kind, local):
    """The points of a gun that are its own peg's or post's business (the peg runs up the barrel): within 9 mm of
    the slot's peg/post axis. Dropped from the clash check."""
    P = dict(fits.KINDS[kind['type']][1])
    P.update(kind['params'])
    if kind['type'] == 'peg':
        a = math.radians(P['angle'])
        d = np.array([0.0, -math.cos(a), math.sin(a)])
        L = P['length'] + 0.01
    elif kind['type'] == 'post':
        d = np.array([0.0, 0.0, 1.0])
        L = P['height'] + 0.01
    else:
        return np.zeros(len(local), bool)
    t = np.clip(local @ d, 0.0, L)
    return np.linalg.norm(local - t[:, None] * d[None, :], axis=1) < 0.009


def fit_rack(kit, bvh, lo, hi, report):
    """Every firearm into every kind of slot this rack has; checked at every slot of the kind."""
    table = guns.table()
    out = {}
    lo_a, hi_a = np.array(lo), np.array(hi)
    for key, kind in kit.kinds.items():
        slots = [s for s in kit.slots if s['kind'] == key]
        mats = [slot_matrix(s) for s in slots]
        ok, refused = {}, {}
        stats = []
        for name, info in sorted(table.items()):
            if info['pack'].startswith(SERVER_BUILD_PACKS_AFTER):
                continue
            g, pts = gun_points(name)
            lo_g, hi_g = g.bbox()
            if hi_g[0] - lo_g[0] > MAX_LEN:
                continue
            f = fits.fit(kind['type'], g, kind['params'])
            if not isinstance(f, fits.Fit):
                if not f.startswith('not a'):
                    refused[name] = f
                continue
            local = f.apply(pts)
            local = local[~own_peg(kind, local)]
            worst = (0.0, None, None)
            for i, M in enumerate(mats):
                world = local @ M[:3, :3].T + M[:3, 3]
                depth, where = pierce(bvh, world, lo_a, hi_a)
                if depth > worst[0]:
                    worst = (depth, i, where)
            if worst[0] > PIERCE:
                refused[name] = 'clashes with the rack: %.1f mm deep at slot %d (%s)' % (
                    worst[0] * 1000, worst[1] + 1, ', '.join('%.3f' % c for c in worst[2]))
                continue
            ok[name] = f.row()
            stats.append((g, f))
        out[key] = ok
        report['fits'][key] = {'fitted': len(ok), 'refused': refused}
        log(f'  {key}: {len(ok)} fitted, {len(refused)} refused')
        kind['fallback'] = fallback(kind, stats)
    return out


def fallback(kind, stats):
    """The numbers shared/fit.lua places an addon weapon by, from its bounding box: the kind's own parameters, and
    medians of what the real meshes gave (as fractions of their boxes)."""
    P = dict(fits.KINDS[kind['type']][1])
    P.update(kind['params'])
    fb = {k: (list(v) if isinstance(v, tuple) else v) for k, v in P.items() if isinstance(v, (int, float, tuple, list))}
    if not stats:
        return fb
    if kind['type'] == 'upright':
        fb['lean'] = round(float(np.median([f.info['lean'] for _, f in stats])), 2)
        # where the butt's middle sits across the stock's height (gun z, as a fraction of the box)
    if kind['type'] in ('peg', 'post', 'flat'):
        fb['bore'] = round(float(np.median([(fits.bore(g)[2] - g.bbox()[0][2]) / max(1e-6, g.bbox()[1][2] - g.bbox()[0][2])
                                            for g, _ in stats])), 3)
    if kind['type'] == 'horizontal':
        # the support line's height up the gun's box (the rest is level: the median tilt is ~0)
        vals = []
        for g, f in stats:
            lo, hi = g.bbox()
            z_at = f.apply(np.array([[0.0, 0.0, lo[2]]]))[0, 2]       # the box's bottom, after placing
            vals.append(-z_at / max(1e-6, hi[2] - lo[2]))
        fb['rest'] = round(float(np.median(vals)), 3)
    return fb


GROUP_DEFAULT = {
    'upright': ['GROUP_RIFLE', 'GROUP_SHOTGUN', 'GROUP_SNIPER', 'GROUP_MG', 'GROUP_SMG'],
    'horizontal': ['GROUP_RIFLE', 'GROUP_SHOTGUN', 'GROUP_SNIPER', 'GROUP_MG', 'GROUP_SMG'],
    'peg': ['GROUP_PISTOL', 'GROUP_STUNGUN', 'GROUP_SMG'],
    'post': ['GROUP_PISTOL', 'GROUP_STUNGUN', 'GROUP_SMG'],
    'flat': ['GROUP_PISTOL', 'GROUP_STUNGUN', 'GROUP_SMG'],
}


def kind_length(kind):
    t, P = kind['type'], dict(fits.KINDS[kind['type']][1])
    P.update(kind['params'])
    if t == 'upright':
        return [round(P['rest_h'] + P['rest_t'] / 2 + P['reach'], 3), 1.4]
    if t == 'horizontal':
        span = P['hooks'][1] - P['hooks'][0]
        return [round(P.get('min_len') or span + 0.10, 3), round(P.get('max_len') or 1.4, 3)]
    return [0.10, P['max_len']]


# --- one rack ---------------------------------------------------------------------------------------------------------
def build_model(name, builder, paints, pics, report, bake_override, nofit, old):
    t0 = time.time()
    kit = models.Kit(name, paints)
    builder(kit)
    cfg = dict(kit.tex)
    if bake_override:
        cfg['bake'] = bake_override
        for k in 'dns':
            cfg[k] = min(cfg[k], bake_override)
    ob = merge(kit)
    bake.unwrap(ob)
    ctx = {'images': pics, 'regions': kit.regions}
    maps = bake.bake_all(ob, ctx, cfg['bake'], cfg['ao'])
    paths = write_maps(name, maps, cfg)
    t_bake = time.time() - t0

    shift, lo, hi = recentre(kit, ob)
    me = ob.data
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    bpy.context.view_layer.update()
    bvh = BVHTree.FromObject(ob, bpy.context.evaluated_depsgraph_get())
    rep = {'fits': {}}
    if nofit and old and name in old.get('racks', {}):
        fitted = old['racks'][name]['fits']
        for key in kit.kinds:
            kit.kinds[key]['fallback'] = old['racks'][name]['kinds'].get(key, {}).get('fallback', {})
    else:
        fitted = fit_rack(kit, bvh, lo, hi, rep)
    t_fit = time.time() - t0 - t_bake

    atlas = gta_material(name, load_dds(paths['d'], False), load_dds(paths['n'], True), load_dds(paths['s'], True))
    me.polygons.foreach_set('material_index', [0] * len(me.polygons))
    me.materials[0] = atlas
    while len(me.materials) > 1:
        me.materials.pop()
    for attr in ('Color 0', 'Color 1'):        # GTA's shaders read a vertex colour; white = fully lit
        layer = me.color_attributes.new(name=attr, type='BYTE_COLOR', domain='CORNER')
        layer.data.foreach_set('color', [1.0] * (4 * len(layer.data)))
    lod = make_lod(ob, kit.lod_ratio) if kit.lod_ratio else None
    lod_tris = sum(len(p.vertices) - 2 for p in lod.polygons) if lod else 0

    me.name = name
    ob.name = name
    if hasattr(bpy.context.scene, 'auto_create_embedded_col'):
        bpy.context.scene.auto_create_embedded_col = False
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.sollumz.converttodrawable()
    drawable = bpy.data.objects[name]
    model = next(c for c in drawable.children if c.sollum_type == 'sollumz_drawable_model')
    model.name = name + '.model'
    if lod is not None:
        LODLevel = sz('sollumz_properties').LODLevel
        model.sz_lods.get_lod(LODLevel.MEDIUM).mesh = lod
        drawable.drawable_properties.lod_dist_high = 12.0
        drawable.drawable_properties.lod_dist_med = 9998.0
    add_collision(drawable, kit.collision or [(lo.copy(), hi.copy())], kit.col_mat, name)

    bpy.ops.object.select_all(action='DESELECT')
    for o in [drawable] + list(drawable.children_recursive):
        o.select_set(True)
    bpy.context.view_layer.objects.active = drawable
    bpy.ops.sollumz.export_assets(directory=STREAM, target_formats={'NATIVE'}, target_versions={'GEN8'},
                                  limit_to_selected=True, apply_transforms=True, direct_export=True,
                                  use_custom_settings=True)
    bpy.ops.object.select_all(action='DESELECT')
    drawable.select_set(True)
    bpy.context.view_layer.objects.active = drawable
    bpy.ops.sollumz.createarchetypefromselected()
    sc = bpy.context.scene
    arch = sc.ytyps[sc.ytyp_index].archetypes[-1]
    arch.lod_dist = kit.lod_dist

    facts = file_facts(os.path.join(STREAM, name + '.ydr'))
    lo_b, hi_b = kit.budget
    report['models'][name] = dict(rep, tris=tris, lod_tris=lod_tris, budget=kit.budget, within_budget=lo_b <= tris <= hi_b,
                                  part_tris=kit.part_tris,
                                  textures={k: [os.path.basename(p), os.path.getsize(p)] for k, p in paths.items()},
                                  min=r4(lo), max=r4(hi), shift=r4(shift), file=facts,
                                  seconds=round(time.time() - t0, 1), bake_seconds=round(t_bake, 1),
                                  fit_seconds=round(t_fit, 1))
    entry = {
        'label': kit.label, 'mount': kit.mount, 'corner': not kit.recentre or None,
        'min': r4(lo), 'max': r4(hi),
        'slots': [{'kind': s['kind'], 'pos': r4(s['pos']), 'yaw': round(s['yaw'], 2), 'focus': r4(s['focus']),
                   'radius': s['radius']} for s in kit.slots],
        'kinds': {key: {'type': k['type'], 'label': k['label'], 'groups': k.get('groups') or GROUP_DEFAULT[k['type']],
                        'length': kind_length(k), 'fallback': k.get('fallback', {})} for key, k in kit.kinds.items()},
        'fits': fitted,
    }
    if entry['corner'] is None:
        del entry['corner']
    tidy()
    return entry



def main():
    only, bake_override, nofit = set(), None, False
    if '--' in sys.argv:
        for arg in sys.argv[sys.argv.index('--') + 1:]:
            if arg.startswith('only='):
                only = {n for n in arg[5:].split(',') if n}
            elif arg.startswith('bake='):
                bake_override = int(arg[5:])
            elif arg == 'nofit':
                nofit = True
    check_sollumz()
    wipe()
    for d in (STREAM, DATA, TEX):
        os.makedirs(d, exist_ok=True)
    racks_path = os.path.join(DATA, 'racks.json')
    old = json.load(open(racks_path, encoding='utf-8')) if os.path.exists(racks_path) else None
    report = {'ok': False, 'models': {}, 'files': {}}
    out = {
        '_about': 'sd-gunracks rack data (GENERATED by tools/props/build.py; see docs/contract.md). Metres, each rack '
                  'in its own space (+Z up, front -Y). slots: kind (a key of kinds), pos and yaw (degrees about Z) of '
                  'the slot frame, focus and radius of its interaction. fits[kind][WEAPON] = [px, py, pz, pitch, roll, '
                  'yaw]: the weapon object in the slot frame, GTA rotation order 2.',
        'version': 1,
        'racks': dict(old['racks']) if old and only else {},
    }
    try:
        pics = {}
        for paint, r in looks.RECIPES.items():
            if 'image' in r:
                img = bpy.data.images.load(os.path.join(PICTURES, r['image'] + '.png'), check_existing=True)
                img.colorspace_settings.name = 'Non-Color'
                pics[r['image']] = img
                img.use_fake_user = True
        paints = [bpy.data.materials.new('paint.' + n) for n in looks.PAINTS]
        for m in paints:
            m.use_fake_user = True
        sc = bpy.context.scene
        bpy.ops.sollumz.createytyp()
        ytyp = sc.ytyps[sc.ytyp_index]
        ytyp.name = YTYP
        for name, builder in models.MODELS:
            if only and name not in only:
                continue
            log('BUILD', name)
            out['racks'][name] = build_model(name, builder, paints, pics, report, bake_override, nofit, old)
            m = report['models'][name]
            log('BUILT', name, m['tris'], m['lod_tris'], m['seconds'], 's')
        report['archetypes'] = {}
        for a in ytyp.archetypes:
            report['archetypes'][a.name] = {'txd': a.texture_dictionary, 'physics': a.physics_dictionary,
                                            'lod': a.lod_dist, 'type': a.asset_type, 'flags': int(a.flags.total)}
        if not only:
            bpy.ops.sollumz.export_ytyp_io(directory=STREAM, target_formats={'NATIVE'}, target_versions={'GEN8'},
                                           use_custom_settings=True)
            report['files'][YTYP + '.ytyp'] = file_facts(os.path.join(STREAM, YTYP + '.ytyp'))
        for name in report['models']:
            report['files'][name + '.ydr'] = report['models'][name]['file']
        report['ok'] = all(f['exists'] and f['magic'] == 'RSC7' for f in report['files'].values())
        zones.add(out)                         # every slot's interaction box (tools/props/zones.py)
        jsonfmt.write(racks_path, out)
    except Exception:
        report['error'] = traceback.format_exc()
    with open(os.path.join(CACHE, 'build_report.json'), 'w', newline='\n') as f:
        json.dump(report, f, indent=1, default=str)
    log('REPORT', json.dumps({'ok': report['ok'], 'error': report.get('error'),
                              'models': {n: [m['tris'], m['lod_tris'], m['file']['size'],
                                             {k: v['fitted'] for k, v in m['fits'].items()}]
                                         for n, m in report['models'].items()}}, default=str))


if __name__ == '__main__':
    main()
