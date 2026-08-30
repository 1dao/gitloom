-- app/boot.lua — the module convention every other app/ file follows.
--
-- gitloom does NOT use `local M = {} ... return M`. Each app/ module installs
-- its public functions straight onto _G under a short, module-scoped prefix,
-- the way a C translation unit exports a handful of `modname_verb()` symbols
-- and keeps everything else `static`:
--
--     -- app/repo.lua
--     local function normalise(name) ... end        -- static: file-local
--     function repo_dir(owner, name) ... end        -- exported: reachable anywhere
--
-- Why: the call sites read as `repo_dir(...)`, `git_advertise(...)`,
-- `pkt_line(...)` with no import ceremony and no per-file alias block, and
-- there is exactly one instance of every module no matter who loads it first.
-- The cost is that a typo in a name is a silent nil instead of a load error —
-- which is what strict_enable() below buys back.
--
-- RULES
--   1. One prefix per module, declared in its header comment. No module writes
--      a global outside its own prefix.
--   2. Everything not exported is `local`.
--   3. Modules are loaded once, in dependency order, by main.lua. A module may
--      call functions from any module loaded before it, at RUN time; it must
--      not call them at LOAD time.
--   4. After the last module loads, main.lua calls strict_enable(). From then
--      on, reading an undefined global raises instead of returning nil, and
--      creating one requires the explicit `global()` below.
--
-- Exports: global, defined, strict_enable, strict_disable

local declared = {}
local strict = false

-- Define a global after strict mode is on. The only sanctioned way to do it —
-- a bare assignment raises once _G is locked.
function global(name, value)
    declared[name] = true
    rawset(_G, name, value)
end

-- Is this global defined? Safe under strict mode, where a plain read would
-- raise. Use it for genuinely optional things (an xthread build without
-- xdebug, say), never to paper over a typo.
function defined(name)
    return rawget(_G, name) ~= nil
end

-- Freeze _G: from here on an undefined read raises with the offending name, and
-- a new global must come through global(). Call once, after every app/ module
-- has loaded.
--
-- This is the whole safety net for the flat-namespace convention. Without it,
-- `repo_dirr(x)` is a nil call three frames from where the typo lives; with it,
-- the error names the symbol.
function strict_enable()
    if strict then return end
    for k in pairs(_G) do declared[k] = true end
    setmetatable(_G, {
        __index = function(_, k)
            error(string.format("undefined global read: '%s'", tostring(k)), 2)
        end,
        __newindex = function(_, k, _v)
            error(string.format(
                "undefined global write: '%s' (use global('%s', v) if deliberate)",
                tostring(k), tostring(k)), 2)
        end,
    })
    strict = true
end

-- Escape hatch, for a REPL or a test that needs to scribble on _G.
function strict_disable()
    if not strict then return end
    setmetatable(_G, nil)
    strict = false
end
