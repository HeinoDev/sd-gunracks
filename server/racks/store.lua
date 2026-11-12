---@type table Console log helper (shared.log): tagged color-coded prints.
local log = require 'shared.log'

---@type table Store module; the table returned at end of file.
local store = {}

-- Every write goes through one guard: oxmysql can either throw or answer nil on a failed query
-- depending on its settings, and the callers roll back on a false, so both cases must read as a
-- failure rather than reach them as an error.

---Run one oxmysql await call, turning a throw or a nil answer into nil.
---@param fn function MySQL.<kind>.await
---@param query string SQL
---@param params table|nil bound values
---@return any|nil result
local function run(fn, query, params)
    local ok, res = pcall(fn, query, params)

    if not ok then
        log.error('store', 'query failed: %s', tostring(res))
        return nil
    end

    return res
end

---Create the sd_gunracks table if it doesn't exist, so the resource is drop-in. Run once at boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS sd_gunracks (
            id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
            model       VARCHAR(64)  NOT NULL,
            x           DOUBLE       NOT NULL,
            y           DOUBLE       NOT NULL,
            z           DOUBLE       NOT NULL,
            heading     FLOAT        NOT NULL DEFAULT 0,
            bucket      INT          NOT NULL DEFAULT 0,
            owner       VARCHAR(64)  NULL,
            owner_name  VARCHAR(100) NULL,
            locked      TINYINT(1)   NOT NULL DEFAULT 1,
            access      LONGTEXT     NULL,
            slots       LONGTEXT     NULL,
            created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            KEY idx_owner (owner),
            KEY idx_bucket (bucket)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
end

---Slots as the JSON object stored in the row: string keys ("1", "4"), because a Lua table with
---holes does not survive json.encode as an array.
---@param slots table<integer, table> slot index -> stored gun
---@return string json
local function encodeSlots(slots)
    local out = {}
    for i, rec in pairs(slots or {}) do
        out[tostring(i)] = rec
    end

    if next(out) == nil then return '{}' end

    return json.encode(out)
end

---The row's slots JSON back into slot index -> stored gun. A broken value loads as an empty rack
---(logged), so one bad row cannot stop the resource booting.
---@param raw string|nil
---@param id integer rack id, for the log line
---@return table<integer, table> slots
local function decodeSlots(raw, id)
    local out = {}

    if type(raw) ~= 'string' or raw == '' then return out end

    local ok, data = pcall(json.decode, raw)

    if not ok or type(data) ~= 'table' then
        log.error('store', 'rack %s has unreadable slots json; loading it empty', tostring(id))
        return out
    end

    for k, rec in pairs(data) do
        local i = math.tointeger(tonumber(k))

        if i and type(rec) == 'table' and type(rec.name) == 'string' then
            out[i] = rec
        end
    end

    return out
end

---The row's access JSON ({ jobs = { name = minGrade }, gangs = {...} }), or nil when it has none.
---@param raw string|nil
---@return table|nil access
local function decodeAccess(raw)
    if type(raw) ~= 'string' or raw == '' then return nil end

    local ok, data = pcall(json.decode, raw)

    if not ok or type(data) ~= 'table' then return nil end

    return data
end

---A TINYINT(1) as oxmysql hands it over (boolean or 0/1) as a boolean.
---@param v any
---@return boolean
local function bool(v)
    return v == true or v == 1 or v == '1'
end

---Every rack in the table, decoded into the registry's shape.
---@return table[] racks
function store.loadAll()
    local rows = run(MySQL.query.await, 'SELECT * FROM sd_gunracks') or {}
    local out = {}
    for _, row in ipairs(rows) do
        local created = tonumber(row.created_at)

        -- oxmysql dates arrive in ms
        if created and created > 1e11 then
            created = math.floor(created / 1000)
        end

        out[#out + 1] = {
            id = math.tointeger(tonumber(row.id)),
            model = row.model,
            coords = vector3(tonumber(row.x) or 0.0, tonumber(row.y) or 0.0, tonumber(row.z) or 0.0),
            heading = tonumber(row.heading) or 0.0,
            bucket = math.tointeger(tonumber(row.bucket)) or 0,
            owner = row.owner,
            ownerName = row.owner_name,
            locked = bool(row.locked),
            access = decodeAccess(row.access),
            slots = decodeSlots(row.slots, row.id),
            createdAt = created or os.time(),
        }
    end

    return out
end

---Insert a new rack row.
---@param r table { model, coords, heading, bucket, owner?, ownerName?, locked, access?, slots }
---@return integer|nil id the new row id, nil on failure
function store.insert(r)
    local id = run(MySQL.insert.await,
        'INSERT INTO sd_gunracks (model, x, y, z, heading, bucket, owner, owner_name, locked, access, slots) '
            .. 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        {
            r.model,
            r.coords.x,
            r.coords.y,
            r.coords.z,
            r.heading,
            r.bucket,
            r.owner,
            r.ownerName,
            r.locked and 1 or 0,
            r.access and json.encode(r.access) or nil,
            encodeSlots(r.slots),
        })

    return math.tointeger(tonumber(id))
end

---Delete a rack row.
---@param id integer
---@return boolean ok
function store.delete(id)
    return run(MySQL.update.await, 'DELETE FROM sd_gunracks WHERE id = ?', { id }) ~= nil
end

---Write a rack's slots (write-through after every store/take).
---@param id integer
---@param slots table<integer, table>
---@return boolean ok
function store.saveSlots(id, slots)
    return run(MySQL.update.await, 'UPDATE sd_gunracks SET slots = ? WHERE id = ?', { encodeSlots(slots), id }) ~= nil
end

---Write a rack's lock state.
---@param id integer
---@param locked boolean
---@return boolean ok
function store.saveLocked(id, locked)
    return run(MySQL.update.await, 'UPDATE sd_gunracks SET locked = ? WHERE id = ?', { locked and 1 or 0, id }) ~= nil
end

---Write a rack's access list (nil clears it).
---@param id integer
---@param access table|nil { jobs = { name = minGrade }, gangs = {...} }
---@return boolean ok
function store.saveAccess(id, access)
    return run(MySQL.update.await, 'UPDATE sd_gunracks SET access = ? WHERE id = ?',
        { access and json.encode(access) or nil, id }) ~= nil
end

---Write a rack's owner and the name shown for them, together, so a rack is never left owned by
---one character under another's name.
---@param id integer
---@param owner string|nil character id
---@param ownerName string|nil
---@return boolean ok
function store.saveOwner(id, owner, ownerName)
    return run(MySQL.update.await, 'UPDATE sd_gunracks SET owner = ?, owner_name = ? WHERE id = ?',
        { owner, ownerName, id }) ~= nil
end


-- The audit trail the console's Logs tab reads (configs/server/logs.lua Database). Written by
-- server/racks/audit.lua for every event it logs; read a page at a time, newest first.

---@type boolean True once the log table is known to exist: audit writes nothing before that, so a
---first boot's earliest events cannot hit a missing table.
local logReady = false

---Create the sd_gunracks_log table if it doesn't exist. Run once at boot, after the racks load.
function store.ensureLogSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS sd_gunracks_log (
            id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
            at      INT UNSIGNED NOT NULL,
            kind    VARCHAR(32)  NOT NULL,
            actor   VARCHAR(120) NULL,
            cid     VARCHAR(64)  NULL,
            src     INT          NULL,
            rack    INT UNSIGNED NULL,
            detail  VARCHAR(255) NOT NULL DEFAULT '',
            data    TEXT         NULL,
            PRIMARY KEY (id),
            KEY idx_kind (kind),
            KEY idx_rack (rack),
            KEY idx_at (at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    logReady = true
end

---@return boolean true once the log table exists
function store.logReady()
    return logReady
end

---Append one audit row. Fire-and-forget (no await): it is called from inside rack changes and the
---rate limiter, which must not yield on a log write.
---@param row { at: integer, kind: string, actor?: string, cid?: string, src?: integer, rack?: integer, detail: string, data?: string }
function store.insertLog(row)
    if not logReady then return end

    local ok, err = pcall(MySQL.insert,
        'INSERT INTO sd_gunracks_log (at, kind, actor, cid, src, rack, detail, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        {
            row.at,
            row.kind:sub(1, 32),
            row.actor and row.actor:sub(1, 120) or nil,
            row.cid and row.cid:sub(1, 64) or nil,
            row.src,
            row.rack,
            (row.detail or ''):sub(1, 255),
            row.data,
        })

    if not ok then
        log.error('store', 'audit row not written: %s', tostring(err))
    end
end

---A search term as a LIKE pattern that matches it anywhere, with LIKE's own wildcards (and the
---escape character) in it taken literally.
---@param q string
---@return string pattern
local function contains(q)
    return '%' .. q:gsub('[\\%%_]', '\\%0') .. '%'
end

---The WHERE clause for a log filter, and its values in order.
---@param f { kind?: string, rack?: integer, q?: string }
---@return string where '' or ' WHERE ...'
---@return any[] params
local function logWhere(f)
    local parts, params = {}, {}

    if f.kind then
        parts[#parts + 1] = 'kind = ?'
        params[#params + 1] = f.kind
    end

    if f.rack then
        parts[#parts + 1] = 'rack = ?'
        params[#params + 1] = f.rack
    end

    if f.q then
        local like = contains(f.q)
        parts[#parts + 1] = '(actor LIKE ? OR cid LIKE ? OR detail LIKE ?)'
        params[#params + 1], params[#params + 2], params[#params + 3] = like, like, like
    end

    if #parts == 0 then return '', params end

    return ' WHERE ' .. table.concat(parts, ' AND '), params
end

---How many log rows a filter matches.
---@param f { kind?: string, rack?: integer, q?: string }
---@return integer|nil count nil when the read failed
function store.logCount(f)
    local where, params = logWhere(f)
    local n = run(MySQL.scalar.await, 'SELECT COUNT(*) FROM sd_gunracks_log' .. where, params)

    return n ~= nil and math.tointeger(tonumber(n)) or nil
end

---One page of log rows, newest first.
---@param f { kind?: string, rack?: integer, q?: string }
---@param limit integer
---@param offset integer
---@return table[]|nil rows { id, at, kind, actor, cid, rack, detail }; nil when the read failed
function store.logPage(f, limit, offset)
    local where, params = logWhere(f)

    params[#params + 1], params[#params + 2] = limit, offset

    local query = 'SELECT id, at, kind, actor, cid, rack, detail FROM sd_gunracks_log' .. where
        .. ' ORDER BY id DESC LIMIT ? OFFSET ?'
    local rows = run(MySQL.query.await, query, params)

    if not rows then return nil end

    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {
            id = math.tointeger(tonumber(r.id)) or 0,
            at = math.tointeger(tonumber(r.at)) or 0,
            kind = r.kind or '',
            actor = r.actor,
            cid = r.cid,
            rack = math.tointeger(tonumber(r.rack)),
            detail = r.detail or '',
        }
    end

    return out
end

---Every kind on record with its row count (one rack's, when given): the Logs tab's filter pills.
---@param rack integer|nil
---@return { kind: string, count: integer }[]|nil kinds nil when the read failed
function store.logKinds(rack)
    local where, params = logWhere({ rack = rack })
    local rows = run(MySQL.query.await,
        'SELECT kind, COUNT(*) AS n FROM sd_gunracks_log' .. where .. ' GROUP BY kind ORDER BY kind', params)

    if not rows then return nil end

    local out = {}
    for i, r in ipairs(rows) do
        out[i] = { kind = r.kind or '', count = math.tointeger(tonumber(r.n)) or 0 }
    end

    return out
end

---Delete what the retention limits no longer keep: rows past the newest `maxRows`, and rows older
---than `maxDays`. A limit of 0 keeps everything on that count.
---@param maxRows integer
---@param maxDays integer
---@return integer deleted rows deleted (as far as the database said)
function store.pruneLogs(maxRows, maxDays)
    local deleted = 0

    if maxRows > 0 then
        local top = math.tointeger(tonumber(run(MySQL.scalar.await, 'SELECT MAX(id) FROM sd_gunracks_log')))

        if top and top > maxRows then
            local n = run(MySQL.update.await, 'DELETE FROM sd_gunracks_log WHERE id <= ?', { top - maxRows })

            deleted = deleted + (tonumber(n) or 0)
        end
    end

    if maxDays > 0 then
        local n = run(MySQL.update.await, 'DELETE FROM sd_gunracks_log WHERE at < ?', { os.time() - maxDays * 86400 })

        deleted = deleted + (tonumber(n) or 0)
    end

    return deleted
end

return store
