-- SERVER-ONLY (not in fxmanifest files{}): rate limits, forcing a lock and police seizures.
-- Deep-merged into config.Interact on the server.
return {
    -- Shortest gap between two of one player's requests, ms. `Action` covers everything that
    -- moves a gun or changes a rack; `Query` covers reads (the weapon list, inspecting a gun).
    -- A legitimate client never gets near these (every action has a progress bar); a request
    -- that does is refused, and logged as `suspect` at most once per SuspectEverySeconds.
    RateLimit = {
        Action = 600,
        Query = 300,
        SuspectEverySeconds = 10,
    },

    -- Force the lock: a player who has no key to a locked rack can try to pick it.
    Force = {
        Enabled = true,
        Item = 'lockpick', -- needed to try; false = no item needed
        BreakChance = 0.35, -- chance the item is used up on a failed attempt (0 = never, 1 = always)
        Difficulty = { 'easy', 'medium', 'medium' }, -- ox_lib skillCheck difficulty (one entry per stage)
        Inputs = { 'w', 'a', 's', 'd' }, -- keys the skill check may ask for
        AlertChance = 1.0, -- chance police are alerted when someone STARTS forcing (0-1)
        MinSeconds = 1, -- an attempt reported back sooner than this was not played (refused, suspect)
        TimeoutSeconds = 45, -- an attempt not reported back within this is forgotten
        AdminRacks = false, -- may admin-placed racks (armouries) be forced? false = never

        -- The dispatch alert, sent through bridge/client/alert.lua to whichever dispatch you run.
        Alert = {
            displayCode = '10-90',
            title = 'Gun rack break-in',
            message = 'Someone is forcing the lock on a gun rack',
            description = 'Someone is forcing the lock on a gun rack',
            dispatchcodename = 'gunrack_breakin',
            sprite = 110, colour = 1, scale = 1.0, blipText = 'Gun rack break-in',
            jobs = { 'police', 'sheriff' },
        },
    },

    -- Police may seize a stored gun from any rack, locked or not, owned or not. Each seizure is
    -- logged with the gun's serial and the rack's owner.
    Seize = {
        Enabled = true,
        Jobs = { police = 0, sheriff = 0 }, -- job = lowest grade allowed
    },
}
