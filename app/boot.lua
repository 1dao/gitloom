-- app/boot.lua — isolated app-module loading and the public export registry.
--
-- `_G` contains one gitloom-owned name: g_exports. Every app/*.lua file runs in
-- its own environment, so a bare top-level assignment is private to that file.
-- Public API is deliberate and visually obvious:
--
--     local function normalise(name) ... end       -- lexical/file-private
--     function g_exports.repo_get(owner, name) ... end
--
-- Every file environment resolves an earlier export by its short name. The
-- lookup comes from g_exports; the short name is never installed in `_G`:
--
--     repo_get(...)                              -- call an exported API
--     function g_exports.repo_get(...) ... end  -- declare an exported API
--
-- Export names are enforced as module_function: app/repo.lua may export only
-- repo_*, while app/auth_ratelimit.lua may export only auth_ratelimit_*.
--
-- The isolation comes from load_script/run_script, NOT from `dofile`. A plain
-- dofile of an app module runs in the root `_G`: its bare names land there, and
-- it then dies on the first `g_exports.x =` because no module is loading. Load
-- app modules with load_script and entry points with run_script.
--
-- To stop that being a trap, this file replaces `dofile`: only scripts/core/
-- (the runtime's own files, which have no gitloom environment) still reaches the
-- native one, and every other path is redirected to load_script. See the bottom
-- of this file.
--
-- Lua 5.1 has no `_ENV` and loadfile has no environment argument, so this file
-- uses setfenv there. Lua 5.2+ receives the same environment through loadfile.
-- Both spellings live in compile() below and nowhere else, so no entry point or
-- test driver has to carry a _VERSION branch of its own.

local inherited_global_mt = getmetatable(_G)
if inherited_global_mt and rawget(inherited_global_mt, '__gitloom_strict') then
    -- A full runtime reload re-executes this file in the same Lua state. Remove
    -- our previous guard first, otherwise STRICT_GLOBALS=0 could not disable it.
    inherited_global_mt = rawget(inherited_global_mt, '__previous')
    setmetatable(_G, inherited_global_mt)
end

-- Keep the proxy identity stable across a runtime reload. Old callbacks may
-- still hold it briefly; replacing its metatable makes them see the new API.
local exports = rawget(_G, 'g_exports')
local previous_exports_mt = nil
if exports ~= nil then
    previous_exports_mt = type(exports) == 'table' and getmetatable(exports) or nil
    if not previous_exports_mt or not rawget(previous_exports_mt, '__gitloom_exports') then
        error("global 'g_exports' already exists and is not owned by gitloom")
    end
else
    exports = {}
    rawset(_G, 'g_exports', exports)
end

-- `dofile` is replaced at the bottom of this file. A runtime reload re-executes
-- this chunk, so recover the real one from the previous load; capturing
-- `_G.dofile` unconditionally would wrap our own wrapper one layer deeper every
-- time. The stable proxy's metatable is the one place that survives a reload.
local native_dofile = (previous_exports_mt and rawget(previous_exports_mt, '__gitloom_dofile'))
                      or rawget(_G, 'dofile')

-- The loader cannot be loaded through the function it defines, and a reload
-- re-enters it by path, so it has to be able to recognise its own name.
local self_path = 'app/boot.lua'
if type(debug) == 'table' and debug.getinfo then
    local info = debug.getinfo(1, 'S')
    local src = info and info.source
    if type(src) == 'string' and src:sub(1, 1) == '@' then self_path = src:sub(2) end
end

local export_values = {}
local loading_module = nil
local loading_exports = nil   -- names this load registered, for rollback
local module_names = {}       -- module name -> true, for prefix ownership
setmetatable(exports, {
    __gitloom_exports = true,
    __gitloom_dofile = native_dofile,

    __index = function(_, name)
        return export_values[name]
    end,

    -- The proxy deliberately has no raw API fields, so __newindex runs for
    -- every assignment, including an attempted overwrite of an existing name.
    __newindex = function(_, name, value)
        if type(name) ~= 'string' or name == '' then
            error('export name must be a non-empty string', 2)
        end
        if export_values[name] ~= nil then
            error("duplicate export: '" .. name .. "'", 2)
        end
        if value == nil then
            error("cannot export nil as '" .. name .. "'", 2)
        end
        if not loading_module then
            error("exports may only be declared while loading a module", 2)
        end

        -- A leading "__" marks a test-only hook. Strip it only for ownership
        -- validation: __browse_path_ok still belongs to browse.lua, but callers
        -- can tell immediately that it is not an application API.
        local api_name = name:sub(1, 2) == '__' and name:sub(3) or name
        local prefix = loading_module .. '_'
        if not api_name:match('^[a-z][a-z0-9_]*$') or
           api_name:sub(1, #prefix) ~= prefix or #api_name == #prefix then
            error(string.format(
                "invalid export '%s' in module '%s' (expected %s<function> or __%s<test_hook>)",
                name, loading_module, prefix, prefix), 2)
        end

        -- The longer module name wins. auth_ratelimit_check belongs to
        -- auth_ratelimit.lua, even though it also satisfies auth.lua's auth_.
        for other in pairs(module_names) do
            if #other > #loading_module and
               api_name:sub(1, #other + 1) == other .. '_' then
                error(string.format("export '%s' belongs to module '%s', not '%s'",
                    name, other, loading_module), 2)
            end
        end

        export_values[name] = value
        loading_exports[#loading_exports + 1] = name
    end,

    -- Lua 5.2+ honours this. Lua 5.1 ignores __pairs.
    __pairs = function()
        return next, export_values, nil
    end,
})

local loaded = {}
local unpack_values = table.unpack or unpack

-- ---------------------------------------------------------------------------
-- Paths
--
-- Two decisions must not be fooled by spelling: which module a `loaded` entry
-- belongs to, and whether a dofile target is one of the runtime's own scripts
-- (see the bottom of this file). Both fail CLOSED — a path that cannot be
-- reduced to a plain repo-relative one is treated as unrecognised, never as
-- allowed.
--
-- Reduced here: '/' and '\' mixed, repeated separators, '.' and '..' segments,
-- absolute / drive-relative / UNC spellings, and case on Windows.
--
-- NOT reduced, deliberately: anything only the filesystem knows. A junction or
-- a symlink, or an 8.3 short name, still resolves wherever it resolves. Closing
-- that needs a realpath the runtime does not expose (scripts/core/share/xfs.lua
-- offers home, mkdirp, read_file and write_file, and nothing else), and this is
-- module isolation, not a sandbox — the same caveat as in new_environment.
-- ---------------------------------------------------------------------------

-- Windows compares paths case-insensitively and POSIX does not, where folding
-- case would let a genuine 'Scripts/Core' directory pass as the runtime's.
local FOLD_CASE = package.config:sub(1, 1) == '\\'

local function fold(path)
    local s = tostring(path):gsub('\\', '/')
    if FOLD_CASE then s = s:lower() end
    return s
end

-- Reduce to a repo-relative path, or nil when the path is absolute or climbs
-- above the tree. nil always means "not recognised", never "allowed".
local function normalise_path(path)
    if type(path) ~= 'string' or path == '' then return nil end
    local p = fold(path)
    -- /abs, C:/abs, C:relative, //host/share
    if p:find('^/') or p:find('^%a:') then return nil end

    local out = {}
    for segment in p:gmatch('[^/]+') do
        if segment == '.' then                       -- contributes nothing
        elseif segment == '..' then
            if #out == 0 then return nil end         -- climbs above the root
            out[#out] = nil
        else
            out[#out + 1] = segment
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, '/')
end

-- The key a module is remembered under. Two spellings of one file have to be
-- one module, or './app/repo.lua' walks straight past the double-load guard.
local function module_key(path)
    return normalise_path(path) or fold(path)
end


local function new_environment(path)
    local env = {
        g_exports = exports,
    }
    -- Code that deliberately refers to _G stays inside the module environment;
    -- this is architectural isolation, not a security sandbox.
    env._G = env

    local mt = {
        __gitloom_path = path,

        __index = function(_, name)
            -- Read through the stable proxy rather than this boot's backing
            -- table. After a full runtime reload, a briefly surviving callback
            -- therefore resolves dependencies from the newly loaded API.
            local value = exports[name]
            if value ~= nil then return value end

            value = rawget(_G, name)
            if value ~= nil then return value end

            error(string.format("undefined name '%s' in %s",
                tostring(name), tostring(path)), 2)
        end,
    }
    setmetatable(env, mt)
    return env
end

-- Close an environment to NEW names once its chunk has finished. `__newindex`
-- only fires for absent keys, so file state created while the chunk ran stays
-- writable; a name appearing for the first time at runtime is a typo
-- (`verify_cach = {}`) and now says so instead of quietly becoming file state.
--
-- STRICT_GLOBALS guards the root `_G`, which holds one name and which almost no
-- app code touches. This is the same guarantee for the environments where the
-- code actually lives.
local function seal(env)
    local mt = getmetatable(env)
    mt.__newindex = function(_, name)
        error(string.format("undefined name '%s' assigned after load in %s",
            tostring(name), tostring(mt.__gitloom_path)), 2)
    end
end

-- The one place either environment spelling appears. Errors leave at level 0
-- because loadfile's message already names the file and line.
local function compile(path, env)
    local chunk, err
    if _VERSION == 'Lua 5.1' then
        chunk, err = loadfile(path)
        if chunk then setfenv(chunk, env) end
    else
        chunk, err = loadfile(path, 't', env)
    end
    if not chunk then error(err, 0) end
    return chunk
end

-- `#results` is undefined once a returned nil puts a hole in the table, so the
-- count travels with the values.
local function pack_results(...)
    return { n = select('#', ...), ... }
end

-- pcall unwinds before the handler sees anything, so a module that breaks
-- reports one line with no call site inside it. Capture the stack while the
-- frames still exist.
local traceback = type(debug) == 'table' and debug.traceback or nil

local function with_traceback(err)
    if traceback and type(err) == 'string' then return traceback(err, 2) end
    return err
end

local function load_script(path)
    local key = module_key(path)
    if loaded[key] then
        error("app module already loaded: '" .. tostring(path) .. "'", 2)
    end

    local module_name = tostring(path):gsub('\\', '/'):match('([^/]+)%.lua$')
    if not module_name then
        error("cannot derive module name from path: '" .. tostring(path) .. "'", 2)
    end
    module_name = module_name:gsub('[^%w_]', '_'):lower()
    if loading_module then
        error("cannot load a module while another module is loading", 2)
    end

    local env = new_environment(path)
    local chunk = compile(path, env)

    loading_module, loading_exports = module_name, {}
    local results = pack_results(xpcall(chunk, with_traceback))
    local declared = loading_exports
    loading_module, loading_exports = nil, nil

    if not results[1] then
        -- Half a module's exports are worse than none of them: the next attempt
        -- would report 'duplicate export' instead of the fault that actually
        -- stopped this one. Undo what this load registered before re-raising.
        for i = 1, #declared do export_values[declared[i]] = nil end
        error(results[2], 0)   -- level 0: the traceback already carries the site
    end

    module_names[module_name] = true
    loaded[key] = env
    seal(env)
    return unpack_values(results, 2, results.n)
end

-- Run a script that consumes the API but exports nothing: the entry point and
-- the test drivers. Same environment and the same seal as a module, without the
-- export bookkeeping — and deliberately without a pcall, so a failing entry
-- point surfaces with its own traceback rather than one this file rewrote.
local function run_script(path, ...)
    local env = new_environment(path)
    local results = pack_results(compile(path, env)(...))
    seal(env)
    return unpack_values(results, 1, results.n)
end

-- ---------------------------------------------------------------------------
-- dofile
--
-- Native dofile is the wrong tool for an app module, and it fails in the worst
-- order: the chunk runs in the root `_G`, so its bare names land there, and only
-- then does it die on the first `g_exports.x =` because no module is loading. A
-- leak, and then a crash that does not mention the leak. Since nobody wants that
-- outcome, dofile of anything outside scripts/core/ is redirected to load_script
-- rather than left as a trap.
--
-- scripts/core/ keeps the native one. Those files are a copied subset of the
-- xnet2lua runtime, shared with it verbatim, and they have no gitloom
-- environment to run in; app/util.lua, app/proc.lua, app/http.lua, app/api.lua
-- and app/stream.lua all pull runtime helpers in that way, as do the runtime's
-- own scripts when they load each other.
-- ---------------------------------------------------------------------------
-- The test runs on the normalised path (see Paths, above) and fails CLOSED. It
-- used to match '/scripts/core/' anywhere in the raw string, which let
-- 'scripts/core/../../app/repo.lua' through to native dofile: a guard that
-- fails open is worse than no guard, because it reads as though it were
-- checking something.
local RUNTIME_DIR = 'scripts/core/'

local function is_runtime_script(path)
    local p = normalise_path(path)
    return p ~= nil and p:sub(1, #RUNTIME_DIR) == RUNTIME_DIR
end

-- A reload re-enters this file by path, so recognise it whatever the spelling.
local self_relative = normalise_path(self_path)
local self_folded = fold(self_path)

local function is_self(path)
    local p = normalise_path(path)
    if p ~= nil and self_relative ~= nil then return p == self_relative end
    return fold(path) == self_folded
end

rawset(_G, 'dofile', function(path)
    if path == nil then return native_dofile() end
    if is_runtime_script(path) or is_self(path) then return native_dofile(path) end
    return load_script(path)
end)

local strict = false

-- Neither runtime backend puts a metatable on `_G` today, so these two only
-- matter if the host ever adds one: strict mode has to tighten what the host
-- does, not silently replace it.
local function previous_read(t, name)
    local h = inherited_global_mt and rawget(inherited_global_mt, '__index')
    if type(h) == 'function' then return h(t, name) end
    if h ~= nil then return h[name] end
    return nil
end

local function previous_write(t, name, value)
    local h = inherited_global_mt and rawget(inherited_global_mt, '__newindex')
    if type(h) == 'function' then h(t, name, value); return true end
    if h ~= nil then h[name] = value; return true end
    return false
end

local function strict_enable()
    if strict then return end
    setmetatable(_G, {
        __gitloom_strict = true,
        __previous = inherited_global_mt,

        __index = function(t, name)
            local value = previous_read(t, name)
            if value ~= nil then return value end
            error(string.format("undefined global read: '%s'", tostring(name)), 2)
        end,

        __newindex = function(t, name, value)
            if previous_write(t, name, value) then return end
            error(string.format(
                "undefined global write: '%s' (export through g_exports)",
                tostring(name)), 2)
        end,
    })
    strict = true
end

local function strict_disable()
    if not strict then return end
    setmetatable(_G, inherited_global_mt)
    strict = false
end

return {
    new_environment = new_environment,
    load_script = load_script,
    run_script = run_script,
    strict_enable = strict_enable,
    __strict_disable = strict_disable,
    __is_runtime_script = is_runtime_script,
}
