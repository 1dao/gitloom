-- app/git.lua — everything that shells out to the git binary.
--
-- Exports: git_bin, git_version, git_version_ok, git_version_cached,
--          git_version_cache_set, git_exec, git_advertise, git_service,
--          git_service_stream, git_stream_enabled, git_stream_report,
--          git_env_for_request, git_head_ref, git_refs
--
-- gitloom does not implement git. Like gitea — which shells out in 232 places
-- and requires git >= 2.25 — it drives the real binary and confines itself to
-- transport, authorisation and metadata. Packfile negotiation, delta
-- resolution, ref locking and fsck all stay where they already work.
--
-- SMART HTTP, AND WHY IT GOES THROUGH FILES
-- The wire protocol is: POST body -> `git upload-pack --stateless-rpc` stdin,
-- and that process's stdout -> HTTP response body. A pipe in both directions is
-- the natural implementation and it is exactly what this runtime cannot do
-- today (io.popen is one-shot and unidirectional). So the body is staged to a
-- file, the child is run with both streams redirected, and the response is sent
-- from the output file with send_file_response — which streams it from C
-- without ever materialising the packfile in a Lua string.
--
-- What that costs:
--   * two disk round trips per fetch/push
--   * no response streaming: the client waits for the child to finish before
--     the first byte moves, so a very large clone looks slow to start
--   * the request body must fit in memory once, while the codec parses it
--     (MAX_REQUEST_SIZE) — this is the ceiling on push size
-- None of it is visible in this module's interface, which is the point: a real
-- pollable-pipe binding replaces the internals and leaves callers alone.

local GIT_TIMEOUT_MS = nil    -- resolved on first use from config

-- Forward declaration. git_exec below closes over this, while the definition
-- lives with the rest of the environment reasoning further down. Keeping it
-- lexical makes the dependency file-private instead of an environment lookup.
local base_env

local function git_timeout()
    if GIT_TIMEOUT_MS == nil then
        GIT_TIMEOUT_MS = cfg_int('GIT_TIMEOUT_SEC', 0) * 1000
    end
    return GIT_TIMEOUT_MS
end

function g_exports.git_bin()
    return cfg_get('GIT_BIN', 'git')
end

-- ---------------------------------------------------------------------------
-- Running git
-- ---------------------------------------------------------------------------

-- Run git with `args` (an array, WITHOUT the leading 'git').
--
-- opts:
--   cwd            run inside this directory (normally the bare repo)
--   stdin_file     redirect stdin from this file
--   stdout_file    redirect stdout to this file (else stdout is captured)
--   env            extra environment for the child
--   timeout_ms     override GIT_TIMEOUT_SEC
--
-- Returns xproc's result table: { ok, exit_code, stdout, stderr, err, ... }.
-- Coroutine-only.
function g_exports.git_exec(args, opts)
    opts = opts or {}
    local argv = { git_bin() }
    for _, a in ipairs(args) do argv[#argv + 1] = tostring(a) end

    -- Every invocation is isolated, not just the ones carrying a request:
    -- repo_create's `git init` and the metadata reads inherit the operator's
    -- config otherwise.
    local env = opts.env
    if not env then
        env = base_env()
    else
        for k, v in pairs(base_env()) do
            if env[k] == nil then env[k] = v end
        end
    end

    return proc_exec({
        argv           = argv,
        cwd            = opts.cwd,
        env            = env,
        stdin_file     = opts.stdin_file,
        stdout_file    = opts.stdout_file,
        capture_stdout = opts.stdout_file == nil,
        capture_stderr = true,
        timeout_ms     = opts.timeout_ms or git_timeout(),
        max_capture    = opts.max_capture,
    })
end

-- The oldest git whose smart-HTTP behaviour this code assumes — same floor
-- gitea sets. Below it, --stateless-rpc and protocol v2 differ in ways that
-- show up as a failed clone rather than as a clear error.
local MIN_GIT = { 2, 25, 0 }

-- Version as 'X.Y.Z', or nil plus the failure. Called once at boot so a missing
-- git is a startup error and not a mystery 500 on the first clone.
--
-- Only the first three components: on Windows the string is '2.52.0.windows.1',
-- and the vendor suffix is not part of any comparison we want to make.
function g_exports.git_version()
    local r = git_exec({ '--version' })
    if not r.ok then
        local msg = util_str_trim(r.stderr or '')
        return nil, msg ~= '' and msg or tostring(r.err)
    end
    local v = util_str_trim(r.stdout):match('git version (%d+%.%d+%.%d+)')
    return v or util_str_trim(r.stdout)
end

-- The version read once at boot. Serving it from here rather than re-running
-- `git --version` is a availability fix, not a micro-optimisation: /api/v1/version
-- is unauthenticated, and a per-request child let anyone occupy the whole
-- process pool from outside and stall every clone on the instance.
local cached_version = nil

function g_exports.git_version_cache_set(v) cached_version = v end
function g_exports.git_version_cached()     return cached_version end

-- Is `version` (as returned above) at least MIN_GIT? Returns ok, wanted-string.
function g_exports.git_version_ok(version)
    local want = table.concat(MIN_GIT, '.')
    local a, b, c = tostring(version or ''):match('^(%d+)%.(%d+)%.(%d+)')
    if not a then return false, want end
    local got = { tonumber(a), tonumber(b), tonumber(c) }
    for i = 1, 3 do
        if got[i] > MIN_GIT[i] then return true, want end
        if got[i] < MIN_GIT[i] then return false, want end
    end
    return true, want
end

-- ---------------------------------------------------------------------------
-- Environment handed to upload-pack / receive-pack
-- ---------------------------------------------------------------------------

-- GIT_PROTOCOL carries the client's protocol version. Passing it through is
-- what enables protocol v2, where the client asks for only the refs it wants
-- instead of receiving the full advertisement — the difference between a few
-- hundred bytes and megabytes on a repository with many refs.
--
-- The header is client-controlled and lands in a child's environment, so it is
-- matched against a fixed shape rather than forwarded as received. Same
-- restriction gitea applies (safeGitProtocolHeader).
--
-- The identity fields feed the reflog of anything receive-pack writes, so a
-- push is attributable to the account that authenticated rather than to
-- whatever git guesses from the server's hostname.
-- Environment every git child gets, request or not.
--
-- Without this a child inherits the SERVER OPERATOR's git configuration: the
-- system gitconfig, ~/.gitconfig via HOME, and anything they set there. That is
-- not a tidiness problem — `core.hooksPath`, `alias.*`, `http.proxy`,
-- `include.path`, `core.fsmonitor` and `credential.helper` all change what
-- upload-pack and receive-pack do, so a repository's behaviour would depend on
-- the machine's dotfiles, and a credential helper could be invoked during a
-- request. gitea pins the same set for the same reason.
--
--   GIT_CONFIG_NOSYSTEM   ignore /etc/gitconfig
--   HOME / XDG_CONFIG_HOME point at a directory we own, so ~/.gitconfig is ours
--   GIT_TERMINAL_PROMPT   never block a worker waiting for a tty that is not there
--   GIT_ASKPASS/SSH_ASKPASS  same, for the GUI prompt path
--   GIT_NO_REPLACE_OBJECTS  refs/replace/* must not rewrite what we serve
--   LC_ALL                stable, parseable output regardless of server locale
base_env = function()
    local home = util_path_join(cfg_get('DATA_DIR', 'data'), 'githome')
    return {
        GIT_CONFIG_NOSYSTEM    = '1',
        HOME                   = home,
        XDG_CONFIG_HOME        = home,
        GIT_TERMINAL_PROMPT    = '0',
        GIT_ASKPASS            = '',
        SSH_ASKPASS            = '',
        GIT_NO_REPLACE_OBJECTS = '1',
        LC_ALL                 = 'C',
    }
end

-- The isolated HOME has to exist, or git warns on every invocation. Created
-- once at boot from main.lua.
function g_exports.git_home_dir()
    return util_path_join(cfg_get('DATA_DIR', 'data'), 'githome')
end

function g_exports.git_env_for_request(req, user)
    local env = base_env()

    local proto = req.headers and req.headers['git-protocol']
    if proto and proto:match('^[0-9a-zA-Z:,=%.%-_ ]+$') and #proto <= 100 then
        env.GIT_PROTOCOL = proto
    end

    if user then
        env.GIT_COMMITTER_NAME  = user.name or user.username or 'gitloom'
        env.GIT_COMMITTER_EMAIL = user.email or ((user.username or 'gitloom') .. '@gitloom.local')
    end

    return env
end

-- ---------------------------------------------------------------------------
-- Smart HTTP: GET /<repo>/info/refs?service=git-upload-pack
-- ---------------------------------------------------------------------------

-- Ref advertisement for `service` ('git-upload-pack' | 'git-receive-pack').
-- Returns the full response body — preamble plus git's output — or nil plus a
-- message. Small enough to hold in memory: it is one line per ref.
--
-- The repository is passed as '.' with cwd set to it, so the path never travels
-- through the shell quoting layer at all.
function g_exports.git_advertise(dir, service, env)
    local verb = service:gsub('^git%-', '')
    local r = git_exec({ verb, '--stateless-rpc', '--advertise-refs', '.' },
                       { cwd = dir, env = env })
    if not r.ok then
        return nil, string.format('%s --advertise-refs failed: %s %s',
            verb, tostring(r.err), util_str_trim(r.stderr or ''))
    end
    return pkt_service_header(service) .. r.stdout
end

-- ---------------------------------------------------------------------------
-- Smart HTTP: POST /<repo>/git-upload-pack | git-receive-pack
-- ---------------------------------------------------------------------------

-- Run the stateless-RPC half of the protocol.
--
--   dir       the bare repository
--   service   'git-upload-pack' | 'git-receive-pack'
--   body      the raw request body (already un-gzipped by the codec)
--   env       from git_env_for_request
--
-- On success returns (out_path, nil): the caller sends that file and then
-- proc_tmp_release()s it. On failure returns (nil, message) and any scratch file has
-- already been released.
function g_exports.git_service(dir, service, body, env)
    local verb = service:gsub('^git%-', '')
    local in_path  = proc_tmp_path('in')
    local out_path = proc_tmp_path('out')

    local wok, werr = util_file_write(in_path, body)
    if not wok then
        proc_tmp_release(in_path)
        return nil, 'staging the request body failed: ' .. tostring(werr)
    end

    local r = git_exec({ verb, '--stateless-rpc', '.' }, {
        cwd         = dir,
        env         = env,
        stdin_file  = in_path,
        stdout_file = out_path,
    })

    -- The input file has done its job either way.
    proc_tmp_release(in_path)

    if not r.ok then
        proc_tmp_release(out_path)
        return nil, string.format('%s failed: %s %s',
            verb, tostring(r.err), util_str_trim(r.stderr or ''))
    end

    -- receive-pack reports hook output and per-ref results on stderr even when
    -- it succeeds; that is the only place a rejected push explains itself, so
    -- it goes to the log rather than being dropped.
    local errtext = util_str_trim(r.stderr or '')
    if errtext ~= '' then
        cfg_log_info('%s %s: %s', verb, dir, errtext:gsub('\n', ' | '))
    end

    return out_path
end

-- ---------------------------------------------------------------------------
-- Streaming smart HTTP (Linux)
-- ---------------------------------------------------------------------------

-- The xproc module is newer than some runtimes gitloom may be run on, so its
-- absence must be survivable rather than fatal.
--
-- A bare require() here would raise at LOAD time on any bin/xnet built before
-- xproc existed, and gitloom would not start at all — turning a missing
-- optimisation into a dead service. pcall makes it exactly what it should be:
-- a capability that is either present or not.
local xproc_ok, xproc_mod = pcall(require, 'xproc')
if not xproc_ok then xproc_mod = nil end

-- Is the streaming path usable AND wanted?
--
-- GIT_STREAM: 'auto' (default) uses it wherever xproc works, 'off' forces the
-- file-staging path everywhere. The switch exists because this path is new and
-- its C half has not yet run on a real Linux host -- an operator who hits
-- trouble should be able to fall back without editing code or rebuilding.
function g_exports.git_stream_enabled()
    local mode = tostring(cfg_get('GIT_STREAM', 'auto')):lower()
    if mode == 'off' or mode == '0' then return false end
    if not xproc_mod then return false end
    return xproc_mod.supported()
end

-- ---------------------------------------------------------------------------
-- How many streams may run at once
--
-- xproc.spawn is a bare process-creation call. proc_exec is not: it hands the
-- command to a pool of GIT_WORKERS threads and the caller waits until one is
-- free, which is what makes "concurrency is bounded by GIT_WORKERS" true of the
-- staged path. Calling spawn straight from a request handler restores the
-- property the pool exists to remove — the number of concurrent git processes
-- becomes the number of concurrent POSTs, a number an anonymous client picks
-- for us on any public repository, and each one also holds up to
-- STREAM_PAUSE_HIGH_KB of buffered packfile.
--
-- So a stream takes a slot before it spawns, and gives it back on every exit.
-- With none free the caller stages through files instead, which queues on the
-- pool rather than adding a process: a burst degrades to slower clones, not to
-- an unbounded fan-out, and an instance runs at most GIT_STREAM_MAX +
-- GIT_WORKERS git processes.
-- ---------------------------------------------------------------------------

local streams_active = 0
local STREAM_MAX = nil

local function stream_max()
    if STREAM_MAX == nil then
        STREAM_MAX = cfg_int('GIT_STREAM_MAX', cfg_int('GIT_WORKERS', 4))
    end
    return STREAM_MAX
end

-- Say once, at boot, which transport path is in use. Otherwise the difference
-- between "streaming" and "staging through files" is invisible until someone
-- measures a clone and wonders why it is slow.
function g_exports.git_stream_report()
    if git_stream_enabled() then
        cfg_log_system('smart-HTTP transport: streaming (pipes via xproc), ' ..
                   'at most %d concurrent (then file staging)', stream_max())
    elseif not xproc_mod then
        cfg_log_system('smart-HTTP transport: file staging ' ..
                   '(this runtime has no xproc module)')
    else
        cfg_log_system('smart-HTTP transport: file staging (%s)',
            tostring(cfg_get('GIT_STREAM', 'auto')):lower() == 'off'
                and 'GIT_STREAM=off' or 'xproc unsupported on this platform')
    end
end

-- The transfer itself. git_service_stream below owns the slot accounting and is
-- what callers use; everything from here to the terminating chunk is this.
--
-- This is what the whole xproc chain exists for. The staged path
-- above cannot start the response until git has finished, because
-- Content-Length is not knowable before then; here the first packet git emits
-- becomes the first chunk on the wire.
--
-- Once the first byte has gone out the status is committed, so a later failure
-- can only abort the connection -- see stream_abort. That is honest: the client
-- reports a truncated transfer, which is what happened.
--
-- Coroutine-only. It yields until the child's stdout reaches EOF and is resumed
-- from that channel's on_close, which runs on the event loop.
local function stream_rpc(dir, service, body, env, conn, headers)
    local verb = service:gsub('^git%-', '')

    local argv = { git_bin(), verb, '--stateless-rpc', '.' }
    local h, serr = xproc_mod.spawn({ argv = argv, cwd = dir, env = env })
    if not h then return nil, 'spawn failed: ' .. tostring(serr) end

    local co = coroutine.running()
    local started, finished = false, false
    local child_out = nil          -- the channel we pause when the client lags
    local drain_timer = nil
    local send_failed = nil
    local errparts = {}
    local kill_timer = nil

    local function wake()
        if finished then return end
        finished = true
        if kill_timer then kill_timer:del(); kill_timer = nil end
        if drain_timer then drain_timer:del(); drain_timer = nil end
        local ok, e = coroutine.resume(co)
        if not ok then
            cfg_log_error('%s stream coroutine crashed: %s', verb, tostring(e))
        end
    end

    -- stdout: every arrival becomes a chunk.
    -- Flow control between the two channels.
    --
    -- git produces a packfile far faster than a client on a real network can
    -- take it. Without this, every byte the child emits is queued on the HTTP
    -- connection immediately: the send buffer grows to its cap, send_raw starts
    -- refusing writes, and a chunk loses one of its three parts — which the
    -- client reports as "Malformed encoding found in chunked-encoding". Small
    -- repositories never reach the cap, which is why this only appeared once a
    -- 60 MiB clone was tried.
    --
    -- So: stop reading the child while the socket is backed up, and start again
    -- once it has drained. The child then blocks on its own stdout write, which
    -- is exactly the backpressure a pipeline is supposed to have.
    local HIGH = cfg_int('STREAM_PAUSE_HIGH_KB', 4096) * 1024
    local LOW  = cfg_int('STREAM_PAUSE_LOW_KB', 1024) * 1024

    -- No drain callback exists, so resuming is polled. The interval only has to
    -- be short next to how long the socket takes to drain HIGH-LOW bytes.
    local function arm_drain()
        if drain_timer or finished then return end
        drain_timer = xtimer.add(cfg_int('STREAM_DRAIN_MS', 20), function()
            drain_timer = nil
            if finished or not child_out then return end
            local queued = conn:stats()
            if queued <= LOW then
                if child_out:is_read_paused() then child_out:resume_read() end
            else
                arm_drain()
            end
        end, 1)
    end

    local rconn, rerr = xnet.attach(h.stdout_fd, {
        on_packet = function(c, data)
            if send_failed then return #data end     -- draining, already doomed
            if not started then
                started = true
                stream_begin(conn, 200, headers)
            end
            local ok, werr = stream_write(conn, data)
            if not ok then
                -- A partial frame is unrecoverable; record it and let the tail
                -- of the function abort the connection.
                send_failed = werr
                return #data
            end
            if conn:stats() >= HIGH and not c:is_read_paused() then
                c:pause_read()
                arm_drain()
            end
            -- The return value is the number of bytes consumed; anything less
            -- and the channel redelivers the remainder.
            return #data
        end,
        on_close = function() wake() end,
    })
    child_out = rconn
    if not rconn then
        xproc_mod.kill(h.pid, true)
        xproc_mod.wait(h.pid, false)
        return nil, 'attach stdout failed: ' .. tostring(rerr)
    end

    -- stderr: collected for the log. It must be drained even if nobody reads
    -- it -- a full stderr pipe blocks the child forever, and receive-pack is
    -- chatty on it even when it succeeds.
    xnet.attach(h.stderr_fd, {
        on_packet = function(_c, d) errparts[#errparts + 1] = d; return #d end,
        on_close  = function() end,
    })

    -- stdin: the request body, then EOF.
    local wconn, werr = xnet.attach(h.stdin_fd, {
        on_packet = function(_c, d) return #d end,
        on_close  = function() end,
    })
    if not wconn then
        xproc_mod.kill(h.pid, true)
        return nil, 'attach stdin failed: ' .. tostring(werr)
    end
    if body and #body > 0 then wconn:send_raw(body) end
    -- close_after_flush, NOT close: the body above is QUEUED, and close()
    -- tears the channel down immediately and discards whatever has not drained
    -- yet -- git would see a truncated request. This drains first, then shuts
    -- the write side down, which is the EOF the child is waiting for. Without
    -- an EOF at all, both sides wait for each other until the timeout.
    wconn:close_after_flush('eof')

    -- A client that disconnects does not stop the child; nothing else would
    -- either, once we are parked in yield. Armed from here rather than from a
    -- callback because xtimer binds a timer to the lua_State that created it.
    local limit = cfg_int('GIT_TIMEOUT_SEC', 600)
    if limit > 0 then
        kill_timer = xtimer.add(limit * 1000, function()
            kill_timer = nil
            cfg_log_warn('%s exceeded %ds, killing pid %d', verb, limit, h.pid)
            xproc_mod.kill(h.pid, true)
        end, 1)
    end

    coroutine.yield()

    -- wait returns (exited, code) on success and (nil, message) on failure, so
    -- `code` is not always a number -- and the failure branches below format it
    -- with %d, which RAISES on a string. That raise landed after the headers had
    -- gone out, where an error is the one thing that cannot be reported. Pin it
    -- to a number here instead.
    local exited, code = xproc_mod.wait(h.pid, false)
    if not exited or type(code) ~= 'number' then
        if not exited then
            cfg_log_warn('%s: wait on pid %d failed (%s); treating it as a failure',
                verb, h.pid, tostring(code))
        end
        code = -1
    end

    local errtext = util_str_trim(table.concat(errparts))
    if errtext ~= '' then
        cfg_log_info('%s %s: %s', verb, dir, errtext:gsub('\n', ' | '))
    end

    if send_failed then
        -- Part of a chunk is already on the wire, so there is no valid way to
        -- finish: the terminator would tell the client a truncated body is
        -- complete.
        stream_abort(conn, 'send failed mid-stream: ' .. tostring(send_failed))
        return true
    end

    if not started then
        -- Nothing reached the wire, so a clean error response is still possible.
        if code ~= 0 then
            return nil, string.format('%s exited %d %s', verb, code, errtext)
        end
        stream_begin(conn, 200, headers)
        local fok, ferr = stream_finish(conn)
        if not fok then stream_abort(conn, 'terminator failed: ' .. tostring(ferr)) end
        return true
    end

    if code ~= 0 then
        stream_abort(conn, string.format('%s exited %d', verb, code))
        return true
    end

    local fok, ferr = stream_finish(conn)
    if not fok then stream_abort(conn, 'terminator failed: ' .. tostring(ferr)) end
    return true
end

-- Run the stateless-RPC half of the protocol with the child's stdout going
-- straight out as chunked HTTP, as it is produced.
--
-- Returns:
--   true            the response was written (headers, body, terminator)
--   false           every streaming slot is busy. NOTHING was spawned and
--                   nothing was written; the caller should use git_service,
--                   which queues on the process pool
--   nil, message    the attempt failed before anything reached the wire; the
--                   caller should send an error response
--
-- Coroutine-only.
function g_exports.git_service_stream(dir, service, body, env, conn, headers)
    local max = stream_max()
    if max > 0 and streams_active >= max then
        cfg_log_warn('%s: all %d streaming slot(s) busy, staging through files instead',
            service, max)
        return false
    end

    streams_active = streams_active + 1
    -- pcall so the slot comes back on EVERY exit, including a raise from the
    -- half that runs after the yield -- which is resumed by an event callback
    -- and would otherwise unwind straight past this line. One leaked slot is
    -- permanent, and enough of them take the cap to zero for the process's
    -- lifetime. (A child that never reaches EOF still holds its slot until
    -- GIT_TIMEOUT_SEC kills it, which is why that must not be 0.)
    local ok, a, b = pcall(stream_rpc, dir, service, body, env, conn, headers)
    streams_active = streams_active - 1
    if ok then return a, b end

    cfg_log_error('%s stream raised: %s', service, tostring(a))
    if stream_is_committed(conn) then
        -- Part of the response is already out; there is no status left to send.
        stream_abort(conn, 'stream handler error')
        return true
    end
    return nil, 'stream handler error: ' .. tostring(a)
end

-- ---------------------------------------------------------------------------
-- Metadata reads (for the JSON API, not the transport)
-- ---------------------------------------------------------------------------

-- The branch HEAD points at, without resolving it to a commit — works on an
-- empty repository, where rev-parse would fail.
function g_exports.git_head_ref(dir)
    local r = git_exec({ 'symbolic-ref', '--short', 'HEAD' }, { cwd = dir })
    if not r.ok then return nil end
    return util_str_trim(r.stdout)
end

-- Every ref as { name = 'refs/heads/main', oid = '...', type = 'commit' }.
-- Empty table on an empty repository — not an error.
function g_exports.git_refs(dir)
    local r = git_exec({ 'for-each-ref', '--format=%(refname) %(objectname) %(objecttype)' },
                       { cwd = dir })
    if not r.ok then return nil, util_str_trim(r.stderr or tostring(r.err)) end
    local out = {}
    for line in tostring(r.stdout):gmatch('[^\r\n]+') do
        local name, oid, kind = line:match('^(%S+)%s+(%S+)%s+(%S+)$')
        if name then out[#out + 1] = { name = name, oid = oid, type = kind } end
    end
    return out
end
