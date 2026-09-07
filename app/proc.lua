-- app/proc.lua — the process pool, and the scratch directory it works in.
--
-- Exports: proc_setup, proc_exec, proc_selftest,
--          proc_tmp_path, proc_tmp_release, proc_tmp_sweep, proc_tmp_purge
--
-- Thin wrapper over scripts/core/server/xproc.lua so the rest of the app never
-- names the underlying module. That indirection is the point: when a real xproc
-- C binding with pollable pipes lands, only this file changes.
--
-- proc_exec() is COROUTINE-ONLY — it yields on an RPC into a worker thread.
-- Every HTTP request is served on its own coroutine (see http.lua), so any
-- handler may call it; boot-time code may not, unless it wraps itself.

local xproc  = dofile('scripts/core/server/xproc.lua')
local xutils = require('xutils')

local swept_at = 0

function g_exports.proc_setup()
    util_dir_make(cfg_get('TMP_DIR', 'tmp'))
    local ok, err = xproc.setup({
        workers  = cfg_int('GIT_WORKERS', 4),
        tmp_dir  = cfg_get('TMP_DIR', 'tmp'),
        base_tid = xthread.WORKER_GRP1,
        name     = 'gitloom-proc',
    })
    if not ok then return nil, err end
    cfg_log_system('process pool up: %d worker(s)', xproc.size())
    return true
end

function g_exports.proc_exec(spec)
    return xproc.exec(spec)
end

function g_exports.proc_selftest()
    return xproc.selftest()
end

-- ---------------------------------------------------------------------------
-- Scratch files
--
-- Every smart-HTTP call stages the request body and the response through files
-- (see git.lua for why). Names are random rather than sequential because two
-- workers can be staging at the same moment and a collision would silently mix
-- one client's packfile into another's response.
-- ---------------------------------------------------------------------------

local pending = {}     -- path -> unix time it became eligible for deletion

function g_exports.proc_tmp_path(suffix)
    return util_path_join(cfg_get('TMP_DIR', 'tmp'), util_rand_hex(12) .. '.' .. (suffix or 'bin'))
end

-- Hand a scratch file to the sweeper. Call it once the file is no longer needed
-- by name — including right after queueing it for send_file_response.
function g_exports.proc_tmp_release(path)
    if path then pending[path] = os.time() end
end

-- Delete released scratch files that have aged past TMP_TTL_SEC.
--
-- WHY NOT DELETE ON RELEASE: send_file_response hands the path to the C layer,
-- which opens the file and keeps it open until the whole response has drained
-- to the socket. On Windows an open handle blocks deletion outright, so an
-- immediate unlink fails and the file leaks with nothing logged. Retrying on a
-- timer is the only point at which the delete can be known to have worked — a
-- file that is still open simply stays on the list for the next sweep.
--
-- Pure Lua: no shell, so it is safe to call from the timer without a coroutine.
function g_exports.proc_tmp_sweep()
    local ttl = cfg_int('TMP_TTL_SEC', 600)
    local now = os.time()
    local removed, held = 0, 0
    for path, released_at in pairs(pending) do
        if now - released_at >= ttl then
            if util_file_remove(path) and not util_file_exists(path) then
                pending[path] = nil
                removed = removed + 1
            else
                held = held + 1
            end
        end
    end
    if removed > 0 or held > 0 then
        cfg_log_debug('scratch sweep: %d removed, %d still held open', removed, held)
    end
    swept_at = now
end

-- Empty the scratch directory at boot. Nothing is in flight yet, so anything
-- left there is debris from a previous run — a crash mid-clone leaves a
-- half-written packfile that nothing will ever come back for.
--
-- This used to shell out, and needed a different command per platform with a
-- different quirk in each: `del /q "dir\*.*"` wants the shell for its own
-- globbing and exits non-zero on an empty directory, while `find -delete` was
-- chosen over `rm -f dir/*` because a glob needs a shell and a shell would also
-- expand `$` and backticks inside TMP_DIR. `xutils.list_dir` is one call with
-- neither quirk, and no longer coroutine-only.
function g_exports.proc_tmp_purge()
    local dir = cfg_get('TMP_DIR', 'tmp')
    local entries = xutils.list_dir(dir)
    if not entries then return end          -- no scratch directory yet

    local failed = 0
    for _, e in ipairs(entries) do
        -- Files only. Nothing here creates a subdirectory, and a recursive
        -- delete aimed at a configured path is not what a sweeper should be.
        if not e.dir and not util_file_remove(util_path_join(dir, e.name)) then
            failed = failed + 1
        end
    end
    if failed > 0 then
        cfg_log_warn('scratch purge could not remove %d file(s)', failed)
    end
end
