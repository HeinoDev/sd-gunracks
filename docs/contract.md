# sd-gunracks: contract between the models and the script

sd-gunracks is a standalone resource: ten placeable gun racks (floor, wall and table-top) whose slots hold real
weapons out of the player's inventory. A stored gun is drawn in its slot as the game's own weapon model (with its
attachments and tint), exactly where it would sit in that rack. Nothing here depends on any housing script.

Two halves, built separately:

- **Models** (`tools/props/`, Blender + Sollumz, run offline): the ten `.ydr` + `stream/sd_gunracks.ytyp`, and
  `data/racks.json`: every rack's slots and, for every vanilla firearm, where it sits in each kind of slot (fitted
  against the real weapon meshes, collision-checked). Also `images/<item>.png` (inventory icons).
- **Script** (everything else): placing racks, storing/taking guns, access, persistence, sync, drawing the guns.

`shared/fit.lua` (owned by the models side) is the only code that reads the fits; the script calls it.

## The racks

| model | item | label | mount | slots |
|---|---|---|---|---|
| `sd_gunrack_oak` | `gunrack_oak` | Oak Floor Rack | floor | 8 upright |
| `sd_gunrack_panel` | `gunrack_panel` | Steel Wall Panel | wall | 3 horizontal |
| `sd_gunrack_walnut` | `gunrack_walnut` | Walnut Wall Rack | wall | 6 upright |
| `sd_gunrack_pegboard` | `gunrack_pegboard` | Tactical Pegboard | wall | 2 horizontal + 6 peg |
| `sd_gunrack_pistols` | `gunrack_pistols` | Pistol Display Board | wall | 8 flat (magnetic mounts) |
| `sd_gunrack_armory` | `gunrack_armory` | Armory A-Frame | floor | 12 upright (6 a side) |
| `sd_gunrack_corner` | `gunrack_corner` | Cherry Corner Rack | floor (corner) | 5 upright |
| `sd_gunrack_stand` | `gunrack_stand` | Pistol Stand | surface | 5 post |
| `sd_gunrack_pipe` | `gunrack_pipe` | Industrial Pipe Rack | wall | 4 horizontal |
| `sd_gunrack_heritage` | `gunrack_heritage` | Heritage Display | wall | 1 horizontal |

Model space (every rack): metres, +Z up, the rack's FRONT faces -Y (its back +Y).

- `floor` / `surface`: origin on the floor (or table) under the middle of the footprint. `surface` racks are small
  and go on any upward-facing surface (a table, a counter, a shelf) as well as the floor.
- `wall`: origin on the BACK face (y = 0 is the wall), at the bottom-centre of the rack. Local +Y points INTO the
  wall. Placed by aiming at a wall: heading = the one that turns local -Y onto the wall's normal
  (`heading = deg(atan2(nx, -ny))` for a wall normal (nx, ny)); the player moves it up/down/sideways along the wall.
- The corner rack's origin is its corner (the rack lies in +x/+y... see `racks.json` min/max): it is a floor rack.

## data/racks.json (generated, read with LoadResourceFile on both sides)

```jsonc
{
  "version": 1,
  "racks": {
    "sd_gunrack_oak": {
      "label": "Oak Floor Rack",
      "mount": "floor",                       // floor | wall | surface
      "min": [-0.48, -0.17, 0.0], "max": [0.48, 0.17, 0.86],
      "slots": [
        // one per slot, in a stable order (slot index = position in this list, 1-based in Lua).
        // `kind` is a KEY into this rack's `kinds` (a rack may have several: e.g. the pegboard's "long" and "pistol")
        { "kind": "long", "pos": [x, y, z], "yaw": 0.0,
          "focus": [x, y, z], "radius": 0.10,   // (old: a small sphere where the gun sits)
          "zone": { "c": [x, y, z], "s": [sx, sy, sz], "yaw": 0.0 } }  // the slot's interaction BOX: centre and
          // size in the rack's space, turned by yaw. It covers the slot's whole column, because the aim ray goes
          // through the (collision-less) gun and ends on what is behind it (tools/props/zones.py)
      ],
      "kinds": {
        // type: upright | horizontal | peg | post | flat (how the gun sits; tools/props/weapons/fits.py)
        "long": { "type": "upright", "label": "Long gun",
                  "groups": ["GROUP_RIFLE", "GROUP_SHOTGUN", "GROUP_SNIPER", "GROUP_MG", "GROUP_SMG"],
                  "length": [0.55, 1.25], "fallback": { /* shared/fit.lua's, per type */ } }
      },
      "fits": {
        // per kind key: weapon (UPPERCASE, as ox_inventory names it) -> [px, py, pz, pitch, roll, yaw] in the SLOT's frame
        "long": { "WEAPON_ASSAULTRIFLE": [0.0, 0.012, 0.31, -78.0, 90.0, 0.0] }
      }
    }
  }
}
```

A weapon is accepted by a slot when `fits[kind][WEAPON]` exists (it was fitted and collision-checked offline), or
when it is an extra (addon) weapon registered in the config with a group the slot kind accepts; extras are placed
at run time from the weapon model's bounding box (`shared/fit.lua`, less exact).

## shared/fit.lua (API the script uses)

```lua
local fit = require 'shared.fit'
fit.racks()                         --> the decoded racks table (racks.json's `racks`), cached
fit.rack(model)                     --> one rack, or nil
fit.accepts(model, slot, weapon)    --> boolean: may this weapon go in this slot (server + client; extras by config group)
fit.place(model, slot, weapon, dmin, dmax)
    --> offset vector3, rotation vector3 (pitch, roll, yaw) in the RACK's space, or nil
    -- dmin/dmax: GetModelDimensions of the weapon model (client only; needed for extras, ignored otherwise)
```

The script draws a stored weapon by: `RequestWeaponAsset`, `CreateWeaponObject(hash, 0, coords, true, 1.0, 0)`,
attachments (`GiveWeaponComponentToWeaponObject` for every component the gun takes) and tint
(`SetWeaponObjectTintIndex`), then `AttachEntityToEntity(obj, rack, 0, offset.x, offset.y, offset.z, rot.x, rot.y,
rot.z, false, false, false, false, 2, true)`. Rotation order 2: x = pitch, y = roll, z = yaw (Blender `YXZ`).
