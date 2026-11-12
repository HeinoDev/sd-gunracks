"""preview.py -- the racks' bare geometry, quickly, without baking: every builder's parts with their modifiers, each paint a
flat viewport colour, rendered with Workbench from three-quarters front and straight on, back faces culled (as GTA
draws them, so a face wound the wrong way shows as a hole).

In a running Blender (the MCP window):
    import sys; sys.path.insert(0, r'<sd-gunracks>/tools/props'); import preview; preview.run(['sd_gunrack_oak'])
Headless:
    blender -b -P tools/props/preview.py -- sd_gunrack_oak,sd_gunrack_panel
Writes tools/props/cache/preview/<model>.png. Everything it makes lives in a scene of its own ('sdgr_preview').
"""
import importlib
import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import looks  # noqa: E402
import models  # noqa: E402

OUT = os.path.join(HERE, 'cache', 'preview')
SCENE = 'sdgr_preview'

COLOURS = {   # sRGB-ish viewport colours by paint family
    'oak': (0.62, 0.40, 0.19), 'walnut': (0.30, 0.17, 0.09), 'cherry': (0.45, 0.17, 0.10), 'barn': (0.42, 0.37, 0.31),
    'felt_green': (0.08, 0.32, 0.15), 'felt_black': (0.10, 0.10, 0.11), 'felt_tan': (0.62, 0.48, 0.30),
    'felt_red': (0.5, 0.06, 0.08), 'leather': (0.35, 0.18, 0.08), 'leather_black': (0.07, 0.07, 0.07),
    'coat_black': (0.07, 0.07, 0.075), 'coat_od': (0.22, 0.25, 0.14), 'coat_tan': (0.55, 0.45, 0.32),
    'coat_grey': (0.25, 0.26, 0.27), 'pegboard': (0.09, 0.09, 0.095), 'galv': (0.55, 0.56, 0.57),
    'iron': (0.12, 0.12, 0.12), 'steel': (0.45, 0.45, 0.46), 'alu': (0.7, 0.7, 0.72), 'chrome': (0.85, 0.86, 0.88),
    'brass': (0.85, 0.65, 0.25), 'brass_aged': (0.55, 0.42, 0.18), 'rubber': (0.05, 0.05, 0.05),
    'plastic_black': (0.06, 0.06, 0.06), 'diffuser': (0.95, 0.95, 0.92), 'dark': (0.0, 0.0, 0.0),
    'plate': (0.9, 0.75, 0.3), 'stencil': (0.85, 0.85, 0.8),
}


def colour(paint):
    for key, c in COLOURS.items():
        if paint.startswith(key):
            return c
    return (1.0, 0.0, 1.0)


def scene():
    sc = bpy.data.scenes.get(SCENE) or bpy.data.scenes.new(SCENE)
    bpy.context.window.scene = sc if bpy.context.window else sc
    return sc


def paints():
    mats = []
    for name in looks.PAINTS:
        m = bpy.data.materials.get('pv.' + name) or bpy.data.materials.new('pv.' + name)
        m.diffuse_color = (*colour(name), 1.0)
        m.roughness = 0.6
        mats.append(m)
    return mats


def clear(sc):
    for ob in list(sc.objects):
        bpy.data.objects.remove(ob, do_unlink=True)


def build(name, builder, mats):
    k = models.Kit(name, mats)
    builder(k)
    return k


def frame_objects(sc, objs, cam_dir, lens=50.0):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    centre, radius = (lo + hi) / 2, (hi - lo).length / 2
    cam_data = bpy.data.cameras.get('sdgr_cam') or bpy.data.cameras.new('sdgr_cam')
    cam_data.lens = lens
    cam = bpy.data.objects.get('sdgr_cam') or bpy.data.objects.new('sdgr_cam', cam_data)
    if cam.name not in sc.collection.objects:
        sc.collection.objects.link(cam)
    d = Vector(cam_dir).normalized()
    fov = 2 * math.atan(18 / lens)
    cam.location = centre - d * (radius / math.sin(fov / 2) * 1.05)
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    sc.camera = cam


def render(sc, path, size=900):
    sc.render.engine = 'BLENDER_WORKBENCH'
    sh = sc.display.shading
    sh.light = 'STUDIO'
    sh.color_type = 'MATERIAL'
    sh.show_backface_culling = True
    sh.show_cavity = True
    sh.cavity_type = 'BOTH'
    sh.show_shadows = False
    sc.render.resolution_x = sc.render.resolution_y = size
    sc.render.film_transparent = False
    sc.world = sc.world or bpy.data.worlds.new('sdgr_world')
    sc.render.image_settings.file_format = 'PNG'
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True, scene=sc.name)


def run(only=None, views=((0.55, 1.0, -0.42), (0.0, 1.0, -0.08))):
    importlib.reload(looks)
    importlib.reload(models)
    os.makedirs(OUT, exist_ok=True)
    sc = scene()
    mats = paints()
    done = []
    for name, builder in models.MODELS:
        if only and name not in only:
            continue
        clear(sc)
        # Kit.part links into bpy.context.scene: point the context at ours while building
        prev = bpy.context.window.scene if bpy.context.window else None
        if bpy.context.window:
            bpy.context.window.scene = sc
        k = build(name, builder, mats)
        for i, v in enumerate(views):
            frame_objects(sc, k.parts, v)
            path = os.path.join(OUT, f'{name}_{i}.png')
            render(sc, path)
        done.append((name, len(k.parts), len(k.slots)))
        if prev is not None:
            bpy.context.window.scene = prev
    return done


if __name__ == '__main__':
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    print(run(set(args[0].split(',')) if args else None))
