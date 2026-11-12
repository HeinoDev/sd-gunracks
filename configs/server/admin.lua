-- SERVER-ONLY (not in fxmanifest files{}): the /gunracks staff console.
return {
    -- /gunracks opens the console. ox_lib restricts the command to Group, which it does by adding
    -- the ace `command.gunracks` to that principal.
    Command = 'gunracks',
    Group = 'group.admin',

    -- Who counts as staff for the console's callbacks (and at every rack: staff open any rack): a
    -- player holding this ace, OR the command ace above. Both are asked, because a member of the
    -- group.admin PRINCIPAL does not hold an ace named `group.admin`: IsPlayerAceAllowed(src,
    -- 'group.admin') is false for every admin there is, so a principal written here would match
    -- nobody and the command ace is what lets them in. To give a group the console without
    -- group.admin, grant it both, e.g.
    --   add_ace group.mod command.gunracks allow
    --   add_ace group.mod sd-gunracks.admin allow
    Ace = 'sd-gunracks.admin',

    -- Whether a rack may be deleted from the console at all. Off, staff can still empty it gun by
    -- gun, lock it, give it away and edit who may open it.
    AllowDelete = true,

    MaxGive = 10, -- most rack items one "Give a rack item" hands out

    -- Seconds between automatic refreshes of each tab while it is open (the Racks one also keeps
    -- the rack list every tab reads fresh).
    Poll = {
        Overview = 10,
        Racks = 6,
        Players = 8,
        Logs = 15,
    },

    -- Staff requests are paced like players' are (configs/server/interact.lua RateLimit), on their
    -- own counters: a change at most once every WriteMs, and only one in flight at a time; reads
    -- (the console opening fires several at once) in bursts of up to ReadBurst, refilled at
    -- ReadPerSecond. A refused request is logged as `suspect` like any other.
    RateLimit = {
        WriteMs = 400,
        ReadBurst = 12,
        ReadPerSecond = 6,
    },

    -- The Weapons tab: the most stored guns one search answers with (newest racked first).
    SearchLimit = 200,
}
