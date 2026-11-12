-- Resource loader: a package searcher that maps dotted module names onto the resource folder
-- (`configs.config` -> <resource>/configs/config.lua), desugars CFX-only syntax the stock Lua
-- parser rejects, and loads the chunk. Bridge modules never get here: stubs.lua preloads them.
local H = require 'env'

local L = {}

-- The resource folder is the one above tests/ (this file's own location), unless overridden.
local function resourceDir()
    local file = debug.getinfo(1, 'S').source:gsub('^@', '')
    local dir = file:match('^(.*)[/\\]tests[/\\][^/\\]+$')

    if dir and dir ~= '' then return dir end

    if file:match('^tests[/\\]') then return '.' end -- run as `lua tests/run.lua` from the resource

    return '..' -- run as `lua run.lua` from inside tests/
end

L.resource = os.getenv('GUNRACKS_RESOURCE') or resourceDir()

---Desugar CFX Lua extensions so stock load() accepts the file. The resource itself uses neither
---outside comments today; this is belt-and-braces so a future edit does not break the harness.
---  `hash`  -> joaat("hash")        (backtick hash literals)
---  a?.b    -> a.b                  (safe navigation: approximated as plain indexing; logged)
---@param src string file contents
---@param path string for the log line
---@return string desugared
function L.preprocess(src, path)
    local n1, n2
    src, n1 = src:gsub('`([^`\n]*)`', 'joaat("%1")')
    src, n2 = src:gsub('([%w_%]%)])%?%.([%a_][%w_]*)', '%1.%2')

    if n2 > 0 then
        print(('^3[harness] desugared %d `?.` safe-navigation uses in %s (approximated as plain indexing)'):format(n2, path))
    end

    return src
end

function L.readFile(path)
    local f = io.open(path, 'rb')

    if not f then return nil end

    local s = f:read('a')
    f:close()

    return s
end

local function searcher(name)
    local rel = name:gsub('%.', '/')
    local path = L.resource .. '/' .. rel .. '.lua'
    local src = L.readFile(path)

    if not src then
        return ('\n\tno resource file ' .. path)
    end

    src = L.preprocess(src, path)
    local chunk, err = load(src, '@' .. path)

    if not chunk then
        error(('resource file %s failed to compile: %s'):format(path, err))
    end

    return chunk, path
end

table.insert(package.searchers, 2, searcher)

---Execute a resource script file (fxmanifest-style, not a module) in the fake environment.
function L.runScript(rel)
    local path = L.resource .. '/' .. rel
    local src = L.readFile(path)

    if not src then
        error('missing resource script ' .. path)
    end

    src = L.preprocess(src, path)
    local chunk, err = load(src, '@' .. path)

    if not chunk then
        error(('resource script %s failed to compile: %s'):format(path, err))
    end

    return chunk()
end

---Load the server side the way fxmanifest.lua does: shared bridge init, server bridge init, then
---server/main.lua (which requires configs.config, server.racks.init and every module).
function L.loadServer()
    require 'bridge.shared.init'
    require 'bridge.server.init'
    L.runScript('server/main.lua')
end

return L
