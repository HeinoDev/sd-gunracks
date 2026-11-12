-- SERVER-ONLY (not in fxmanifest files{}): audit logging, routed through server/racks/audit.lua to
-- the sd_gunracks_log table (the console's Logs tab) and to ox_lib lib.logger (backend picked by
-- the `ox:logger` convar in server.cfg).
return {
    Enabled = true, -- master switch: false disables ALL audit logging, both the table and lib.logger

    -- Per-event switches; a missing key counts as on. Each one covers both destinations.
    Events = {
        place = true, -- a player put a rack down (rack id, model, coords)
        pickup = true, -- an owner picked an empty rack back up
        store = true, -- a gun went onto a rack (weapon, serial, rack, slot)
        take = true, -- a gun came off a rack
        lock = true, -- a rack was locked or unlocked by its owner / an admin
        force = true, -- someone tried to force a rack's lock (success or fail, item broken)
        seize = true, -- police seized a gun (serial, the rack's owner)
        admin = true, -- staff opened the console, placed / deleted / locked / gave away a rack, edited
        -- its access, took a gun off it, went to it, or handed out a rack item (admin.<action>)
        export = true, -- another resource created or deleted a rack through an export
        suspect = true, -- a server-authoritative reject that smells like an exploit attempt
    },

    -- The sd_gunracks_log table the console's Logs tab pages through (created at start). Every
    -- event above is written there whether or not an ox:logger backend is set up.
    Database = {
        Enabled = true,

        -- Retention: rows over MaxRows (oldest first) and rows older than MaxDays are deleted at
        -- start and then every PruneEveryMinutes. 0 switches that limit off.
        MaxRows = 50000,
        MaxDays = 90,
        PruneEveryMinutes = 60,
    },
}
