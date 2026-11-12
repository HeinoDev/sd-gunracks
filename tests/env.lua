-- Fake FiveM / ox_lib / oxmysql environment for running sd-gunracks' SERVER side under stock
-- Lua 5.4: players with peds, routing buckets and aces, events, callbacks, commands and exports, a
-- JSON encoder and decoder, and an in-memory sd_gunracks table behind the MySQL stub. Everything
-- time-based runs on one fake clock (H.now, ms): GetGameTimer reads it, os.time derives from it,
-- CreateThread'd loops run as coroutines that yield on Wait() and are resumed by H.run(ms), and
-- SetTimeout callbacks are queued on it.
local H = {}

H.now = 0
H.epoch = 1700000000
H.verbose = false
H.logbuf = {}
H.LOGBUF_MAX = 60

H.records = {
    client   = {},
    notify   = {},
    audit    = {},
    usable   = {},
}
H.callbacks = {}
H.commands = {}
H.handlers = {}
H.players = {}
H.entities = {}
H.nextHandle = 1
H.tasks = {}
H.timeouts = {}
H.threads = {}
H.errors = {}

local rawprint = print
function H.out(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end

    io.stdout:write(table.concat(parts, '\t'), '\n')
    io.stdout:flush()
end

local function stripColors(s) return (tostring(s):gsub('%^%d', '')) end
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = stripColors((select(i, ...)))
    end

    local line = table.concat(parts, '\t')
    H.logbuf[#H.logbuf + 1] = ('[t=%.1fs] %s'):format(H.now / 1000, line)

    if #H.logbuf > H.LOGBUF_MAX then
        table.remove(H.logbuf, 1)
    end

    if H.verbose then
        H.out(line)
    end
end

function H.dumpLog()
    H.out('---- last resource log lines ----')
    for _, l in ipairs(H.logbuf) do
        H.out('  ' .. l)
    end

    H.out('---------------------------------')
end

local vmt = {}
local function vec3(x, y, z)
    return setmetatable({ x = (x or 0) + 0.0, y = (y or 0) + 0.0, z = (z or 0) + 0.0 }, vmt)
end

vmt.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
vmt.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vmt.__mul = function(a, b)
    if type(a) == 'number' then
        return vec3(a * b.x, a * b.y, a * b.z)
    end

    return vec3(a.x * b, a.y * b, a.z * b)
end

vmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
vmt.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
vmt.__tostring = function(a) return ('vec3(%.2f, %.2f, %.2f)'):format(a.x, a.y, a.z) end
_G.vec3 = vec3
_G.vector3 = vec3
H.vec3 = vec3

function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'sd-gunracks' end
function GetGameTimer() return H.now end
function GetResourceState() return 'started' end
function GetInvokingResource() return nil end
_G.source = nil
H.exports = {}
_G.exports = setmetatable({}, {
    __index = function() return setmetatable({}, { __index = function() return function() end end }) end,
    __call = function(_, name, fn) H.exports[name] = fn end,
})

local realTime = os.time
os.time = function(t)
    if t then
        return realTime(t)
    end

    return H.epoch + (H.now // 1000)
end

-- Deterministic randomness: seed once for real, then make the resource's own seeding a no-op.
math.randomseed(1337)
math.randomseed = function() end

function joaat(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = (h ~ (h >> 6)) & 0xFFFFFFFF
    end

    h = (h + (h << 3)) & 0xFFFFFFFF
    h = (h ~ (h >> 11)) & 0xFFFFFFFF
    h = (h + (h << 15)) & 0xFFFFFFFF

    if h >= 0x80000000 then
        h = h - 0x100000000
    end

    return h
end

GetHashKey = joaat

-- A small JSON encoder and decoder, standing in for the one FiveM provides.
json = {}

local function jenc(v, seen)
    local t = type(v)

    if t == 'nil' then
        return 'null'
    elseif t == 'boolean' then
        return tostring(v)
    elseif t == 'number' then
        return (math.type(v) == 'integer') and tostring(v) or ('%.14g'):format(v)
    elseif t == 'string' then
        return '"' .. v:gsub('[%c"\\]', function(c) return ('\\u%04x'):format(c:byte()) end) .. '"'
    elseif t == 'table' then
        seen = seen or {}

        if seen[v] then return '"<cycle>"' end

        seen[v] = true

        local isArr = #v > 0 or next(v) == nil
        local parts = {}

        if isArr then
            for _, x in ipairs(v) do
                parts[#parts + 1] = jenc(x, seen)
            end

            return '[' .. table.concat(parts, ',') .. ']'
        end

        for k, x in pairs(v) do
            parts[#parts + 1] = jenc(tostring(k), seen) .. ':' .. jenc(x, seen)
        end

        return '{' .. table.concat(parts, ',') .. '}'
    end

    return '"' .. tostring(v) .. '"'
end

function json.encode(v)
    return jenc(v)
end

---Objects, arrays, strings with escapes, numbers and literals.
function json.decode(s)
    local pos = 1

    local function ws()
        pos = s:find('[^ \t\r\n]', pos) or (#s + 1)
    end

    local val

    local function str()
        pos = pos + 1

        local out = {}

        while true do
            local c = s:sub(pos, pos)

            if c == '"' then
                pos = pos + 1
                break
            end

            if c == '\\' then
                local e = s:sub(pos + 1, pos + 1)

                if e == 'u' then
                    out[#out + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16))
                    pos = pos + 6
                else
                    local map = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' }

                    out[#out + 1] = map[e] or e
                    pos = pos + 2
                end
            elseif c == '' then
                error('unterminated string')
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end

        return table.concat(out)
    end

    function val()
        ws()

        local c = s:sub(pos, pos)

        if c == '{' then
            pos = pos + 1

            local t = {}

            ws()

            if s:sub(pos, pos) == '}' then
                pos = pos + 1
                return t
            end

            while true do
                ws()

                local k = str()

                ws()
                pos = pos + 1 -- ':'
                t[k] = val()
                ws()

                local d = s:sub(pos, pos)

                pos = pos + 1

                if d == '}' then return t end
            end
        elseif c == '[' then
            pos = pos + 1

            local t = {}

            ws()

            if s:sub(pos, pos) == ']' then
                pos = pos + 1
                return t
            end

            while true do
                t[#t + 1] = val()
                ws()

                local d = s:sub(pos, pos)

                pos = pos + 1

                if d == ']' then return t end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(pos, pos + 3) == 'true' then
            pos = pos + 4
            return true
        elseif s:sub(pos, pos + 4) == 'false' then
            pos = pos + 5
            return false
        elseif s:sub(pos, pos + 3) == 'null' then
            pos = pos + 4
            return nil
        else
            local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)

            if not num or num == '' then
                error('bad json at ' .. pos .. ': ' .. s:sub(pos, pos + 20))
            end

            pos = pos + #num

            return math.tointeger(tonumber(num)) or tonumber(num)
        end
    end

    return val()
end

function H.resume(co, ...)
    local ok, waitMs = coroutine.resume(co, ...)

    if not ok then
        local msg = debug.traceback(co, tostring(waitMs))
        H.errors[#H.errors + 1] = msg
        print('^1[harness] thread error: ' .. msg)
        H.threads[co] = nil
        return
    end

    if coroutine.status(co) == 'dead' then
        H.threads[co] = nil
        return
    end

    H.tasks[#H.tasks + 1] = { co = co, wakeAt = H.now + (tonumber(waitMs) or 0) }
end

function CreateThread(fn)
    local co = coroutine.create(fn)
    H.threads[co] = true
    H.resume(co)
end

Citizen = { CreateThread = CreateThread }

function Wait(ms)
    local co, isMain = coroutine.running()

    if isMain or not H.threads[co] then
        H.now = H.now + (tonumber(ms) or 0)
        return
    end

    coroutine.yield(tonumber(ms) or 0)
end

Citizen.Wait = Wait

function SetTimeout(ms, fn)
    H.timeouts[#H.timeouts + 1] = { at = H.now + (tonumber(ms) or 0), fn = fn }
end

Citizen.SetTimeout = SetTimeout

---Advance the fake clock WITHOUT running any thread/timeout (a pure time jump).
function H.advance(ms)
    H.now = H.now + ms
end

---Run the world for `ms`: every thread whose Wait elapsed and every SetTimeout due inside the
---window fires in time order (a loop that waits 1 s runs once for each second of it).
function H.run(ms)
    local target = H.now + ms
    local guard = 0
    while true do
        local bestAt, kind, idx
        for i, t in ipairs(H.tasks) do
            if t.wakeAt <= target and (not bestAt or t.wakeAt < bestAt) then
                bestAt, kind, idx = t.wakeAt, 'task', i
            end
        end

        for i, t in ipairs(H.timeouts) do
            if t.at <= target and (not bestAt or t.at < bestAt) then
                bestAt, kind, idx = t.at, 'timeout', i
            end
        end

        if not bestAt then break end

        if bestAt > H.now then
            H.now = bestAt
        end

        if kind == 'task' then
            local t = table.remove(H.tasks, idx)
            H.resume(t.co)
        else
            local t = table.remove(H.timeouts, idx)
            local ok, err = xpcall(t.fn, debug.traceback)

            if not ok then
                H.errors[#H.errors + 1] = err
                print('^1[harness] timeout error: ' .. err)
            end
        end

        guard = guard + 1

        if guard > 2000000 then
            error('harness scheduler runaway')
        end
    end

    H.now = target
end

function H.spawn(kind, model, x, y, z, heading)
    local handle = H.nextHandle
    H.nextHandle = H.nextHandle + 1
    H.entities[handle] = { handle = handle, kind = kind, model = model, pos = vec3(x, y, z), heading = heading or 0.0 }

    return handle
end

function GetEntityCoords(h)
    local r = H.entities[h]

    return r and r.pos or vec3(0, 0, 0)
end

H.buckets = {}
function GetPlayerRoutingBucket(src) return H.buckets[tonumber(src)] or 0 end
H.admins = {}
---Aces a player holds one by one (src -> { [ace] = true }), for players who are not in the admin
---group but were granted something on its own (configs/server/admin.lua Ace).
H.aces = {}
---Like the live server: an allowed ace answers the NUMBER 1, a refused one false. Admins hold
---every ace (the group the command is restricted to); anyone else only what H.aces grants them.
function IsPlayerAceAllowed(src, ace)
    src = tonumber(src)

    if H.admins[src] or (H.aces[src] and H.aces[src][ace]) then return 1 end

    return false
end

function H.addPlayer(src, opts)
    opts = opts or {}
    local ped = H.spawn('ped', 'mp_m_freemode_01', opts.x or 0.0, opts.y or 0.0, opts.z or 0.0, 0.0)
    H.players[src] = {
        src = src, ped = ped, name = opts.name or ('Player' .. src),
        job = opts.job or 'unemployed', grade = opts.grade or 0,
        gang = opts.gang, gangGrade = opts.gangGrade or 0,
    }
    H.buckets[src] = opts.bucket or 0
    H.admins[src] = opts.admin or nil

    return H.players[src]
end

function H.setPos(src, pos)
    local p = H.players[src]

    H.entities[p.ped].pos = vec3(pos.x, pos.y, pos.z)
end

function GetPlayers()
    local ids = {}
    for src in pairs(H.players) do
        ids[#ids + 1] = src
    end

    table.sort(ids)
    for i, v in ipairs(ids) do
        ids[i] = tostring(v)
    end

    return ids
end

function GetPlayerPed(src)
    local p = H.players[tonumber(src)]
    return p and p.ped or 0
end

function GetPlayerName(src)
    local p = H.players[tonumber(src)]
    return p and p.name or nil
end

function TriggerClientEvent(name, target, ...)
    H.records.client[#H.records.client + 1] = { name = name, target = target, payload = (...), args = { ... }, at = H.now }
end

function RegisterNetEvent(name, fn)
    if fn then
        H.handlers[name] = H.handlers[name] or {}
        table.insert(H.handlers[name], fn)
    end
end

function AddEventHandler(name, fn)
    H.handlers[name] = H.handlers[name] or {}
    table.insert(H.handlers[name], fn)
end

RegisterServerEvent = RegisterNetEvent
---Fire a (net) event as if `src` sent it.
function H.fireEvent(name, src, ...)
    local fns = H.handlers[name]

    if not fns then
        error('no handler registered for event ' .. name)
    end

    for _, fn in ipairs(fns) do
        local prev = _G.source
        _G.source = src
        local ok, err = xpcall(fn, debug.traceback, ...)
        _G.source = prev

        if not ok then
            error(err, 0)
        end
    end
end

lib = {
    callback = {
        register = function(name, fn) H.callbacks[name] = fn end,
    },
    locale = function() end,
    addCommand = function(name, props, fn) H.commands[name] = { props = props, fn = fn } end,
    triggerClientEvent = function(name, targets, ...)
        if type(targets) == 'table' then
            for _, t in ipairs(targets) do
                TriggerClientEvent(name, t, ...)
            end
        else
            TriggerClientEvent(name, targets, ...)
        end
    end,
    logger = function(source, event, message, data)
        H.records.audit[#H.records.audit + 1] = { source = source, event = event, message = message, data = data, at = H.now }
    end,
    requestModel = function(m) return m end,
    print = { info = print, warn = print, error = print, debug = print },
}
---Invoke a registered lib.callback as `src`.
function H.call(name, src, ...)
    local fn = H.callbacks[name]

    if not fn then
        error('no callback registered: ' .. name)
    end

    return fn(src, ...)
end

---Invoke a registered lib.addCommand handler as `src`.
function H.command(name, src, args)
    local c = H.commands[name]

    if not c then
        error('no command registered: ' .. name)
    end

    return c.fn(src, args or {}, '')
end

function locale(key, ...)
    local n = select('#', ...)

    if n == 0 then return key end

    local parts = { key }
    for i = 1, n do
        parts[#parts + 1] = tostring((select(i, ...)))
    end

    return table.concat(parts, ' ')
end

-- An in-memory sd_gunracks table (and sd_gunracks_log beside it) that understands exactly the
-- statements server/racks/store.lua sends. `H.db.latency` makes every await yield (Wait) inside a
-- thread, which is how the race scenarios get two requests interleaved; `H.db.failNext[kind] = n`
-- makes the next n statements of that kind fail the way oxmysql does (an error the store's pcall
-- turns into nil). Log rows go to `H.db.logRows`, in id order.
H.db = { rows = {}, nextId = 1, latency = 0, failNext = {}, log = {}, logRows = {}, logNext = 1 }
function H.dbReset()
    H.db.rows, H.db.nextId, H.db.latency, H.db.failNext, H.db.log = {}, 1, 0, {}, {}
    H.db.logRows, H.db.logNext = {}, 1
end

local function dbStep(kind, sql)
    H.db.log[#H.db.log + 1] = sql

    if H.db.latency > 0 then
        Wait(H.db.latency)
    end

    local n = H.db.failNext[kind]

    if n and n > 0 then
        H.db.failNext[kind] = n - 1
        error(('fake db: %s failed'):format(kind))
    end
end

local function norm(sql) return (sql:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')) end
local function copyRow(r)
    local o = {}

    for k, v in pairs(r) do
        o[k] = v
    end

    return o
end

---The filter a log statement's WHERE clause names, read back out of its params in the order
---store.lua's logWhere writes them (kind, rack, then the three LIKEs of a search).
---@return table filter { kind?, rack?, like? }
---@return integer next index of the first param after the WHERE values
local function logFilter(sql, params)
    local f, i = {}, 1

    if sql:find('kind = ?', 1, true) then
        f.kind = params[i]
        i = i + 1
    end

    if sql:find('rack = ?', 1, true) then
        f.rack = params[i]
        i = i + 1
    end

    if sql:find('actor LIKE ?', 1, true) then
        f.like = params[i]
        i = i + 3
    end

    return f, i
end

---A LIKE '%...%' pattern back to the text it looks for (backslash escapes undone).
local function unlike(p)
    p = p:gsub('^%%', ''):gsub('%%$', '')
    return (p:gsub('\\(.)', '%1'))
end

local function logMatch(r, f)
    if f.kind and r.kind ~= f.kind then return false end

    if f.rack and r.rack ~= f.rack then return false end

    if f.like then
        local needle = unlike(f.like):lower()
        for _, v in ipairs({ r.actor or '', r.cid or '', r.detail or '' }) do
            if tostring(v):lower():find(needle, 1, true) then return true end
        end

        return false
    end

    return true
end

local function logRowsMatching(f)
    local out = {}

    for _, r in ipairs(H.db.logRows) do
        if logMatch(r, f) then
            out[#out + 1] = r
        end
    end

    return out
end

local function insert(sql, params)
    sql = norm(sql)

    if sql:find('^INSERT INTO sd_gunracks_log ') then
        H.db.log[#H.db.log + 1] = sql
        local cols = sql:match('^INSERT INTO sd_gunracks_log %((.-)%) VALUES')
        local row, i = { id = H.db.logNext }, 0
        for col in cols:gmatch('[%w_]+') do
            i = i + 1
            row[col] = params[i]
        end

        H.db.logNext = H.db.logNext + 1
        H.db.logRows[#H.db.logRows + 1] = row

        return row.id
    end

    dbStep('insert', sql)
    local cols = sql:match('^INSERT INTO sd_gunracks %((.-)%) VALUES')

    if not cols then
        error('fake db: unknown insert ' .. sql)
    end

    local row, i = { id = H.db.nextId, created_at = os.time() * 1000 }, 0
    for col in cols:gmatch('[%w_]+') do
        i = i + 1
        row[col] = params[i]
    end

    H.db.nextId = H.db.nextId + 1
    H.db.rows[row.id] = row

    return row.id
end

MySQL = {
    query = { await = function(sql, params)
        sql = norm(sql)
        dbStep('query', sql)

        if sql:find('^CREATE TABLE') then
            return {}
        end

        if sql == 'SELECT * FROM sd_gunracks' then
            local out = {}
            for _, r in pairs(H.db.rows) do
                out[#out + 1] = copyRow(r)
            end

            table.sort(out, function(a, b) return a.id < b.id end)

            return out
        end

        if sql:find('^SELECT id, at, kind, actor, cid, rack, detail FROM sd_gunracks_log') then
            local f, i = logFilter(sql, params)
            local limit, offset = params[i], params[i + 1]
            local rows = logRowsMatching(f)
            local out = {}
            for n = #rows - offset, math.max(1, #rows - offset - limit + 1), -1 do
                out[#out + 1] = copyRow(rows[n])
            end

            return out
        end

        if sql:find('^SELECT kind, COUNT%(%*%) AS n FROM sd_gunracks_log') then
            local counts = {}
            for _, r in ipairs(logRowsMatching((logFilter(sql, params)))) do
                counts[r.kind] = (counts[r.kind] or 0) + 1
            end

            local out = {}
            for kind, n in pairs(counts) do
                out[#out + 1] = { kind = kind, n = n }
            end

            table.sort(out, function(a, b) return a.kind < b.kind end)

            return out
        end

        error('fake db: unknown query ' .. sql)
    end },
    insert = setmetatable({ await = insert }, {
        -- MySQL.insert(query, params[, cb]) without await: oxmysql runs it and returns at once.
        __call = function(_, sql, params, cb)
            local id = insert(sql, params)

            if cb then
                cb(id)
            end
        end,
    }),
    update = { await = function(sql, params)
        sql = norm(sql)
        dbStep('update', sql)

        if sql == 'DELETE FROM sd_gunracks WHERE id = ?' then
            local had = H.db.rows[params[1]] ~= nil
            H.db.rows[params[1]] = nil
            return had and 1 or 0
        end

        local logCol = sql:match('^DELETE FROM sd_gunracks_log WHERE (%w+) [<=]+ %?$')

        if logCol then
            local inclusive = sql:find('<=', 1, true) ~= nil
            local keep, n = {}, 0
            for _, r in ipairs(H.db.logRows) do
                local v = r[logCol]

                if (inclusive and v <= params[1]) or (not inclusive and v < params[1]) then
                    n = n + 1
                else
                    keep[#keep + 1] = r
                end
            end

            H.db.logRows = keep

            return n
        end

        local sets = sql:match('^UPDATE sd_gunracks SET (.-) WHERE id = %?$')

        if not sets then
            error('fake db: unknown update ' .. sql)
        end

        local cols = {}
        for col in sets:gmatch('([%w_]+) = %?') do
            cols[#cols + 1] = col
        end

        local r = H.db.rows[params[#cols + 1]]

        if not r then return 0 end

        for i, col in ipairs(cols) do
            r[col] = params[i]
        end

        return 1
    end },
    scalar = { await = function(sql, params)
        sql = norm(sql)
        dbStep('scalar', sql)

        if sql:find('^SELECT COUNT%(%*%) FROM sd_gunracks_log') then
            return #logRowsMatching((logFilter(sql, params)))
        end

        if sql == 'SELECT MAX(id) FROM sd_gunracks_log' then
            local last = H.db.logRows[#H.db.logRows]
            return last and last.id or nil
        end

        return nil
    end },
    single = { await = function() return nil end },
    prepare = { await = function() return nil end },
}

function H.mark()
    return #H.records.client
end

---Client events named `name` recorded after index `since` (H.mark()), optionally for one target.
function H.clientEvents(name, since, target)
    local out = {}
    for i = (since or 0) + 1, #H.records.client do
        local r = H.records.client[i]

        if r.name == name and (target == nil or r.target == target) then
            out[#out + 1] = r
        end
    end

    return out
end

function H.auditEvents(event, reason)
    local out = {}
    for _, r in ipairs(H.records.audit) do
        if r.event == event and (reason == nil or (r.data and r.data.reason == reason)) then
            out[#out + 1] = r
        end
    end

    return out
end

function H.clearRecords()
    for k in pairs(H.records) do
        H.records[k] = {}
    end

    H.errors = {}
end

return H
