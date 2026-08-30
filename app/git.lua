-- app/git.lua — everything that shells out to the git binary.
--
-- Exports: git_bin, git_version, git_version_ok, git_version_cached,
--          git_version_cache_set, git_exec, git_advertise, git_service,
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

-- Forward declaration. git_exec below closes over this, but the definition
-- lives with the rest of the environment reasoning further down; without the
-- declaration the reference would compile as a global and, under
-- strict_enable(), raise on the first git invocation.
local base_env

local function git_timeout()
    if GIT_TIMEOUT_MS == nil then
        GIT_TIMEOUT_MS = cfg_int('GIT_TIMEOUT_SEC', 0) * 1000
    end
    return GIT_TIMEOUT_MS
end

function git_bin()
    return cfg('GIT_BIN', 'git')
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
function git_exec(args, opts)
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
function git_version()
    local r = git_exec({ '--version' })
    if not r.ok then
        local msg = str_trim(r.stderr or '')
        return nil, msg ~= '' and msg or tostring(r.err)
    end
    local v = str_trim(r.stdout):match('git version (%d+%.%d+%.%d+)')
    return v or str_trim(r.stdout)
end

-- The version read once at boot. Serving it from here rather than re-running
-- `git --version` is a availability fix, not a micro-optimisation: /api/v1/version
-- is unauthenticated, and a per-request child let anyone occupy the whole
-- process pool from outside and stall every clone on the instance.
local cached_version = nil

function git_version_cache_set(v) cached_version = v end
function git_version_cached()     return cached_version end

-- Is `version` (as returned above) at least MIN_GIT? Returns ok, wanted-string.
function git_version_ok(version)
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
    local home = path_join(cfg('DATA_DIR', 'data'), 'githome')
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
function git_home_dir()
    return path_join(cfg('DATA_DIR', 'data'), 'githome')
end

function git_env_for_request(req, user)
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
function git_advertise(dir, service, env)
    local verb = service:gsub('^git%-', '')
    local r = git_exec({ verb, '--stateless-rpc', '--advertise-refs', '.' },
                       { cwd = dir, env = env })
    if not r.ok then
        return nil, string.format('%s --advertise-refs failed: %s %s',
            verb, tostring(r.err), str_trim(r.stderr or ''))
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
-- tmp_release()s it. On failure returns (nil, message) and any scratch file has
-- already been released.
function git_service(dir, service, body, env)
    local verb = service:gsub('^git%-', '')
    local in_path  = tmp_path('in')
    local out_path = tmp_path('out')

    local wok, werr = file_write(in_path, body)
    if not wok then
        tmp_release(in_path)
        return nil, 'staging the request body failed: ' .. tostring(werr)
    end

    local r = git_exec({ verb, '--stateless-rpc', '.' }, {
        cwd         = dir,
        env         = env,
        stdin_file  = in_path,
        stdout_file = out_path,
    })

    -- The input file has done its job either way.
    tmp_release(in_path)

    if not r.ok then
        tmp_release(out_path)
        return nil, string.format('%s failed: %s %s',
            verb, tostring(r.err), str_trim(r.stderr or ''))
    end

    -- receive-pack reports hook output and per-ref results on stderr even when
    -- it succeeds; that is the only place a rejected push explains itself, so
    -- it goes to the log rather than being dropped.
    local errtext = str_trim(r.stderr or '')
    if errtext ~= '' then
        log_info('%s %s: %s', verb, dir, errtext:gsub('\n', ' | '))
    end

    return out_path
end

-- ---------------------------------------------------------------------------
-- Metadata reads (for the JSON API, not the transport)
-- ---------------------------------------------------------------------------

-- The branch HEAD points at, without resolving it to a commit — works on an
-- empty repository, where rev-parse would fail.
function git_head_ref(dir)
    local r = git_exec({ 'symbolic-ref', '--short', 'HEAD' }, { cwd = dir })
    if not r.ok then return nil end
    return str_trim(r.stdout)
end

-- Every ref as { name = 'refs/heads/main', oid = '...', type = 'commit' }.
-- Empty table on an empty repository — not an error.
function git_refs(dir)
    local r = git_exec({ 'for-each-ref', '--format=%(refname) %(objectname) %(objecttype)' },
                       { cwd = dir })
    if not r.ok then return nil, str_trim(r.stderr or tostring(r.err)) end
    local out = {}
    for line in tostring(r.stdout):gmatch('[^\r\n]+') do
        local name, oid, kind = line:match('^(%S+)%s+(%S+)%s+(%S+)$')
        if name then out[#out + 1] = { name = name, oid = oid, type = kind } end
    end
    return out
end
