---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'

-- Load translations for this VM from configs/config.lua's `Locale` (en is always loaded first as
-- the per-key fallback). Must run before the modules below build their target labels.
lib.locale(config.Locale)

---@type table Rack sync (client.racks.sync): server lists + deltas into the mirror and the drawing.
local sync = require 'client.racks.sync'
---@type table Rack drawing (client.racks.spawn): torn down on stop.
local spawn = require 'client.racks.spawn'
---@type table Placement mode (client.racks.placement): cancelled on stop.
local placement = require 'client.racks.placement'
---@type table The staff console (client.racks.admin): its NUI callbacks self-register; closed on stop.
local admin = require 'client.racks.admin'
require 'client.racks.menus' -- the police alert event self-registers
---@type table Client helpers (client.racks.util): native booleans.
local util = require 'client.racks.util'

-- Ask for our racks once this client is in the session (also covers a resource restart while
-- playing). Later changes arrive as pushes.
CreateThread(function()
    while not util.yes(NetworkIsPlayerActive(PlayerId())) do
        Wait(250)
    end

    sync.request()
end)

---On resource stop, hand back NUI focus, drop the ghost (and the cursor it took), and delete every
---prop and weapon object this client made.
---@param resource string stopping resource name
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    admin.cleanup()
    placement.cancel(true)
    spawn.cleanupAll()
end)

log.debug(nil, 'client loaded')
