return {
    -- sd-interact (floating prompts) when it is running: 'auto' uses it if it is started and your target
    -- resource (ox_target, qb-target, ...) otherwise; true / false force one or the other.
    Interact = 'auto',

    -- Target options: icons and how close you must be to see them, metres. Keep the distances
    -- inside Interact.Range (configs/shared/interact.lua) or the server refuses what you picked.
    Slot = {
        store = { icon = 'fa-solid fa-gun', distance = 3.0 },
        choose = { icon = 'fa-solid fa-list', distance = 3.0 },
        take = { icon = 'fa-solid fa-hand', distance = 3.0 },
        inspect = { icon = 'fa-solid fa-magnifying-glass', distance = 3.0 },
        seize = { icon = 'fa-solid fa-handcuffs', distance = 3.0 },
    },
    Rack = {
        lock = { icon = 'fa-solid fa-lock', distance = 3.0 },
        unlock = { icon = 'fa-solid fa-lock-open', distance = 3.0 },
        pickup = { icon = 'fa-solid fa-box', distance = 3.0 },
        force = { icon = 'fa-solid fa-screwdriver', distance = 3.0 },
    },

    -- Short progress bars so racking and taking a gun is an action rather than a click. 0 = instant.
    Progress = {
        store = 1200,
        take = 1000,
        pickup = 2500,
        anim = { dict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@', clip = 'machinic_loop_mechandplayer' },
    },

    -- The animation played while forcing a lock, around the skill check.
    ForceAnim = { dict = 'mp_arresting', clip = 'a_uncuff' },
}
