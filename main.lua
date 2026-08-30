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
-- app/*.lua export their public functions onto _G under a per-module prefix
-- instead of returning a table — see app/boot.lua for the rules and for the
-- strict_enable() guard that turns a mistyped name into an error. The load
-- order below IS the dependency order.

dofile('app/boot.lua')     -- global(), strict_enable()
dofile('app/cfg.lua')      -- cfg*, log*                 (no deps)
dofile('app/util.lua')     -- str_*, path_*, file_*, dir_*
dofile('app/proc.lua')     -- proc_*, tmp_*
dofile('app/pkt.lua')      -- pkt_*
dofile('app/repo.lua')     -- repo_*
dofile('app/git.lua')      -- git_*
dofile('app/auth_ratelimit.lua')  -- authrl_*  (before auth.lua, which calls it)
dofile('app/auth.lua')     -- auth_*
dofile('app/http.lua')     -- http_*, resp_*
dofile('app/smart.lua')    -- smart_install
dofile('app/api.lua')      -- api_install

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
        log_error('process pool self-test failed: %s', tostring(err))
        xthread.stop(1)
        return
    end

    local version, verr = git_version()
    if not version then
        log_error('git is not usable (GIT_BIN=%q): %s', git_bin(), tostring(verr))
        log_error('gitloom drives the real git binary; install git or set GIT_BIN')
        xthread.stop(1)
        return
    end
    local vok, want = git_version_ok(version)
    if not vok then
        log_error('git %s is too old; gitloom needs >= %s', version, want)
        xthread.stop(1)
        return
    end
    -- Cache it: /api/v1/version is unauthenticated, and re-running git per
    -- request let anyone occupy the whole process pool from outside.
    git_version_cache_set(version)
    log_system('git %s via %q', version, git_bin())

    -- Debris from a previous run: a crash mid-clone leaves a half-written
    -- packfile nothing will ever come back for. Safe here because no request
    -- has been served yet.
    tmp_purge()

    local n = #repo_list()
    log_system('gitloom ready — %d repository(ies) under %s', n, repo_root())
end

-- ---------------------------------------------------------------------------

local function __init()
    assert(xnet.init())
    xtimer.init(16)

    dir_make(cfg('DATA_DIR', 'data'))
    dir_make(cfg('TMP_DIR', 'tmp'))
    dir_make(repo_root())

    local ok, err = proc_setup()
    if not ok then error('process pool failed to start: ' .. tostring(err)) end

    -- Password hashing gets its own thread: PBKDF2 is deliberately slow, and on
    -- the event loop it made bad logins a denial-of-service against clones.
    ok, err = auth_kdf_setup()
    if not ok then error('kdf worker failed to start: ' .. tostring(err)) end

    -- git children run with HOME pointed here so they cannot pick up the
    -- operator's ~/.gitconfig. The directory has to exist or git warns on every
    -- invocation.
    dir_make(git_home_dir())

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
        tmp_sweep()
        -- Rate-limit buckets are created per source address, so on a public
        -- instance the table grows without bound unless stale ones are dropped.
        authrl_gc()
    end, -1)

    -- Lock _G. From here a mistyped global raises instead of evaluating to nil.
    -- After every module has loaded and before any request can arrive.
    if cfg_bool('STRICT_GLOBALS', true) then
        strict_enable()
        log_info('strict globals on')
    end

    local resumed, rerr = coroutine.resume(coroutine.create(boot_async))
    if not resumed then
        log_error('boot coroutine crashed: %s', tostring(rerr))
        xthread.stop(1)
    end
end

local function __uninit()
    if sweep_timer then sweep_timer:del(); sweep_timer = nil end
    http_close()
    xnet.uninit()
    log_system('gitloom stopped')
end

return {
    __thread_handle = router.handle,
    __init = __init,
    __uninit = __uninit,
}
