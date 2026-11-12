"""What the racks are made of: one Cycles material per paint, built from Poly Haven photographs (tools/props/textures/maps,
CC0) and baked by build.py into each rack's own textures. Every material exposes four bake targets the baker switches
the Material Output between:

    albedo   the diffuse colour GTA multiplies its lighting by: the material's colour, broken up by its photograph, with
             grime settled where the baked ambient occlusion says it is enclosed, dust on what faces up, and wear on the
             edges (Cycles' pointiness)
    spec     specular intensity 0..1 (the spec map's red holds its square root: the shader squares it)
    gloss    0..1, the spec map's alpha: specularFalloffMult times this is the highlight's exponent
    normal   the shading normal with the photograph's relief, baked to tangent space

Wood has a direction. A wood paint comes in three: <wood>_x, <wood>_y, <wood>_z, the grain running along that axis of the
rack. Each face takes the photograph projected flat along its own facing (as a box projection), turned so the grain lies
along the part; a face looking along the grain (a sawn end) gets the photograph squeezed to fine rings, a shade darker,
as end grain is. The photographs' grain runs along the image's v (oak, barn) or u (walnut): GRAIN says which.

Photographs are thrown on in the rack's own metres at their real size (Poly Haven's dimensions), so a peg and a panel
share a scale. GTA has no metallic channel: metals are a mid albedo plus strong, tight spec.
"""
import math
import os

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
MAPS = os.path.join(HERE, 'textures', 'maps')

GRAIN = {'oak': 'v', 'barn': 'v', 'walnut': 'u'}       # which image axis each photograph's grain runs along
END_GRAIN = 0.70                                       # a sawn end's brightness against the long grain

# name: recipe. colour = linear albedo; var = how much the photo's lightness varies it; tint = how much of the photo's
# own colour shows; grime = how dirty its recesses get; dust = dust on upward faces; edge = edge wear; bump = (photo
# map, strength, distance m); tile = metres one photo repeat covers; wood = the photograph is grain (makes _x/_y/_z).
BASE = {
    'dark': dict(colour=(0.004, 0.004, 0.004), spec=0.0, gloss=0.1),
    # ---- woods: lacquered, oiled or weathered
    'oak': dict(wood='oak', tile=1.83, colour=(0.40, 0.21, 0.075), var=0.55, tint=0.85,
                bump=('oak_rough', 0.25, 0.0003), spec=0.30, gloss=0.55, grime=0.45, grime_col='dust', dust=0.25,
                edge=0.35, edge_col=(0.55, 0.36, 0.17), edge_spec=0.2),
    'walnut': dict(wood='walnut', tile=1.0, colour=(0.085, 0.042, 0.020), var=0.65, tint=0.55,
                   bump=('walnut_rough', 0.2, 0.0003), spec=0.38, gloss=0.62, grime=0.4, grime_col='dust', dust=0.2,
                   edge=0.3, edge_col=(0.20, 0.11, 0.05), edge_spec=0.2),
    'cherry': dict(wood='walnut', tile=0.8, colour=(0.21, 0.065, 0.030), var=0.45, tint=0.20,
                   bump=('walnut_rough', 0.2, 0.0003), spec=0.40, gloss=0.66, grime=0.4, grime_col='dust', dust=0.2,
                   edge=0.3, edge_col=(0.36, 0.14, 0.07), edge_spec=0.2),
    'barn': dict(wood='barn', tile=0.5, colour=(0.15, 0.12, 0.090), var=0.75, tint=0.75,
                 bump=('barn_rough', 0.8, 0.0012), spec=0.08, gloss=0.18, grime=0.7, grime_col='dust', dust=0.35,
                 edge=0.45, edge_col=(0.24, 0.20, 0.15)),
    # ---- soft goods
    'felt_green': dict(photo='felt', tile=0.284, colour=(0.012, 0.075, 0.032), var=0.35, bump=('felt_rough', 0.35, 0.0004),
                       spec=0.03, gloss=0.08, grime=0.35, grime_col='dust', dust=0.3),
    'felt_black': dict(photo='felt', tile=0.284, colour=(0.020, 0.020, 0.022), var=0.35, bump=('felt_rough', 0.35, 0.0004),
                       spec=0.03, gloss=0.08, grime=0.25, grime_col='dust', dust=0.08),
    'felt_tan': dict(photo='felt', tile=0.284, colour=(0.26, 0.16, 0.075), var=0.35, bump=('felt_rough', 0.35, 0.0004),
                     spec=0.03, gloss=0.08, grime=0.45, grime_col='oil', dust=0.2),
    'felt_red': dict(photo='felt', tile=0.284, colour=(0.20, 0.012, 0.018), var=0.35, bump=('felt_rough', 0.35, 0.0004),
                     spec=0.03, gloss=0.08, grime=0.35, grime_col='oil', dust=0.2),
    'leather': dict(photo='leather', tile=0.4, colour=(0.11, 0.045, 0.018), var=0.45, tint=0.6,
                    bump=('leather_rough', 0.45, 0.0004), spec=0.25, gloss=0.45, grime=0.6, grime_col='oil', dust=0.1,
                    edge=0.35, edge_col=(0.20, 0.10, 0.05)),
    'leather_black': dict(photo='leather', tile=0.4, colour=(0.020, 0.019, 0.018), var=0.4, tint=0.0,
                          bump=('leather_rough', 0.45, 0.0004), spec=0.3, gloss=0.5, grime=0.5, grime_col='dust',
                          dust=0.08, edge=0.25, edge_col=(0.06, 0.055, 0.05)),
    # ---- powder coats: the scratches and smudges of a scan of painted sheet steel, an orange-peel bump
    'coat_black': dict(photo='paint', tile=0.9, colour=(0.019, 0.019, 0.020), var=0.18, bump=('paint_rough', 0.25, 0.0002),
                       peel=True, spec=0.32, gloss=0.48, grime=0.45, grime_col='dust', dust=0.08, edge=0.25,
                       edge_col=(0.20, 0.20, 0.20), edge_spec=0.8),
    'coat_od': dict(photo='paint', tile=0.9, colour=(0.050, 0.058, 0.028), var=0.2, bump=('paint_rough', 0.25, 0.0002),
                    peel=True, spec=0.25, gloss=0.40, grime=0.55, grime_col='dust', dust=0.35, edge=0.3,
                    edge_col=(0.22, 0.22, 0.21), edge_spec=0.8),
    'coat_tan': dict(photo='paint', tile=0.9, colour=(0.24, 0.165, 0.090), var=0.2, bump=('paint_rough', 0.25, 0.0002),
                     peel=True, spec=0.25, gloss=0.40, grime=0.55, grime_col='oil', dust=0.3, edge=0.3,
                     edge_col=(0.30, 0.30, 0.29), edge_spec=0.8),
    'coat_grey': dict(photo='paint', tile=0.9, colour=(0.075, 0.078, 0.082), var=0.2, bump=('paint_rough', 0.25, 0.0002),
                      peel=True, spec=0.32, gloss=0.48, grime=0.5, grime_col='dust', dust=0.08, edge=0.25,
                      edge_col=(0.28, 0.28, 0.28), edge_spec=0.8),
    # the pegboard: black powder coat over a grid of punched holes (dark, with the wall's shadow in them)
    'pegboard': dict(photo='paint', tile=0.9, colour=(0.019, 0.019, 0.020), var=0.18, bump=('paint_rough', 0.25, 0.0002),
                     peel=True, holes=(0.0254, 0.0032), spec=0.32, gloss=0.48, grime=0.45, grime_col='dust', dust=0.08,
                     edge=0.25, edge_col=(0.20, 0.20, 0.20), edge_spec=0.8),
    # ---- bare metals
    'galv': dict(photo='galvanised', tile=0.9, colour=(0.20, 0.205, 0.21), var=0.7, tint=0.0,
                 bump=('steel_rough', 0.10, 0.0001), spec=0.55, gloss=0.42, grime=0.5, grime_col='oil', dust=0.15,
                 edge=0.4, edge_col=(0.34, 0.34, 0.35), edge_spec=0.9),
    'iron': dict(photo='steel', tile=0.35, colour=(0.030, 0.029, 0.028), var=0.6, tint=0.15,
                 bump=('steel_rough', 0.25, 0.0002), spec=0.35, gloss=0.38, grime=0.8, grime_col='rust', dust=0.15,
                 edge=0.45, edge_col=(0.13, 0.12, 0.11), edge_spec=0.75),
    'steel': dict(photo='steel', tile=0.6, colour=(0.2, 0.2, 0.2), var=0.5, tint=0.1, bump=('steel_rough', 0.15, 0.0002),
                  spec=0.6, gloss=0.5, grime=0.9, grime_col='oil', dust=0.2, edge=0.6, edge_col=(0.38, 0.38, 0.38),
                  edge_spec=0.9),
    'alu': dict(photo='galvanised', tile=0.3, colour=(0.33, 0.335, 0.34), var=0.3, tint=0.0,
                bump=('steel_rough', 0.06, 0.0001), spec=0.7, gloss=0.55, grime=0.6, grime_col='dust', dust=0.2,
                edge=0.3, edge_col=(0.48, 0.48, 0.48), edge_spec=0.9),
    'chrome': dict(colour=(0.30, 0.305, 0.31), spec=0.95, gloss=0.90, grime=0.5, grime_col='oil', dust=0.05),
    'brass': dict(photo='steel', tile=0.2, colour=(0.46, 0.31, 0.10), var=0.2, tint=0.0, spec=0.85, gloss=0.72,
                  grime=0.6, grime_col='oil', edge=0.3, edge_col=(0.62, 0.46, 0.20), edge_spec=0.95),
    'brass_aged': dict(photo='steel', tile=0.2, colour=(0.26, 0.17, 0.06), var=0.3, tint=0.0, spec=0.6, gloss=0.5,
                       grime=0.9, grime_col='oil', edge=0.5, edge_col=(0.48, 0.34, 0.14), edge_spec=0.9),
    # ---- rubber and plastic
    'rubber': dict(photo='grain', tile=0.04, colour=(0.017, 0.017, 0.018), var=0.3, bump=('grain_rough', 0.5, 0.0002),
                   spec=0.08, gloss=0.18, grime=0.7, grime_col='dust', dust=0.08, edge=0.2, edge_col=(0.05, 0.05, 0.05)),
    'plastic_black': dict(photo='grain', tile=0.06, colour=(0.022, 0.022, 0.023), var=0.25,
                          bump=('grain_rough', 0.25, 0.00015), spec=0.22, gloss=0.42, grime=0.6, grime_col='dust',
                          dust=0.08, edge=0.3, edge_col=(0.07, 0.07, 0.07)),
    'diffuser': dict(colour=(0.62, 0.62, 0.60), spec=0.25, gloss=0.5, grime=0.3, grime_col='dust', dust=0.2),
    # ---- pictures (pictures.py): engraved plates, a stencil
    'plate_oak': dict(image='plate_oak', base='brass', spec=0.8, gloss=0.7, grime=0.5, grime_col='oil'),
    'plate_heritage': dict(image='plate_heritage', base='brass', spec=0.8, gloss=0.7, grime=0.4, grime_col='oil'),
    'plate_walnut': dict(image='plate_walnut', base='brass', spec=0.8, gloss=0.7, grime=0.5, grime_col='oil'),
    'plate_pistols': dict(image='plate_pistols', base='brass', spec=0.8, gloss=0.7, grime=0.5, grime_col='oil'),
    'plate_stand': dict(image='plate_stand', base='chrome', spec=0.85, gloss=0.75, grime=0.4, grime_col='oil'),
    'stencil_armory': dict(image='stencil_armory', base='coat_od', spec=0.25, gloss=0.40, grime=0.55, grime_col='dust',
                           dust=0.3),
}
MOTTLE = {'coat_black': 0.06, 'coat_od': 0.08, 'coat_tan': 0.08, 'coat_grey': 0.06, 'pegboard': 0.06, 'iron': 0.15,
          'galv': 0.10, 'rubber': 0.12, 'plastic_black': 0.1, 'leather': 0.1}
GRIME = {'oil': (0.035, 0.028, 0.02), 'dust': (0.16, 0.145, 0.12), 'rust': (0.16, 0.06, 0.02)}

RECIPES = {}
for _name, _r in BASE.items():
    if 'wood' in _r:
        for _k, _ax in enumerate('xyz'):
            RECIPES[f'{_name}_{_ax}'] = dict(_r, axis=_k)
    else:
        RECIPES[_name] = _r
PAINTS = list(RECIPES)
INDEX = {n: i for i, n in enumerate(PAINTS)}


def P(name):
    return INDEX[name]


class Nodes:
    """A node tree built by naming what goes into each node (sockets link, numbers set)."""

    def __init__(self, mat):
        self.mat = mat
        self.nt = mat.node_tree
        self.nt.nodes.clear()
        self._co = self._uv = self._geo = None

    def node(self, kind, inputs=None, **props):
        n = self.nt.nodes.new(kind)
        for k, v in props.items():
            setattr(n, k, v)
        for k, v in (inputs or {}).items():
            s = next((s for s in n.inputs if (s.name == k or s.identifier == k) and s.enabled), None) or n.inputs[k]
            if isinstance(v, bpy.types.NodeSocket):
                self.nt.links.new(v, s)
            else:
                s.default_value = v
        return n

    def out(self, n, name=None):
        return next(s for s in n.outputs if s.enabled) if name is None else n.outputs[name]

    def co(self):
        if self._co is None:
            self._co = self.out(self.node('ShaderNodeTexCoord'), 'Object')
        return self._co

    def uv(self):
        if self._uv is None:
            self._uv = self.out(self.node('ShaderNodeUVMap', uv_map='UVMap 0'), 'UV')
        return self._uv

    def geo(self, name):
        if self._geo is None:
            self._geo = self.node('ShaderNodeNewGeometry')
        return self._geo.outputs[name]

    def op(self, operation, a, b=0.0, c=None):
        n = self.nt.nodes.new('ShaderNodeMath')
        n.operation = operation
        for i, v in enumerate((a, b) if c is None else (a, b, c)):
            if isinstance(v, bpy.types.NodeSocket):
                self.nt.links.new(v, n.inputs[i])
            else:
                n.inputs[i].default_value = v
        return n.outputs[0]

    def band(self, v, lo, hi):
        return self.out(self.node('ShaderNodeMapRange', {'Value': v, 'From Min': lo, 'From Max': hi, 'To Min': 0.0,
                                                         'To Max': 1.0}, interpolation_type='SMOOTHSTEP', clamp=True))

    def mix(self, fac, a, b):
        return self.out(self.node('ShaderNodeMix', {'Factor': fac, 'A': a, 'B': b}, data_type='RGBA'), 'Result')

    def mixf(self, fac, a, b):
        return self.out(self.node('ShaderNodeMix', {'Factor': fac, 'A': a, 'B': b}, data_type='FLOAT'), 'Result')

    def grey(self, c):
        return self.out(self.node('ShaderNodeRGBToBW', {'Color': c}))

    def axis(self, k, v):
        return self.out(self.node('ShaderNodeSeparateXYZ', {'Vector': v}), 'XYZ'[k])

    def vec(self, x, y, z=0.0):
        return self.out(self.node('ShaderNodeCombineXYZ', {'X': x, 'Y': y, 'Z': z}))

    def scale(self, v, k):
        return self.out(self.node('ShaderNodeVectorMath', {0: v, 'Scale': k}, operation='SCALE'), 'Vector')

    def add(self, a, b):
        return self.out(self.node('ShaderNodeVectorMath', {0: a, 1: b}, operation='ADD'), 'Vector')

    def mul(self, a, b):
        return self.out(self.node('ShaderNodeVectorMath', {0: a, 1: b}, operation='MULTIPLY'), 'Vector')

    def noise(self, scale, detail=3.0, rough=0.55, vector=None):
        return self.out(self.node('ShaderNodeTexNoise', {'Vector': vector or self.co(), 'Scale': scale, 'Detail': detail,
                                                         'Roughness': rough}), 'Fac')

    def image(self, file, data=False):
        img = bpy.data.images.load(os.path.join(MAPS, file + '.jpg'), check_existing=True)
        if data:
            img.colorspace_settings.name = 'Non-Color'
        return img

    def photo(self, file, tile, data=False, blend=0.2):
        m = self.node('ShaderNodeMapping', {'Vector': self.co(), 'Scale': (1 / tile,) * 3})
        t = self.node('ShaderNodeTexImage', {'Vector': self.out(m)}, projection='BOX', projection_blend=blend)
        t.image = self.image(file, data)
        return self.out(t, 'Color')

    def weights(self):
        """How much each of the three flat projections shows on a face: |normal|^4 per axis, summing to 1."""
        if not hasattr(self, '_w'):
            nrm = self.geo('Normal')
            p = [self.op('POWER', self.op('ABSOLUTE', self.axis(i, nrm)), 4.0) for i in range(3)]
            total = self.op('ADD', self.op('ADD', p[0], p[1]), self.op('ADD', p[2], 1e-6))
            self._w = [self.op('DIVIDE', q, total) for q in p]
        return self._w

    def grain(self, file, tile, axis, along, data=False):
        """The photograph on three flat projections (one per facing), each turned so the grain runs along `axis`;
        returns (colour, end-grain weight). A face looking along the grain gets the photograph squeezed 10:1 across
        the rings (fine end-grain lines)."""
        img = self.image(file, data)
        co = self.co()
        c = [self.axis(i, co) for i in range(3)]
        w = self.weights()
        acc = None
        for d in range(3):
            others = [i for i in range(3) if i != d]
            if axis in others:
                gc, cc = c[axis], c[[i for i in others if i != axis][0]]
                g = self.op('DIVIDE', gc, tile)
                x = self.op('DIVIDE', cc, tile)
            else:
                g = self.op('DIVIDE', c[others[0]], tile * 10.0)
                x = self.op('DIVIDE', c[others[1]], tile)
            uvw = self.vec(x, g) if along == 'v' else self.vec(g, x)
            t = self.node('ShaderNodeTexImage', {'Vector': uvw})
            t.image = img
            part = self.scale(self.out(t, 'Color'), w[d])
            acc = part if acc is None else self.add(acc, part)
        return acc, w[axis]

    def bump(self, h, strength, distance, normal=None):
        inputs = {'Height': h, 'Strength': strength, 'Distance': distance}
        if normal is not None:
            inputs['Normal'] = normal
        return self.out(self.node('ShaderNodeBump', inputs), 'Normal')


def build(name, ctx):
    """The material for paint `name`. ctx: {'ao': image or None, 'images': {name: image},
    'regions': {paint: ((ux, uy, uz, u0), (vx, vy, vz, v0))}}"""
    r = RECIPES[name]
    base_r = RECIPES.get(r.get('base')) if r.get('base') else None
    mat = bpy.data.materials.new('look.' + name)
    if mat.node_tree is None:
        mat.use_nodes = True
    n = Nodes(mat)
    co = n.co()
    colour = r.get('colour', base_r['colour'] if base_r else (0.5, 0.5, 0.5))
    albedo = n.out(n.node('ShaderNodeRGB'))
    albedo.default_value = (*colour, 1.0)
    height = None
    end = None

    if 'wood' in r or 'photo' in r:
        if 'wood' in r:
            ph, end = n.grain(r['wood'] + '_diff', r['tile'], r['axis'], GRAIN[r['wood']])
        else:
            ph = n.photo(r['photo'] + '_diff', r['tile'])
        lum = n.grey(ph)
        var = r.get('var', 0.3)
        k = n.op('ADD', n.op('MULTIPLY', n.op('SUBTRACT', lum, 0.45), 2.0 * var), 1.0)
        albedo = n.mul(albedo, n.vec(k, k, k))
        if r.get('tint'):
            # the photograph's own colour, scaled to the material's brightness
            scaled = n.mul(ph, (sum(colour) / 3 / 0.3,) * 3)
            albedo = n.mix(r['tint'], albedo, scaled)
        if end is not None:
            dim = n.op('SUBTRACT', 1.0, n.op('MULTIPLY', end, 1.0 - END_GRAIN))
            albedo = n.mul(albedo, n.vec(dim, dim, dim))
    mottle = r.get('mottle', MOTTLE.get(name, 0.0))
    if mottle:
        m = n.op('ADD', 1.0, n.op('MULTIPLY', n.op('SUBTRACT', n.noise(7.0, 3.0, 0.5), 0.5), 2.0 * mottle))
        albedo = n.mul(albedo, n.vec(m, m, m))
    if r.get('holes'):
        # punched holes on a grid in the board's x/z plane, dark inside (the wall behind them in shadow)
        pitch, rad = r['holes']
        fx = n.op('SUBTRACT', n.op('FRACT', n.op('DIVIDE', n.axis(0, co), pitch)), 0.5)
        fz = n.op('SUBTRACT', n.op('FRACT', n.op('DIVIDE', n.axis(2, co), pitch)), 0.5)
        d = n.op('MULTIPLY', n.op('SQRT', n.op('ADD', n.op('MULTIPLY', fx, fx), n.op('MULTIPLY', fz, fz))), pitch)
        facing = n.band(n.op('ABSOLUTE', n.axis(1, n.geo('Normal'))), 0.9, 0.98)
        hole = n.op('MULTIPLY', n.op('SUBTRACT', 1.0, n.band(d, rad - 0.0004, rad + 0.0002)), facing)
        albedo = n.mix(hole, albedo, (0.002, 0.002, 0.002, 1))
        height = n.op('SUBTRACT', 1.0, hole)
    if 'image' in r:
        (ux, uy, uz, u0), (vx, vy, vz, v0) = ctx['regions'][name]
        s = n.op('ADD', n.op('ADD', n.op('MULTIPLY', n.axis(0, co), ux), n.op('MULTIPLY', n.axis(1, co), uy)),
                 n.op('ADD', n.op('MULTIPLY', n.axis(2, co), uz), u0))
        t = n.op('ADD', n.op('ADD', n.op('MULTIPLY', n.axis(0, co), vx), n.op('MULTIPLY', n.axis(1, co), vy)),
                 n.op('ADD', n.op('MULTIPLY', n.axis(2, co), vz), v0))
        tex = n.node('ShaderNodeTexImage', {'Vector': n.vec(s, t)}, extension='CLIP')
        tex.image = ctx['images'][r['image']]
        pic = n.out(tex, 'Color')
        # the picture's red channel is the engraving / paint (white = engraved or painted), on the base metal
        ink = n.axis(0, pic)
        under = n.out(n.node('ShaderNodeRGB'))
        under.default_value = (*colour, 1.0)
        cut = (0.035, 0.025, 0.012, 1) if r['base'] != 'coat_od' else (0.55, 0.53, 0.45, 1)
        albedo = n.mix(ink, under, cut)
        height = n.op('SUBTRACT', 1.0, ink) if r['base'] != 'coat_od' else None
    if r.get('peel'):
        # the orange peel of a sprayed, baked finish: a fine soft bump
        h = n.noise(900.0, 2.0, 0.5)
        height = h if height is None else n.op('ADD', height, n.op('MULTIPLY', h, 0.1))

    # masks
    ao = 1.0
    if ctx.get('ao') is not None:
        t = n.node('ShaderNodeTexImage', {'Vector': n.uv()})
        t.image = ctx['ao']
        ao = n.axis(0, n.out(t, 'Color'))
    breakup = n.noise(55.0, 4.0, 0.6)
    crevice = n.op('SUBTRACT', 1.0, ao) if not isinstance(ao, float) else 0.0
    grime = 0.0
    if r.get('grime') and not isinstance(crevice, float):
        gphoto = n.grey(n.photo('grime_diff', 0.35))
        g = n.band(crevice, 0.10, 0.42)
        mod = n.op('ADD', 0.62, n.op('ADD', n.op('MULTIPLY', n.op('SUBTRACT', 0.6, gphoto), 0.35),
                                     n.op('MULTIPLY', breakup, 0.3)))
        grime = n.op('MINIMUM', n.op('MULTIPLY', n.op('MULTIPLY', g, mod), r['grime']), 1.0)
        albedo = n.mix(grime, albedo, (*GRIME[r.get('grime_col', 'oil')], 1))
    dust = 0.0
    if r.get('dust'):
        up = n.band(n.axis(2, n.geo('Normal')), 0.55, 0.95)
        # fine and faint: coarse patches read as camouflage on dark rubber and powder coat
        dust = n.op('MULTIPLY', n.op('MULTIPLY', up, n.band(n.noise(320.0, 5.0, 0.6), 0.52, 0.92)), r['dust'] * 0.45)
        albedo = n.mix(dust, albedo, (*GRIME['dust'], 1))
    edge = 0.0
    if r.get('edge'):
        e = n.band(n.geo('Pointiness'), 0.53, 0.6)
        edge = n.op('MULTIPLY', n.op('MULTIPLY', e, n.band(n.noise(90.0, 3.0), 0.35, 0.6)), r['edge'])
        albedo = n.mix(edge, albedo, (*r.get('edge_col', colour), 1))

    # spec and gloss
    spec, gloss = r['spec'], r['gloss']
    if 'bump' in r and ('photo' in r or 'wood' in r):
        if 'wood' in r:
            rough, _ = n.grain(r['bump'][0], r['tile'], r['axis'], GRAIN[r['wood']], data=True)
            rough = n.grey(rough)
        else:
            rough = n.grey(n.photo(r['bump'][0], r['tile'], data=True))
        gloss = n.op('MAXIMUM', n.op('SUBTRACT', gloss, n.op('MULTIPLY', n.op('SUBTRACT', rough, 0.5), 0.4)), 0.02)
    dirt = n.op('MINIMUM', n.op('ADD', grime if not isinstance(grime, float) else 0.0,
                                dust if not isinstance(dust, float) else 0.0), 1.0)
    spec = n.op('MULTIPLY', spec, n.op('SUBTRACT', 1.0, n.op('MULTIPLY', dirt, 0.75)))
    gloss = n.op('MULTIPLY', gloss, n.op('SUBTRACT', 1.0, n.op('MULTIPLY', dirt, 0.6)))
    if r.get('edge_spec') and not isinstance(edge, float):
        spec = n.mixf(edge, spec, r['edge_spec'])
        gloss = n.mixf(edge, gloss, min(1.0, r['gloss'] + 0.2))

    # relief
    normal = None
    if 'bump' in r and ('photo' in r or 'wood' in r):
        file, strength, dist = r['bump']
        if 'wood' in r:
            hmap, _ = n.grain(file, r['tile'], r['axis'], GRAIN[r['wood']], data=True)
            hmap = n.op('SUBTRACT', 1.0, n.grey(hmap))           # (rough pores sit lower than the polished grain)
        else:
            hmap = n.grey(n.photo(file, r['tile'], data=True))
        normal = n.bump(hmap, strength, dist)
    if height is not None:
        normal = n.bump(height, 0.5 if r.get('holes') or 'image' in r else 0.08,
                        0.0004 if r.get('holes') else (0.00015 if 'image' in r else 0.00004), normal)
    if r.get('dust') and not isinstance(dust, float):
        normal = n.bump(n.noise(900.0, 2.0), n.op('MULTIPLY', dust, 0.3), 0.0001, normal)
    _finish(n, albedo, spec, gloss, normal)
    return mat


def _finish(n, albedo, spec, gloss, normal):
    """The four bake targets, an Output, and an image node the baker points at its target."""
    em_a = n.node('ShaderNodeEmission', {'Color': albedo})
    em_a.name = 'EM_albedo'
    em_s = n.node('ShaderNodeEmission', {'Color': n.vec(spec, spec, spec)
                                         if isinstance(spec, bpy.types.NodeSocket) else (spec, spec, spec, 1)})
    em_s.name = 'EM_spec'
    em_g = n.node('ShaderNodeEmission', {'Color': n.vec(gloss, gloss, gloss)
                                         if isinstance(gloss, bpy.types.NodeSocket) else (gloss, gloss, gloss, 1)})
    em_g.name = 'EM_gloss'
    nb = n.node('ShaderNodeBsdfDiffuse', {'Normal': normal} if normal is not None else {})
    nb.name = 'NRM'
    out = n.node('ShaderNodeOutputMaterial')
    out.name = 'OUT'
    n.nt.links.new(em_a.outputs[0], out.inputs['Surface'])
    tgt = n.nt.nodes.new('ShaderNodeTexImage')
    tgt.name = 'BAKE_TARGET'


def set_pass(mat, which, target):
    """Point `mat` at bake pass `which` ('albedo', 'spec', 'gloss', 'normal') and at image `target`."""
    nt = mat.node_tree
    out = nt.nodes['OUT']
    for link in list(out.inputs['Surface'].links):
        nt.links.remove(link)
    src = nt.nodes['NRM'] if which == 'normal' else nt.nodes['EM_' + which]
    nt.links.new(src.outputs[0], out.inputs['Surface'])
    t = nt.nodes['BAKE_TARGET']
    t.image = target
    for node in nt.nodes:
        node.select = False
    t.select = True
    nt.nodes.active = t
