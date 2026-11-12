# sd-gunracks props

The ten racks `sd-gunracks` streams, and the data that lets a real weapon sit in each slot. They ship inside the resource
(`stream/*.ydr`, the archetypes in `stream/sd_gunracks.ytyp`, the slots and fits in `data/racks.json`, the inventory
pictures in `images/`). These scripts rebuild all of it. Restarting sd-gunracks remounts the models, so on a live server
restart it only when nobody is near a rack (its client cleans its own props up on stop), or with nobody connected.

Every vanilla firearm is fitted into every kind of slot against its real mesh, and every fit is checked against the
rack's own baked geometry.

## The racks

| Model | Item | Mount | Slots | What it is |
|---|---|---|---|---|
| `sd_gunrack_oak` | `gunrack_oak` | floor | 8 upright | golden oak: shaped side panels with turned rosettes and dowel plugs, a routed plinth, a felt-lined butt tray, a felt-lined comb, a scalloped back rail, a brass maker's plate |
| `sd_gunrack_panel` | `gunrack_panel` | wall | 3 horizontal | galvanised steel plate on four chrome standoffs, dark rails top and bottom, rubber-dipped J-hooks, an aluminium LED bar |
| `sd_gunrack_walnut` | `gunrack_walnut` | wall | 6 upright | walnut: a crested back board with finials, a bracketed shelf with leather-lined butt cups, a deep notched rail lined in leather, a brass plate |
| `sd_gunrack_pegboard` | `gunrack_pegboard` | wall | 2 horizontal + 6 peg | punched black powder-coated steel with folded edges, rubber-dipped hooks and pistol pegs, a steel shelf |
| `sd_gunrack_pistols` | `gunrack_pistols` | wall | 8 flat | a walnut frame with a bead on charcoal felt, eight rubber-coated magnetic gun mounts, a brass plate |
| `sd_gunrack_armory` | `gunrack_armory` | floor | 12 upright (6 a side) | an OD green square-tube A-frame: rubber butt trays both sides, a spine with rubber-lined notches, end caps, a lock bar with a hasp and padlock, stencilled end plates |
| `sd_gunrack_corner` | `gunrack_corner` | floor (its origin is the room's corner) | 5 upright | cherry: a quarter-round plinth and tray, cove brackets along both walls, a curved comb, a turned corner post, tan felt |
| `sd_gunrack_stand` | `gunrack_stand` | surface (tables too) | 5 post | a black steel base with a rubber deck, rubber-dipped posts with chrome collars, rubber feet, a chrome plate |
| `sd_gunrack_pipe` | `gunrack_pipe` | wall | 4 horizontal | six weathered barn boards, eight 3/4" black iron pipe hooks (flange, nipple, elbow, nipple, cap) |
| `sd_gunrack_heritage` | `gunrack_heritage` | wall | 1 horizontal | a walnut plaque with scooped ends and a black leather inlay, two cast brass hooks on rosettes, an engraved brass plaque |

`cache/build_report.json` has each one's triangles (and its medium LOD's), textures, file size, and every weapon it took
or refused with the reason. Each `.ydr` embeds its own three textures (`<model>_d` DXT1 2048, `_n` BC5 1024, `_s` DXT5
512; the stand half that), one `normal_spec.sps` material, a medium LOD (Decimate to 30%, switched to beyond 12 m) and
box collision.

## Frames

Every rack: metres, +Z up, its front faces -Y. Floor and surface racks have their origin on the floor under the middle
of their footprint; wall racks on their back face (the wall, y = 0) at their bottom-centre; the corner rack at the
room's corner. A slot is a frame in the rack (`pos` + `yaw` about Z); a fit is the weapon object in that frame:

- **upright**: origin on the floor of the butt notch, +Y back toward the rest. The gun stands on its butt, its sights
  to the back, and leans back until whatever of it is at the rest's height touches the rest's stop.
- **horizontal**: origin midway between the hooks on the line they support at, on the wall's face. The gun lies on its
  side, muzzle left, slid along the hooks and tipped until it rests on both where it is solid, its weight between them.
- **peg**: origin at the peg's root on the board; the barrel goes over the peg, grip down.
- **post**: origin on the deck at the post's foot; the gun stands muzzle-down over the post, grip to the room.
- **flat**: origin on the magnet's centre; the gun lies in profile, its slide's middle on the magnet.

A fit row is `[px, py, pz, pitch, roll, yaw]`, GTA rotation order 2 (Blender Euler `YXZ`). `shared/fit.lua` turns it
into the rack-space offset and rotation `AttachEntityToEntity` takes.

## The weapons

`weapons/metas.py` reads every firearm from the game's own weapon metas (name, world model, group, default components)
into `cache/weapons.json`. `weapons/guns.py` reads the models (CodeWalker XML exported with `vexport`, in the folder `GTA_WEAPONS` names: game
data that never ships) and puts each default component
(magazine, scope, Mk II barrel) on its bone, as `CreateWeaponObject` draws the gun. `weapons/fits.py` places a gun in a
kind of slot. A model's vertices alone leave whole bands of a barrel empty (it is a few long triangles), so the fits use
the surface sampled every 6 mm.

`build.py` then checks every fit against the rack: the gun's surface every 8 mm, at every slot of that kind; a point is
inside the rack when two of three rays from it meet the rack's surface from behind (the nearest face's normal alone
misjudged points off edges and corners). A gun that goes more than 4 mm into the rack is dropped and reported. A peg's
or post's own cylinder is exempt: it goes up the barrel.

Addon weapons (configs/shared/weapons.lua `Extra`) have no fit; `shared/fit.lua` places them from their bounding box
with the same rules, using the medians the real guns gave (`kinds[*].fallback`). `fitcheck.py` runs `shared/fit.lua`
under stock Lua: it must place every measured fit exactly as Python does, and it reports how far the box-only placement
lands from the measured one (1 to 6 cm typically).

## Rebuilding

Blender 5.x with the Sollumz extension, Python 3 with numpy and Pillow, Node, stock Lua 5.4.

Environment variables:

- `GTA_WEAPONS` (required to fit or render guns): a folder holding the game's weapon models as CodeWalker XML,
  `models/<model>.ydr.xml`, exported with `vexport`. Game data: it never ships. `weapons/guns.py` caches the meshes
  it reads in `mesh/` beside them.
- `VANILLA_LIB` (optional, `verify.py` only): a folder holding `vanilla_lib.py`, whose Sollumz palette-tint patch
  lets the weapons render with their tint on Blender 5.x. Without it the renders still run, the tinted parts untinted.

Then:

    node tools/props/textures/fetch.mjs                     (once: the Poly Haven photographs, CC0)
    python tools/props/weapons/metas.py <extracted metas>   (once: see weapons/metas.py for which files)
    python tools/props/pictures.py                          (the engraved plates and the stencil)
    blender -b -P tools/props/build.py
    blender -b -P tools/props/verify.py -- icons
    python tools/props/fitcheck.py

`build.py -- only=sd_gunrack_oak bake=256` builds one rack with small textures to iterate on a look; `preview.py`
renders bare geometry with Workbench (back faces culled, as GTA draws) in a couple of seconds. `verify.py` re-imports the
shipped `.ydr` files, loads them with the game's own guns at the racks.json transforms, renders
`cache/verify/<rack>_{loaded,front}.png` (Cycles) and, with `icons`, the 256 px inventory pictures in `images/`.

The files: `models.py` (the ten builders and their slots), `looks.py` (the materials: grain-aware wood, felt, leather,
powder coats, metals), `bake.py` (unwrap and bake), `dds.py` (DDS writers), `shapes.py` (bmesh shape helpers),
`pictures.py`, `build.py`, `verify.py`, `preview.py`, `fitcheck.py`, `weapons/`, `textures/` (photographs, plates).

Photographs (all CC0, Poly Haven; `textures/maps/meta.json` lists authors and pages): `oak_veneer_01`,
`smoked_walnut_veneer` (also the cherry's grain), `rough_wood`, `velour_velvet`, `brown_leather`, `blue_metal_plate`,
`metal_plate_02`, `corrugated_iron`, `rubberized_track`, `dirty_concrete`, and `studio_small_09` for the check renders.
Every name on the plates is made up.
