return {
    -- Racks (and the guns on them) are spawned on each client as local props once you come within
    -- this many metres, and removed again when you leave. Guns are small, so there is no point
    -- drawing them across the map.
    StreamDistance = 40.0,

    -- Draw each stored gun with the attachments it carries (scope, suppressor, grip...). Off draws
    -- the bare gun, which is a little cheaper with many racks in one room.
    Attachments = true,

    -- Draw each stored gun in its tint (camo / colour). Off draws the default finish.
    Tints = true,

    -- The see-through preview while placing: alpha 0-255, and the outline colours for a spot that
    -- will be accepted and one that will not.
    Ghost = {
        Alpha = 170,
        Valid = { 70, 220, 110, 255 },
        Invalid = { 230, 60, 60, 255 },
    },

    -- How long to wait for a rack model / weapon asset to stream in before giving up, ms.
    LoadTimeout = 10000,
}
