---@type table sd-gunracks config root (configs/config.lua).
local config = require 'configs.config'
---@type table Audit-log helper (server.racks.audit): the `suspect` trail.
local audit = require 'server.racks.audit'

---@type table Rate-limit config (config.Interact.RateLimit).
local CFG = config.Interact.RateLimit or {}

---@type table Limits module; the table returned at end of file.
local limits = {}

---@type table<integer, table<string, integer>> Per player: last accepted GetGameTimer ms per kind,
---plus `suspectAt` (os.time) of the last suspect line, so a spamming client logs once per window.
local last = {}

---@type table<integer, table<string, { tokens: number, at: integer }>> Per player and kind: the
---tokens left in a burst bucket and when it was last topped up (GetGameTimer ms).
local buckets = {}

---The per-player row, made on first use.
---@param src integer
---@return table row
local function rowOf(src)
    local row = last[src]

    if not row then
        row = {}
        last[src] = row
    end

    return row
end

---Log a refusal as `suspect`, at most once per SuspectEverySeconds for a player.
---@param src integer
---@param row table the player's row (carries suspectAt)
---@param kind string
---@param what string how fast, in words
local function suspect(src, row, kind, what)
    local every = CFG.SuspectEverySeconds or 10

    if os.time() - (row.suspectAt or 0) < every then return end

    row.suspectAt = os.time()
    audit.log('suspect', src, ('%s requests faster than %s'):format(kind, what), { reason = 'rate_limited', kind = kind })
end

---Accept or refuse one request from `src` of `kind` ('action' moves guns / changes racks,
---'query' only reads; staff writes pass their own gap). A refused request does not move the
---window, so a client hammering the server stays refused until it slows down.
---@param src integer player server id
---@param kind string
---@param gapMs? integer the shortest gap for this kind; default Query or Action from the config
---@return boolean allowed
function limits.allow(src, kind, gapMs)
    local gap = gapMs or (kind == 'query' and (CFG.Query or 300) or (CFG.Action or 600))
    local now = GetGameTimer()
    local row = rowOf(src)
    local prev = row[kind]

    if prev and now - prev < gap then
        suspect(src, row, kind, ('%d ms'):format(gap))
        return false
    end

    row[kind] = now

    return true
end

---Accept or refuse one request against a burst bucket: up to `capacity` back to back, then
---`perSecond` a second. For the staff console's reads, which come several at once when it opens
---(the rack list, the catalog, the open tab) and then on each tab's poll.
---@param src integer player server id
---@param kind string
---@param capacity number most requests in a burst
---@param perSecond number refill rate
---@return boolean allowed
function limits.burst(src, kind, capacity, perSecond)
    local now = GetGameTimer()
    buckets[src] = buckets[src] or {}
    local b = buckets[src][kind]

    if not b then
        b = { tokens = capacity, at = now }
        buckets[src][kind] = b
    end

    b.tokens = math.min(capacity, b.tokens + (now - b.at) / 1000 * perSecond)
    b.at = now

    if b.tokens < 1 then
        suspect(src, rowOf(src), kind, ('%d in a burst / %d a second'):format(capacity, perSecond))
        return false
    end

    b.tokens = b.tokens - 1

    return true
end

---Forget a departed player (server ids are reused).
---@param src integer player server id
function limits.forget(src)
    last[src] = nil
    buckets[src] = nil
end

return limits
