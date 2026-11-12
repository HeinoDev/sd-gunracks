---@type table Tagged debug logger for this file (bridge.shared.debug).
local dprint = require('bridge.shared.debug').tag('bridge:init')

dprint('loading bridge.shared.framework...')
require 'bridge.shared.framework'
dprint('bridge.shared.framework loaded')

-- No bridge.shared.locale here (unlike sd-pettycrime): this resource localizes
-- through ox_lib's lib.locale(), wired up in client/main.lua and server/main.lua.
