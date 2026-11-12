"""verify.py -- looks at what build.py shipped: every rack's .ydr re-imported from stream/ (Sollumz, native), loaded
with the game's own weapons (the GTA_WEAPONS XML, see weapons/guns.py; their default magazine/scope placed on their
bones) at the very transforms data/racks.json gives, rendered in Cycles. Also writes the inventory pictures.

    blender -b -P tools/props/verify.py [-- only=...] [-- icons]

Optional: VANILLA_LIB names a folder holding vanilla_lib.py, whose Sollumz palette-tint patch (Blender 5.x) and preview
material fix let the weapons render with their tint. Without it the renders still run, the tinted parts untinted.

Writes tools/props/cache/verify/<rack>_{loaded,front}.png and, with `icons`, images/<item>.png (256 px, transparent:
the rack with a few guns in it, as ox_inventory shows items). A gun is drawn as the game does with CreateWeaponObject:
its own model plus its default components; which gun goes in which slot is picked to show the range a rack takes.
"""
import importlib
import json
import math
import os
import sys

import bpy
from mathutils import Euler, Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
for p in (HERE, os.path.join(HERE, 'weapons'), os.environ.get('VANILLA_LIB')):
    if p and p not in sys.path:
        sys.path.insert(0, p)

import guns  # noqa: E402

RESOURCE = os.path.dirname(os.path.dirname(HERE))
STREAM = os.path.join(RESOURCE, 'stream')
IMAGES = os.path.join(RESOURCE, 'images')
OUT = os.path.join(HERE, 'cache', 'verify')
STUDIO = os.path.join(HERE, 'textures', 'maps', 'studio.hdr')
WEAPON_XML = str(guns.models_dir())
SZ = 'bl_ext.user_default.sollumz'

# the guns shown, in order of preference, per kind of slot (the first ones that fit are used, cycling)
SHOW = {
    'upright': ['WEAPON_PUMPSHOTGUN', 'WEAPON_ASSAULTRIFLE', 'WEAPON_CARBINERIFLE', 'WEAPON_SNIPERRIFLE',
                'WEAPON_SPECIALCARBINE', 'WEAPON_HEAVYSNIPER', 'WEAPON_SMG', 'WEAPON_MUSKET', 'WEAPON_BULLPUPRIFLE',
                'WEAPON_MARKSMANRIFLE', 'WEAPON_COMBATSHOTGUN', 'WEAPON_TACTICALRIFLE'],
    'horizontal': ['WEAPON_SNIPERRIFLE', 'WEAPON_ASSAULTRIFLE', 'WEAPON_PUMPSHOTGUN', 'WEAPON_CARBINERIFLE',
                   'WEAPON_MUSKET', 'WEAPON_SPECIALCARBINE'],
    'peg': ['WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_HEAVYPISTOL', 'WEAPON_PISTOL50', 'WEAPON_REVOLVER',
            'WEAPON_MACHINEPISTOL', 'WEAPON_VINTAGEPISTOL', 'WEAPON_SNSPISTOL'],
    'post': ['WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_HEAVYPISTOL', 'WEAPON_PISTOL50', 'WEAPON_VINTAGEPISTOL'],
    'flat': ['WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_HEAVYPISTOL', 'WEAPON_PISTOL50', 'WEAPON_VINTAGEPISTOL',
             'WEAPON_APPISTOL', 'WEAPON_STUNGUN', 'WEAPON_FLAREGUN'],
}
ITEMS = {
    'sd_gunrack_oak': 'gunrack_oak', 'sd_gunrack_panel': 'gunrack_panel', 'sd_gunrack_walnut': 'gunrack_walnut',
    'sd_gunrack_pegboard': 'gunrack_pegboard', 'sd_gunrack_pistols': 'gunrack_pistols',
    'sd_gunrack_armory': 'gunrack_armory', 'sd_gunrack_corner': 'gunrack_corner', 'sd_gunrack_stand': 'gunrack_stand',
    'sd_gunrack_pipe': 'gunrack_pipe', 'sd_gunrack_heritage': 'gunrack_heritage',
}


def log(*a):
    print(*a, flush=True)


def patch_sollumz():
    try:
        import vanilla_lib
        vanilla_lib._patch_tint(SZ)
        return vanilla_lib
    except Exception as err:          # (only the weapons' palette tint suffers)
        log('tint patch skipped (VANILLA_LIB names the folder holding vanilla_lib.py):', err)
        return None


def import_file(directory, filename):
    before = set(bpy.data.objects)
    try:
        bpy.ops.sollumz.import_assets(directory=directory, files=[{'name': filename}])
    except Exception as err:
        log('IMPORT_WARN', filename, err)
    return [o for o in bpy.data.objects if o not in before]


def library(name):
    """The collection holding model `name` (imported once, excluded from the view layer, instanced where it is used)."""
    cn = 'L_' + name
    c = bpy.data.collections.get(cn)
    if c is not None:
        return c
    new = import_file(WEAPON_XML, name + '.ydr.xml')
    c = bpy.data.collections.new(cn)
    lib = bpy.data.collections.get('_LIB') or bpy.data.collections.new('_LIB')
    if lib.name not in bpy.context.scene.collection.children:
        bpy.context.scene.collection.children.link(lib)
    lib.children.link(c)
    for o in new:
        st = str(getattr(o, 'sollum_type', '')).lower()
        if 'bound' in st or o.name.lower().endswith('.col'):
            bpy.data.objects.remove(o, do_unlink=True)
            continue
        for uc in list(o.users_collection):
            uc.objects.unlink(o)
        c.objects.link(o)
    lc = bpy.context.view_layer.layer_collection.children.get('_LIB')
    if lc is not None:
        lc.exclude = True
    vl = sys.modules.get('vanilla_lib')
    if vl:
        vl.fix_preview_materials(list(c.objects))
    return c


def instance(coll, matrix, parent_coll):
    e = bpy.data.objects.new('I_' + coll.name, None)
    e.instance_type = 'COLLECTION'
    e.instance_collection = coll
    e.matrix_world = matrix
    parent_coll.objects.link(e)
    return e


def component_matrices(name):
    """(component model, 4x4 in the gun's space) for the default components, as guns.load places them."""
    info = guns.table()[name]
    _, _, bs = guns._read(info['model'])
    out = []
    for c in info['components']:
        if not c['model'].startswith('w_') or not (guns.models_dir() / f"{c['model']}.ydr.xml").exists():
            continue
        on = bs.get((c['bone'] or '').lower())
        if on is None:
            continue
        _, _, cb = guns._read(c['model'])
        own = cb.get((c['attach'] or '').lower())
        import numpy as np
        m = on @ np.linalg.inv(own if own is not None else np.eye(4))
        out.append((c['model'], Matrix(m.tolist())))
    return out


def place_gun(name, matrix, coll):
    info = guns.table()[name]
    instance(library(info['model']), matrix, coll)
    for model, m in component_matrices(name):
        instance(library(model), matrix @ m, coll)


def row_matrix(row):
    px, py, pz, pitch, roll, yaw = row
    rot = Euler((math.radians(pitch), math.radians(roll), math.radians(yaw)), 'YXZ').to_matrix().to_4x4()
    return Matrix.Translation((px, py, pz)) @ rot


def slot_matrix(s):
    return Matrix.Translation(s['pos']) @ Matrix.Rotation(math.radians(s['yaw']), 4, 'Z')


def studio(sc):
    w = sc.world or bpy.data.worlds.new('verify')
    sc.world = w
    w.use_nodes = True
    nt = w.node_tree
    env = nt.nodes.get('ENV') or nt.nodes.new('ShaderNodeTexEnvironment')
    env.name = 'ENV'
    if os.path.exists(STUDIO):
        env.image = bpy.data.images.load(STUDIO, check_existing=True)
    bg = nt.nodes['Background']
    nt.links.new(env.outputs['Color'], bg.inputs['Color'])
    bg.inputs['Strength'].default_value = 1.0


def camera(sc, objs, direction, lens=50.0, pad=1.06):
    pts = []
    for o in objs:
        if o.instance_type == 'COLLECTION' and o.instance_collection:
            for c in o.instance_collection.all_objects:
                if c.type == 'MESH':
                    pts += [o.matrix_world @ c.matrix_world @ Vector(b) for b in c.bound_box]
        elif o.type == 'MESH':
            pts += [o.matrix_world @ Vector(b) for b in o.bound_box]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    centre, radius = (lo + hi) / 2, (hi - lo).length / 2
    cd = bpy.data.cameras.get('vcam') or bpy.data.cameras.new('vcam')
    cd.lens = lens
    cam = bpy.data.objects.get('vcam') or bpy.data.objects.new('vcam', cd)
    if cam.name not in sc.collection.objects:
        sc.collection.objects.link(cam)
    d = Vector(direction).normalized()
    fov = 2 * math.atan(18 / lens)
    cam.location = centre - d * (radius / math.sin(fov / 2) * pad)
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    sc.camera = cam


def render(sc, path, size, samples=64, transparent=False):
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = 16
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.render.resolution_x = sc.render.resolution_y = size
    sc.render.film_transparent = transparent
    sc.view_settings.view_transform = 'Standard'
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA' if transparent else 'RGB'
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main():
    only, icons = set(), False
    if '--' in sys.argv:
        for a in sys.argv[sys.argv.index('--') + 1:]:
            if a.startswith('only='):
                only = set(a[5:].split(','))
            if a == 'icons':
                icons = True
    importlib.import_module(SZ)
    patch_sollumz()
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(IMAGES, exist_ok=True)
    racks = json.load(open(os.path.join(RESOURCE, 'data', 'racks.json'), encoding='utf-8'))['racks']
    sc = bpy.context.scene
    studio(sc)
    for name, rack in racks.items():
        if only and name not in only:
            continue
        log('VERIFY', name)
        scene_coll = bpy.data.collections.new('V_' + name)
        sc.collection.children.link(scene_coll)
        objs = import_file(STREAM, name + '.ydr')
        for o in objs:
            st = str(getattr(o, 'sollum_type', '')).lower()
            if 'bound' in st or '.col' in o.name.lower():
                o.hide_render = True
        shown = {}
        for s in rack['slots']:
            kind = rack['kinds'][s['kind']]
            fitted = rack['fits'].get(s['kind'], {})
            pool = [w for w in SHOW[kind['type']] if w in fitted] or sorted(fitted)
            if not pool:
                continue
            i = shown.get(s['kind'], 0)
            shown[s['kind']] = i + 1
            gun = pool[i % len(pool)]
            place_gun(gun, slot_matrix(s) @ row_matrix(fitted[gun]), scene_coll)
        everything = objs + list(scene_coll.objects)
        wall = rack['mount'] == 'wall'
        camera(sc, everything, (0.55, 1.0, -0.38) if not wall else (0.45, 1.0, -0.22))
        render(sc, os.path.join(OUT, f'{name}_loaded.png'), 1000)
        camera(sc, everything, (0.0, 1.0, -0.05), lens=70)
        render(sc, os.path.join(OUT, f'{name}_front.png'), 1000, samples=48)
        if icons:
            camera(sc, everything, (0.55, 1.0, -0.38) if not wall else (0.40, 1.0, -0.20), pad=1.0)
            render(sc, os.path.join(IMAGES, ITEMS[name] + '.png'), 256, samples=96, transparent=True)
        for o in objs + list(scene_coll.objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.collections.remove(scene_coll)
    log('VERIFY DONE')


if __name__ == '__main__':
    main()
