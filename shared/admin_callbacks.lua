---Every staff console call that goes from the page to the server. The client relays each one
---(`admin:<name>` -> `sd-gunracks:server:admin:<name>`; teleport is relayed by hand, because the
---client moves the admin when the server answers), and the server answers each one, gated on the
---staff ace and paced. server/racks/admin.lua checks this list against its handlers at start and
---says which is missing from which.
return {
    'getOverview',
    'getCatalog',
    'getRacks',
    'getRack',
    'searchWeapons',
    'getPlayers',
    'getLogs',

    'teleport',
    'setLocked',
    'setAccess',
    'transfer',
    'takeGun',
    'deleteRack',
    'giveItem',
}
