return {
    -- Addon (non-vanilla) weapons. Every vanilla firearm already has a measured spot in each slot
    -- kind (data/racks.json); an addon gun has none, so list it here with its weapon group and it
    -- is accepted by every slot kind that takes that group, placed at run time from the weapon
    -- model's bounding box (less exact than a measured fit). Names in UPPERCASE, as ox_inventory
    -- names weapons. Groups: GROUP_PISTOL, GROUP_SMG, GROUP_RIFLE, GROUP_MG, GROUP_SHOTGUN,
    -- GROUP_SNIPER, GROUP_HEAVY, GROUP_MELEE, GROUP_STUNGUN.
    Extra = {
        -- WEAPON_M4A1 = 'GROUP_RIFLE',
        -- WEAPON_GLOCK17 = 'GROUP_PISTOL',
    },

    -- Weapons no rack ever accepts, even where a fit exists. Checked before the fits on both
    -- sides, so a blacklisted gun never even shows the "Rack" option.
    Blacklist = {
        WEAPON_RPG = true,
        WEAPON_HOMINGLAUNCHER = true,
        WEAPON_GRENADELAUNCHER = true,
        WEAPON_MINIGUN = true,
        WEAPON_RAILGUN = true,
        WEAPON_RAILGUNXM3 = true,
        WEAPON_FIREWORK = true,
        WEAPON_EMPLAUNCHER = true,
    },
}
