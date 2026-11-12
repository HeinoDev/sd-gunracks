-- SERVER-ONLY (not in fxmanifest files{}): who may put racks down and how many. Deep-merged into
-- config.Placement on the server.
return {
    -- Most racks one character may own at once (admin-placed racks belong to nobody and never
    -- count). 0 = no limit.
    MaxPerPlayer = 10,

    -- Who may use a rack item: false = everyone, or a list of jobs with the lowest grade allowed,
    -- e.g. { police = 0, ammunation = 2 }.
    Jobs = false,

    -- Seconds a placement may stay open after the item was used before the server forgets it
    -- (the player walked off with the ghost up). Using the item again starts a fresh one.
    SessionSeconds = 300,

    -- Extra metres the server allows over Range, for the ped shuffling while the player confirms.
    RangeSlack = 1.5,
}
