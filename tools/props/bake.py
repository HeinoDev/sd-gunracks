"""Unwrap a finished model and bake its materials (looks.py) into GTA's three maps.

    unwrap(ob)           Smart UV Project into 'UVMap 0' (one non-overlapping layout per model); faces whose
                         paint has its own tiling textures (the radiator core) are left out and keep their UVs
    bake_all(ob, ...)    1. ambient occlusion (64 samples, then blurred): where grime settles
                         2. with that AO feeding every material: albedo, spec, gloss (EMIT bakes) and the tangent-space
                            normal (NORMAL bake of the materials' bump), all at `size` with a 6 px margin
                         returns float arrays, top row first: albedo (linear), spec, gloss, normal (OpenGL, -1..1)
Cycles on the CPU with a fixed thread count, so a game running on the same PC keeps some cores and its GPU.
"""
import math

import bmesh
import bpy
import numpy as np

import looks

THREADS = 16


def unwrap(ob, margin=0.006, angle=62.0):
    exclude = {looks.P(n) for n, r in looks.RECIPES.items() if r.get('tiling')}
    me = ob.data
    if 'UVMap 0' not in me.uv_layers:
        me.uv_layers.new(name='UVMap 0')
    me.uv_layers.active = me.uv_layers['UVMap 0']
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.mode_set(mode='EDIT')
    bm = bmesh.from_edit_mesh(me)
    for f in bm.faces:
        f.select = f.material_index not in exclude
    bmesh.update_edit_mesh(me)
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle), island_margin=margin, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    # the insides of holes are near black and hardly seen: shrink their islands and repack, so the faces people
    # look at get the texels
    from bpy_extras import bmesh_utils
    bm = bmesh.from_edit_mesh(me)
    uv = bm.loops.layers.uv.active
    dark = looks.P('dark')
    shrunk = 0
    for island in bmesh_utils.bmesh_linked_uv_islands(bm, uv):
        if all(f.material_index == dark for f in island):
            loops = [lp for f in island for lp in f.loops]
            cu = sum(lp[uv].uv.x for lp in loops) / len(loops)
            cv = sum(lp[uv].uv.y for lp in loops) / len(loops)
            for lp in loops:
                lp[uv].uv.x = cu + (lp[uv].uv.x - cu) * 0.25
                lp[uv].uv.y = cv + (lp[uv].uv.y - cv) * 0.25
            shrunk += 1
    bmesh.update_edit_mesh(me)
    if shrunk:
        try:
            bpy.ops.uv.select_all(action='SELECT')
            bpy.ops.uv.pack_islands(rotate=True, margin=margin)
        except Exception as err:                 # packing is an improvement, not a requirement
            print('pack_islands skipped:', err)
    bpy.ops.object.mode_set(mode='OBJECT')


def _image(name, size):
    old = bpy.data.images.get(name)
    if old:
        bpy.data.images.remove(old)
    img = bpy.data.images.new(name, size, size, alpha=False, float_buffer=True)
    img.colorspace_settings.name = 'Non-Color'
    return img


def _pixels(img):
    a = np.empty(img.size[0] * img.size[1] * 4, np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(img.size[1], img.size[0], 4)[::-1]          # top row first


def _blur(a, sigma):
    r = int(math.ceil(sigma * 2.5))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    out = a.copy()
    for axis in (0, 1):
        out = sum(np.roll(out, i - r, axis=axis) * k[i] for i in range(len(k)))
    return out


def _scene(samples):
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = THREADS
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    sc.render.bake.margin = 6
    sc.render.bake.margin_type = 'EXTEND'
    sc.render.bake.use_clear = True
    if sc.world is None:
        sc.world = bpy.data.worlds.new('bake')
    return sc


def _bake(ob, kind, samples, **kw):
    _scene(samples)
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.bake(type=kind, use_clear=True, margin=6, margin_type='EXTEND', uv_layer='UVMap 0', **kw)


def bake_all(ob, ctx, size, ao_distance):
    """ctx as looks.build wants it, without 'ao'. Returns dict of arrays."""
    me = ob.data
    for o in bpy.context.scene.objects:          # earlier models and their collision sit at the origin too
        o.hide_render = o is not ob
    used = sorted({p.material_index for p in me.polygons})
    dummy = _image('bake_dummy', 8)
    tiling = {looks.P(n) for n, r in looks.RECIPES.items() if r.get('tiling')}

    def materials(with_ao):
        c = dict(ctx)
        c['ao'] = with_ao
        mats = {}
        for i in used:
            mats[i] = looks.build(looks.PAINTS[i], c)
            me.materials[i] = mats[i]
        return mats

    def point(mats, which, img):
        for i, m in mats.items():
            looks.set_pass(m, which, dummy if i in tiling else img)

    # 1. ambient occlusion
    mats = materials(None)
    ao_img = _image('bake_ao', size)
    point(mats, 'albedo', ao_img)
    bpy.context.scene.world.light_settings.distance = ao_distance
    _bake(ob, 'AO', 64)
    ao = _pixels(ao_img)[:, :, 0]
    ao = _blur(ao, max(1.0, size / 700.0))
    flat = np.ones((size, size, 4), np.float32)
    flat[:, :, 0] = flat[:, :, 1] = flat[:, :, 2] = ao
    ao_img.pixels.foreach_set(flat[::-1].ravel())

    # 2. the maps
    out = {'ao': ao}
    mats = materials(ao_img)
    for which, kind in (('albedo', 'EMIT'), ('spec', 'EMIT'), ('gloss', 'EMIT'), ('normal', 'NORMAL')):
        img = _image('bake_' + which, size)
        point(mats, which, img)
        if kind == 'NORMAL':
            _bake(ob, 'NORMAL', 4, normal_space='TANGENT', normal_r='POS_X', normal_g='POS_Y', normal_b='POS_Z')
            px = _pixels(img)[:, :, :3] * 2.0 - 1.0
        else:
            _bake(ob, 'EMIT', 4)
            px = _pixels(img)[:, :, :3]
        out[which] = px
    return out


def to_srgb(lin):
    lin = np.clip(lin, 0.0, 1.0)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1 / 2.4) - 0.055) * 255.0


def downsample(a, size):
    while a.shape[0] > size:
        a = (a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2]) * 0.25
    return a
