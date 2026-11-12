-- Aggregate config root, loaded by both sides via `require 'configs.config'`.
-- Scope-by-folder: configs/shared/ is read by client + server, configs/client/ is client-only,
-- and configs/server/ holds the rules the server enforces - excluded from fxmanifest files{}, so it
-- never ships to a client. The server-only files are deep-merged below on the server ONLY.
local config = {
    Locale = 'en', -- lib.locale loads locales/<Locale>.json, falling back to en per-key
    Debug = false, -- dev logging + target zone outlines; leave off in production

    -- Bridge diagnostics (bridge/shared/debug.lua): very verbose per-call prints from the
    -- framework/inventory/target bridge. Separate from Debug above so gameplay debugging
    -- doesn't drown in bridge traffic. DebugCategories filters by tag when set, e.g.
    -- { ['bridge:inventory'] = true } prints only that category.
    DebugPrints = false,
    -- DebugCategories = { ['bridge:inventory'] = true },

    -- Shared (client + server)
    Racks = require 'configs.shared.racks', -- rack item -> model (labels, mounts and slots come from data/racks.json)
    Weapons = require 'configs.shared.weapons', -- addon weapons (Extra) + weapons no rack ever takes (Blacklist)
    Placement = require 'configs.shared.placement', -- range + spacing, shared so the ghost agrees with the server
    Interact = require 'configs.shared.interact', -- how close you must stand to use a rack

    -- Client-only
    Controls = require 'configs.client.controls', -- the placer: keys, snap steps, reach, tolerances
    Draw = require 'configs.client.draw', -- stream distance, attachments, ghost look
    Targets = require 'configs.client.targets', -- target icons + distances, progress bars

    Sync = { PollMs = 2000 }, -- how often the server looks for players whose bucket/job/gang changed
}

-- Server-only: per-player limits, who may place, rate limits, the force-the-lock economy, police
-- seizing, admin and audit settings. Merged in server-side only.
if IsDuplicityVersion() then
    local function merge(dst, src)
        for k, v in pairs(src) do
            if type(v) == 'table' and type(dst[k]) == 'table' then
                merge(dst[k], v)
            else
                dst[k] = v
            end
        end
    end

    merge(config.Placement, require 'configs.server.placement')
    merge(config.Interact, require 'configs.server.interact')

    config.Admin = require 'configs.server.admin' -- the /gunracks staff console: aces, polls, pacing
    config.Logs = require 'configs.server.logs' -- audit logging toggles, server-side only
end

return config
