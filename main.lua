-- main.lua — gitloom: a git hosting service on the xnet2lua runtime.
--
-- Phase 0 scope: the git smart-HTTP transport (clone / fetch / push), a
-- repository model on disk, HTTP Basic accounts with access tokens, and a JSON
-- management API. No web UI, no issues, no pull requests — those come later and
-- ride on the same API.
--
-- Run:  bin\xnet.exe main.lua [KEY=VAL ...]      (see gitloom.cfg for keys)
--
-- ARCHITECTURE
--   main thread            the event loop: accept, HTTP parse, routing, and one
--                          coroutine per request
--   WORKER_GRP1..+N        the xproc pool, where every `git` invocation blocks
--
-- Nothing shares state across that boundary: a request coroutine yields on an
-- RPC into a worker, the worker runs one command to completion, and the reply
-- comes back through xrouter. That is why every handler that touches git must
-- run on a coroutine, and why nothing in this file may call git during load.
--
-- MODULE CONVENTION
-- app/*.lua run in separate environments, and that isolation comes from the
-- loader, not from `dofile`: bare top-level names stay private to their file
-- only when it is loaded through boot.load_script. Public functions are
-- installed on the one gitloom global, g_exports, and every module reaches an
-- earlier module's API by its short name.
--
-- THIS FILE RUNS TWICE
-- The runtime loads main.lua into the root `_G`, where the short names below —
-- cfg_log_error, proc_selftest, repo_root — do not resolve. So the first pass
-- does nothing except load the loader and hand main.lua straight back to it.
-- The second pass arrives with `boot` as a chunk argument, already inside an
-- app environment, and falls through the guard into the real work.
--
-- The point of the detour is that neither `setfenv` (5.1) nor a lexical `_ENV`
-- (5.2+) appears here. app/boot.lua is the only file that knows the difference,
-- which matters because a build can only ever execute one of the two branches:
-- bin/xnet.exe is minilua (5.5), and LUA_BACKEND=luajit is 5.1.

local boot = ...
if type(boot) ~= 'table' then     -- pass 1: the runtime passes no arguments
    boot = dofile('app/boot.lua')
    return boot.run_script('main.lua', boot)
end

boot.load_script('app/cfg.lua')      -- cfg_*                       (no deps)
boot.load_script('app/util.lua')     -- util_*
boot.load_script('app/proc.lua')     -- proc_*
boot.load_script('app/pkt.lua')      -- pkt_*
boot.load_script('app/repo.lua')     -- repo_*
boot.load_script('app/git.lua')      -- git_*
-- Before auth.lua, and not only by convention: namespace ownership is decided
-- against the modules already loaded, so auth.lua could otherwise claim
-- auth_ratelimit_* and nothing would stop it.
boot.load_script('app/auth_ratelimit.lua')  -- auth_ratelimit_*
boot.load_script('app/auth.lua')     -- auth_*
boot.load_script('app/http.lua')     -- http_*
boot.load_script('app/stream.lua')   -- stream_*, stream_response
boot.load_script('app/browse.lua')   -- browse_*
boot.load_script('app/smart.lua')    -- smart_install
boot.load_script('app/api.lua')      -- api_install

-- xrouter carries the xproc workers' RPC replies back to this thread. Exposing
-- its handler as __thread_handle is the only wiring that needs; without it
-- every proc_exec() would sit until its RPC deadline and report a transport
-- failure with no explanation.
local router = dofile('scripts/core/share/xrouter.lua')
router.set_log_prefix('GITLOOM')

local sweep_timer = nil

-- ---------------------------------------------------------------------------
-- Boot work that has to run on a coroutine
--
-- Anything that shells out yields, and __init runs on the main state where a
-- yield is not possible. So the checks that need git go here and are kicked off
-- as a coroutine at the end of __init. A failure is fatal on purpose: a gitloom
-- that cannot run git will answer every clone with a 500, and finding out at
-- boot beats finding out from a user.
-- ---------------------------------------------------------------------------
local function boot_async()
    local ok, err = proc_selftest()
    if not ok then
        cfg_log_error('process pool self-test failed: %s', tostring(err))
        xthread.stop(1)
        return
    end

    local version, verr = git_version()
    if not version then
        cfg_log_error('git is not usable (GIT_BIN=%q): %s', git_bin(), tostring(verr))
        cfg_log_error('gitloom drives the real git binary; install git or set GIT_BIN')
        xthread.stop(1)
        return
    end
    local vok, want = git_version_ok(version)
    if not vok then
        cfg_log_error('git %s is too old; gitloom needs >= %s', version, want)
        xthread.stop(1)
        return
    end
    -- Cache it: /api/v1/version is reachable without credentials, and
    -- re-running git per request let anyone occupy the whole process pool
    -- from outside.
    git_version_cache_set(version)
    cfg_log_system('git %s via %q', version, git_bin())
    git_stream_report()
    -- Says whether X-Forwarded-For is honoured, and from whom. Silent
    -- misconfiguration here makes every audit line and every rate-limit
    -- decision name the proxy instead of the client.
    http_trusted_proxy_report()

    -- Debris from a previous run: a crash mid-clone leaves a half-written
    -- packfile nothing will ever come back for. Safe here because no request
    -- has been served yet.
    proc_tmp_purge()

    local n = #repo_list()
    cfg_log_system('gitloom ready — %d repository(ies) under %s', n, repo_root())
end

-- ---------------------------------------------------------------------------

local function __init()
    assert(xnet.init())
    xtimer.init(16)

    util_dir_make(cfg_get('DATA_DIR', 'data'))
    util_dir_make(cfg_get('TMP_DIR', 'tmp'))
    util_dir_make(repo_root())

    local ok, err = proc_setup()
    if not ok then error('process pool failed to start: ' .. tostring(err)) end

    -- Password hashing gets its own thread: PBKDF2 is deliberately slow, and on
    -- the event loop it made bad logins a denial-of-service against clones.
    ok, err = auth_kdf_setup()
    if not ok then error('kdf worker failed to start: ' .. tostring(err)) end

    -- git children run with HOME pointed here so they cannot pick up the
    -- operator's ~/.gitconfig. The directory has to exist or git warns on every
    -- invocation.
    util_dir_make(git_home_dir())

    repo_index_load()
    auth_load()
    auth_bootstrap()

    smart_install()   -- git transport, as a path fallback
    api_install()     -- JSON API, as routes
    -- Order matters only in that both must be registered before the listener
    -- accepts anything; the route table is always consulted before fallbacks.

    ok, err = http_listen()
    if not ok then error(tostring(err)) end

    -- Scratch files released by finished responses are unlinked here. Pure Lua,
    -- no shelling out, so it is safe to run straight off the timer. Armed from
    -- the main state: xtimer keeps a raw pointer to whichever lua_State armed
    -- a timer, and one armed inside a request coroutine fires into freed memory
    -- once that coroutine is collected.
    sweep_timer = xtimer.add(cfg_int('TMP_SWEEP_MS', 60000), function()
        proc_tmp_sweep()
        -- Rate-limit buckets are created per source address, so on a public
        -- instance the table grows without bound unless stale ones are dropped.
        auth_ratelimit_gc()
    end, -1)

    -- Lock _G. From here a mistyped global raises instead of evaluating to nil.
    -- After every module has loaded and before any request can arrive.
    if cfg_bool('STRICT_GLOBALS', true) then
        boot.strict_enable()
        cfg_log_info('strict globals on')
    end

    local resumed, rerr = coroutine.resume(coroutine.create(boot_async))
    if not resumed then
        cfg_log_error('boot coroutine crashed: %s', tostring(rerr))
        xthread.stop(1)
    end
end

local function __uninit()
    if sweep_timer then sweep_timer:del(); sweep_timer = nil end
    http_close()
    xnet.uninit()
    cfg_log_system('gitloom stopped')
end

return {
    __thread_handle = router.handle,
    __init = __init,
    __uninit = __uninit,
}
