-- app/cfg.lua — configuration and logging.
--
-- Exports: cfg, cfg_int, cfg_bool, cfg_list,
--          log_system, log_info, log_warn, log_error, log_debug
--
-- Config comes from xutils' key=value store, which is FIRST-WINS: command-line
-- KEY=VAL arguments are already in it by the time we run, so they beat every
-- file, and gitloom.local.cfg is loaded before gitloom.cfg so a developer's
-- local overrides beat the committed defaults. Same ordering as xpauth.

local xutils = require('xutils')

-- Secrets (DB password, admin token) belong in the local file, which is in
-- .gitignore. load_config returns false for a missing file rather than raising,
-- so the call is unconditional.
xutils.load_config('gitloom.local.cfg')
xutils.load_config('gitloom.cfg')

function cfg(key, default)
    return xutils.get_config(key, default)
end

function cfg_int(key, default)
    return tonumber(xutils.get_config(key, tostring(default))) or default
end

-- '1', 'true', 'yes', 'on' are true; everything else, including an unset key
-- with a false default, is false.
function cfg_bool(key, default)
    local v = tostring(xutils.get_config(key, default and '1' or '0')):lower()
    return v == '1' or v == 'true' or v == 'yes' or v == 'on'
end

-- Comma/whitespace separated list -> array. Empty string -> empty table.
function cfg_list(key, default)
    local out = {}
    for item in tostring(xutils.get_config(key, default or '')):gmatch('[^,%s]+') do
        out[#out + 1] = item
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Logging
--
-- xthread.log_init() is what gives THIS thread a log sink; without it every
-- xthread.log_* call from Lua is silently dropped while the C layer keeps
-- printing its own lines — so the service looks like it is logging when none of
-- its own events ever appear. (See the same note in xpauth's main.lua.)
-- ---------------------------------------------------------------------------
xthread.log_init()

local PREFIX = '[GITLOOM] '

local function fmt(f, ...)
    if select('#', ...) == 0 then return PREFIX .. tostring(f) end
    local ok, s = pcall(string.format, tostring(f), ...)
    return PREFIX .. (ok and s or tostring(f))
end

function log_system(f, ...) xthread.log_system(fmt(f, ...)) end
function log_info(f, ...)   xthread.log_info(fmt(f, ...))   end
function log_warn(f, ...)   xthread.log_warn(fmt(f, ...))   end
function log_error(f, ...)  xthread.log_error(fmt(f, ...))  end
function log_debug(f, ...)  xthread.log_debug(fmt(f, ...))  end
