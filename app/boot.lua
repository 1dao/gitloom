-- app/boot.lua — isolated app-module loading and the public export registry.
--
-- `_G` contains one gitloom-owned name: g_exports. Every app/*.lua file runs in
-- its own environment, so a bare top-level assignment is private to that file.
-- Public API is deliberate and visually obvious:
--
--     local function normalise(name) ... end       -- lexical/file-private
--     function g_exports.repo_dir(owner, name) ... end
--
-- Every file environment resolves an earlier export by its short name. The
-- lookup comes from g_exports; the short name is never installed in `_G`:
--
--     repo_dir(...)                              -- call an exported API
--     function g_exports.repo_dir(...) ... end  -- declare an exported API
--
-- Export names are enforced as module_function: app/repo.lua may export only
-- repo_*, while app/auth_ratelimit.lua may export only auth_ratelimit_*.
--
-- Lua 5.1 has no `_ENV` and loadfile has no environment argument, so load_script
-- uses setfenv there. Lua 5.2+ receives the same environment through loadfile.

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
if exports ~= nil then
    local mt = type(exports) == 'table' and getmetatable(exports) or nil
    if not mt or not rawget(mt, '__gitloom_exports') then
        error("global 'g_exports' already exists and is not owned by gitloom")
    end
else
    exports = {}
    rawset(_G, 'g_exports', exports)
end

local export_values = {}
local loading_module = nil
setmetatable(exports, {
    __gitloom_exports = true,

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

        local prefix = loading_module .. '_'
        if not name:match('^[a-z][a-z0-9_]*$') or
           name:sub(1, #prefix) ~= prefix or #name == #prefix then
            error(string.format(
                "invalid export '%s' in module '%s' (expected %s<function>)",
                name, loading_module, prefix), 2)
        end
        export_values[name] = value
    end,

    -- Lua 5.2+ honours this. Lua 5.1 ignores __pairs, so callers that need a
    -- portable listing should use boot.export_names() below.
    __pairs = function()
        return next, export_values, nil
    end,
})

local loaded = {}
local unpack_values = table.unpack or unpack

local function new_environment(path)
    local env = {
        g_exports = exports,
    }
    -- Code that deliberately refers to _G stays inside the module environment;
    -- this is architectural isolation, not a security sandbox.
    env._G = env

    setmetatable(env, {
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
    })
    return env
end

local function load_script(path)
    if loaded[path] then
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

    local chunk, err
    if _VERSION == 'Lua 5.1' then
        chunk, err = loadfile(path)
        if chunk then setfenv(chunk, env) end
    else
        chunk, err = loadfile(path, 't', env)
    end
    if not chunk then error(err, 2) end

    loading_module = module_name
    local results = { pcall(chunk) }
    loading_module = nil
    if not results[1] then error(results[2], 2) end
    loaded[path] = env
    return unpack_values(results, 2)
end

local strict = false

local function strict_enable()
    if strict then return end
    setmetatable(_G, {
        __gitloom_strict = true,
        __previous = inherited_global_mt,

        __index = function(_, name)
            error(string.format("undefined global read: '%s'", tostring(name)), 2)
        end,

        __newindex = function(_, name)
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

local function export_names()
    local names = {}
    for name in pairs(export_values) do names[#names + 1] = name end
    table.sort(names)
    return names
end

return {
    exports = exports,
    new_environment = new_environment,
    load_script = load_script,
    export_names = export_names,
    strict_enable = strict_enable,
    strict_disable = strict_disable,
}
