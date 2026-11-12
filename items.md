# Item definitions

## ox_inventory

Everything Gun Racks needs added to `ox_inventory/data/items.lua`. Paste the block below into that file's item table, and copy the ten images from this resource's `images/` folder into `ox_inventory/web/images/`.

Using a rack item opens placement mode. The `server = { export = ... }` line is how ox_inventory hands the use to this resource (the bridge registers one export per item, named `use` + the item name with its first letter capitalised); `consume = 0` keeps the item until the rack is actually put down, when the resource removes it itself.

```lua
    ['gunrack_oak'] = {
        label = 'Oak Floor Rack',
        weight = 12000,
        stack = false,
        consume = 0,
        description = 'A free-standing oak rack with eight upright slots for long guns.',
        client = { image = 'gunrack_oak.png' },
        server = { export = 'sd-gunracks.useGunrack_oak' },
    },

    ['gunrack_panel'] = {
        label = 'Steel Wall Panel',
        weight = 8000,
        stack = false,
        consume = 0,
        description = 'A steel wall panel that holds three long guns lying flat.',
        client = { image = 'gunrack_panel.png' },
        server = { export = 'sd-gunracks.useGunrack_panel' },
    },

    ['gunrack_walnut'] = {
        label = 'Walnut Wall Rack',
        weight = 9000,
        stack = false,
        consume = 0,
        description = 'A walnut wall rack with six upright slots for long guns.',
        client = { image = 'gunrack_walnut.png' },
        server = { export = 'sd-gunracks.useGunrack_walnut' },
    },

    ['gunrack_pegboard'] = {
        label = 'Tactical Pegboard',
        weight = 7000,
        stack = false,
        consume = 0,
        description = 'A wall pegboard: two long guns across the top, six handguns on pegs below.',
        client = { image = 'gunrack_pegboard.png' },
        server = { export = 'sd-gunracks.useGunrack_pegboard' },
    },

    ['gunrack_pistols'] = {
        label = 'Pistol Display Board',
        weight = 5000,
        stack = false,
        consume = 0,
        description = 'A walnut-framed felt display board for eight handguns, each held in profile on a magnetic mount.',
        client = { image = 'gunrack_pistols.png' },
        server = { export = 'sd-gunracks.useGunrack_pistols' },
    },

    ['gunrack_armory'] = {
        label = 'Armory A-Frame',
        weight = 18000,
        stack = false,
        consume = 0,
        description = 'A double-sided armoury A-frame holding twelve long guns, six a side.',
        client = { image = 'gunrack_armory.png' },
        server = { export = 'sd-gunracks.useGunrack_armory' },
    },

    ['gunrack_corner'] = {
        label = 'Cherry Corner Rack',
        weight = 10000,
        stack = false,
        consume = 0,
        description = 'A cherry rack that fits into a corner, with five upright slots for long guns.',
        client = { image = 'gunrack_corner.png' },
        server = { export = 'sd-gunracks.useGunrack_corner' },
    },

    ['gunrack_stand'] = {
        label = 'Pistol Stand',
        weight = 3000,
        stack = false,
        consume = 0,
        description = 'A small table-top stand that holds five handguns upright on posts.',
        client = { image = 'gunrack_stand.png' },
        server = { export = 'sd-gunracks.useGunrack_stand' },
    },

    ['gunrack_pipe'] = {
        label = 'Industrial Pipe Rack',
        weight = 8000,
        stack = false,
        consume = 0,
        description = 'Black iron pipe on the wall, holding four long guns lying flat.',
        client = { image = 'gunrack_pipe.png' },
        server = { export = 'sd-gunracks.useGunrack_pipe' },
    },

    ['gunrack_heritage'] = {
        label = 'Heritage Display',
        weight = 6000,
        stack = false,
        consume = 0,
        description = 'A single-gun wall display for the one rifle worth showing off.',
        client = { image = 'gunrack_heritage.png' },
        server = { export = 'sd-gunracks.useGunrack_heritage' },
    },
```

## qb-core / Qbox shared items (qb-inventory and other qb-style inventories)

The `server = { export = ... }` line above is an ox_inventory feature; on qb-style inventories the resource registers the use handlers itself at boot through the bridge, so the items only need to be usable. Add these to `qb-core/shared/items.lua` and copy the images into your inventory's image folder (`qb-inventory/html/images/`).

```lua
    gunrack_oak      = { name = 'gunrack_oak',      label = 'Oak Floor Rack',       weight = 12000, type = 'item', image = 'gunrack_oak.png',      unique = true, useable = true, shouldClose = true, description = 'A free-standing oak rack with eight upright slots for long guns.' },
    gunrack_panel    = { name = 'gunrack_panel',    label = 'Steel Wall Panel',     weight = 8000,  type = 'item', image = 'gunrack_panel.png',    unique = true, useable = true, shouldClose = true, description = 'A steel wall panel that holds three long guns lying flat.' },
    gunrack_walnut   = { name = 'gunrack_walnut',   label = 'Walnut Wall Rack',     weight = 9000,  type = 'item', image = 'gunrack_walnut.png',   unique = true, useable = true, shouldClose = true, description = 'A walnut wall rack with six upright slots for long guns.' },
    gunrack_pegboard = { name = 'gunrack_pegboard', label = 'Tactical Pegboard',    weight = 7000,  type = 'item', image = 'gunrack_pegboard.png', unique = true, useable = true, shouldClose = true, description = 'A wall pegboard: two long guns across the top, six handguns on pegs below.' },
    gunrack_pistols  = { name = 'gunrack_pistols',  label = 'Pistol Display Board', weight = 5000,  type = 'item', image = 'gunrack_pistols.png',  unique = true, useable = true, shouldClose = true, description = 'A walnut-framed felt display board for eight handguns, each held in profile on a magnetic mount.' },
    gunrack_armory   = { name = 'gunrack_armory',   label = 'Armory A-Frame',       weight = 18000, type = 'item', image = 'gunrack_armory.png',   unique = true, useable = true, shouldClose = true, description = 'A double-sided armoury A-frame holding twelve long guns, six a side.' },
    gunrack_corner   = { name = 'gunrack_corner',   label = 'Cherry Corner Rack',   weight = 10000, type = 'item', image = 'gunrack_corner.png',   unique = true, useable = true, shouldClose = true, description = 'A cherry rack that fits into a corner, with five upright slots for long guns.' },
    gunrack_stand    = { name = 'gunrack_stand',    label = 'Pistol Stand',         weight = 3000,  type = 'item', image = 'gunrack_stand.png',    unique = true, useable = true, shouldClose = true, description = 'A small table-top stand that holds five handguns upright on posts.' },
    gunrack_pipe     = { name = 'gunrack_pipe',     label = 'Industrial Pipe Rack', weight = 8000,  type = 'item', image = 'gunrack_pipe.png',     unique = true, useable = true, shouldClose = true, description = 'Black iron pipe on the wall, holding four long guns lying flat.' },
    gunrack_heritage = { name = 'gunrack_heritage', label = 'Heritage Display',     weight = 6000,  type = 'item', image = 'gunrack_heritage.png', unique = true, useable = true, shouldClose = true, description = 'A single-gun wall display for the one rifle worth showing off.' },
```

Notes:

- The item names must match `configs/shared/racks.lua` (`Items`). Rename one there and here together; the model names on the right of that table must stay as they are.
- Forcing a rack's lock uses `lockpick` by default (`configs/server/interact.lua` `Force.Item`), an item assumed to exist on your server. Swap it for your own, or set it to `false` to need no item.
- Racks take the guns themselves as they are in the inventory (serial, ammo, attachments, tint and condition are kept), so the weapons need no extra items.
