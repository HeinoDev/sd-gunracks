fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'sd-gunracks'
author 'Samuels Development'
version '1.0.0'
description 'Gun Racks: ten placeable floor, wall and table-top racks that hold real weapons from your inventory, drawn in their slots with attachments and tint'

shared_scripts {
    '@ox_lib/init.lua',
    'bridge/shared/init.lua',
}

client_scripts {
    'bridge/client/init.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server/init.lua',
    'server/main.lua',
}

-- The staff console and the placer's strip (web/, built with `npm run build` into web/build).
ui_page 'web/build/index.html'

-- configs/server/ is deliberately NOT listed: limits, rate limits, the force-the-lock and seize
-- rules, staff and log settings never reach a client. data/racks.json is (both sides read the
-- slots and fits from it). A `dir/**` glob does not match files sitting directly in `dir`, so
-- every folder with top-level files is listed in both forms (web/build has index.html on top and
-- the bundle, its stylesheet and its typefaces under assets/). images/ is the rack pictures the
-- console's Place tab shows. The .ydr racks in stream/ stream automatically; only their archetype
-- file is listed.
files {
    'stream/sd_gunracks.ytyp',
    'data/racks.json',
    'bridge/**.lua',
    'shared/*.lua',
    'shared/**.lua',
    'configs/config.lua',
    'configs/shared/*.lua',
    'configs/shared/**.lua',
    'configs/client/*.lua',
    'configs/client/**.lua',
    'client/*.lua',
    'client/**.lua',
    'locales/*.json',
    'web/build/*',
    'web/build/**',
    'images/*.png',
}

data_file 'DLC_ITYP_REQUEST' 'stream/sd_gunracks.ytyp'

-- Framework (qb-core/qbx_core or es_extended), inventory (ox_inventory, qb-inventory,
-- qs-inventory, tgiann-inventory, ...) and target (ox_target, qb-target, qtarget) are detected at
-- runtime by the bridge, so none of them are hard dependencies. OneSync is: the server reads
-- player positions and routing buckets for every check.
dependencies {
    '/onesync',
    'ox_lib',
    'oxmysql',
}
