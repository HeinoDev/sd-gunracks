return {
    -- The usable inventory item for each rack model. Everything else about a rack (label, floor or
    -- wall, its slots and which guns fit them) is generated into data/racks.json from the models,
    -- so only the item names live here. Rename an item by changing the key AND your inventory's
    -- item list (see items.md); the model names must stay as they are.
    Items = {
        gunrack_oak = 'sd_gunrack_oak',
        gunrack_panel = 'sd_gunrack_panel',
        gunrack_walnut = 'sd_gunrack_walnut',
        gunrack_pegboard = 'sd_gunrack_pegboard',
        gunrack_pistols = 'sd_gunrack_pistols',
        gunrack_armory = 'sd_gunrack_armory',
        gunrack_corner = 'sd_gunrack_corner',
        gunrack_stand = 'sd_gunrack_stand',
        gunrack_pipe = 'sd_gunrack_pipe',
        gunrack_heritage = 'sd_gunrack_heritage',
    },
}
