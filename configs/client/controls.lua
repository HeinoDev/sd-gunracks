-- The placer (client/racks/placement.lua): the game's own editor gizmo over a see-through rack, with
-- these keys, for players placing a rack item and staff placing from the console alike. The rack
-- starts where you look: a wall rack flat against the wall you aim at, a floor or table-top rack on
-- the surface under the crosshair. Then the gizmo and these keys.
return {
    -- Keys read as GTA control ids (https://docs.fivem.net/docs/game-references/controls/), each with
    -- the name the strip shows for it: move a key and give it its new name here too.
    Keys = {
        Confirm = { 191, 'Enter' }, -- put the rack down here (only while it may go here)
        Cancel = { 177, 'Backspace' }, -- give up (a used rack item stays in the inventory)
        Cursor = { 47, 'G' }, -- the cursor out for the gizmo, or away to walk and look about
        Snap = { 73, 'X' }, -- snapping on / off (SnapMove, SnapTurn)
        -- Keeps a floor rack on the ground and a wall rack flat on its wall while it moves. The chat
        -- reads T before scripts can hold it off, so a server that has its chat on T may want this
        -- elsewhere.
        Stick = { 245, 'T' },
        Surface = { 19, 'Alt' }, -- a wall rack flat back onto the wall behind it, a floor rack down onto the floor
        Undo = { 20, 'Z' }, -- with Ctrl: undo; Ctrl + Redo: redo
        Redo = { 246, 'Y' },
        Shift = { 21, 'Shift' }, -- held: the arrows nudge five times as far, the wheel turns 15 degrees
        Ctrl = { 36, 'Ctrl' }, -- held: the wheel turns 1 degree
        Up = 172, Down = 173, Left = 174, Right = 175, -- nudge (a wall rack slides along its wall)
        PageUp = 10, PageDown = 11, -- height
    },

    -- The gizmo's own inputs are key mappings (Settings > Key Bindings > FiveM, under the
    -- resource's name), because the game's gizmo listens only to its +gizmo* commands. These are
    -- their defaults; each player can rebind them. The left mouse button grabs, the right one held
    -- looks about, the wheel turns.
    Gizmo = { Move = 'W', Rotate = 'R', Axes = 'Q' },

    SnapMove = 0.05, -- metres a step while snapping is on (a wall rack snaps its height and along the wall)
    SnapTurn = 15.0, -- degrees a step while snapping is on (floor racks; a wall rack keeps its wall's heading)
    Nudge = 0.01, -- metres a frame the arrow keys and Page Up / Page Down move it (Shift x5)
    TurnStep = 5.0, -- degrees a notch of the mouse wheel (Shift + wheel 15, Ctrl + wheel 1)

    -- Metres from the camera the aim ray reaches when a placement starts. The rack must still end
    -- up within Placement.Range of your ped (configs/shared/placement.lua) to be accepted.
    Reach = 8.0,

    -- How far off its surface a rack may sit and still count as on it, metres: a floor rack above
    -- the floor under it, a wall rack's back off the wall behind it.
    FloatTolerance = 0.06,
    WallTolerance = 0.06,

    -- Controls held off every frame while placing, so it never shoots, swaps weapons, opens the
    -- chat or the pause menu. Walking stays: you walk about while placing.
    Disable = {
        10, 11, 14, 15, 16, 17, 19, 20, 24, 25, 36, 37, 44, 45, 47, 73, 99, 100, 115, 116,
        140, 141, 142, 172, 173, 174, 175, 199, 200, 238, 241, 242, 245, 246, 257, 263, 264, 322, 331,
    },
}
