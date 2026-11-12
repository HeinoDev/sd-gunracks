---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
lib.locale(config.Locale)

-- Loaded for side effects: boot load, callbacks, usable items, the sync loop and the exports.
require 'server.racks.init'
