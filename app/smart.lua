-- app/smart.lua — the git smart-HTTP transport.
--
-- Exports: smart_install
--
-- Three endpoints make up the whole of clone/fetch/push over HTTP:
--
--   GET  <repo>/info/refs?service=git-upload-pack    ref advertisement (read)
--   GET  <repo>/info/refs?service=git-receive-pack   ref advertisement (write)
--   POST <repo>/git-upload-pack                      the fetch itself
--   POST <repo>/git-receive-pack                     the push itself
--
-- They are registered as a FALLBACK rather than as routes, because the
-- repository name is everything BEFORE the suffix and can be one or two
-- segments: /alice/site.git/info/refs and /site.git/info/refs must both work.
--
-- THE DUMB PROTOCOL IS NOT SERVED. A request to /info/refs with no ?service is
-- a client asking for it; we answer 403 rather than 404 so the failure names
-- itself. Modern git only falls back to dumb when the smart advertisement is
-- malformed, so seeing this in the log usually means the preamble is wrong.

local SERVICES = {
    ['git-upload-pack']  = { verb = 'upload-pack',  write = false },
    ['git-receive-pack'] = { verb = 'receive-pack', write = true },
}

-- git caches aggressively unless told not to, and a cached ref advertisement
-- means a client that never sees a new commit.
local function no_cache(headers)
    headers['Expires']       = 'Fri, 01 Jan 1980 00:00:00 GMT'
    headers['Pragma']        = 'no-cache'
    headers['Cache-Control'] = 'no-cache, max-age=0, must-revalidate'
    return headers
end

-- Resolve the repository named by `prefix` and decide whether `req` may have it.
--
-- Returns (rec, dir, user) on success, or (nil, response) where the response is
-- already the right thing to send back.
--
-- The 401-vs-404 split matters. An anonymous client that is refused must get a
-- 401 WITH a challenge, or git reports the failure instead of asking for
-- credentials and retrying. An authenticated client that is refused gets a 404,
-- not a 403: confirming that a private repository exists to someone who may not
-- read it is itself a disclosure.
local function authorise(req, prefix, want_write)
    local owner, name = repo_parse_url(prefix)
    if not owner then return nil, http_response_error(404, 'not found') end

    local user, why, retry = auth_identify(req)
    if not user and why == 'rate limited' then
        return nil, auth_too_many(retry)
    end
    if not user and why == 'bad credentials' then
        return nil, auth_challenge('invalid username or password')
    end

    local rec = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) then
        -- Anonymous callers get a challenge first: with credentials the answer
        -- might have been different, and this way a typo'd password on a real
        -- repository does not read as "no such repository".
        if not user then return nil, auth_challenge('authentication required') end
        return nil, http_response_error(404, 'no such repository')
    end

    -- Spelled out rather than `want_write and can_write or can_read`: that
    -- idiom silently falls through to the second branch whenever the first
    -- evaluates to FALSE rather than nil, so a refused write became a granted
    -- read and anonymous pushes to a public repository succeeded.
    local allowed
    if want_write then
        allowed = auth_can_write(rec, user)
    else
        allowed = auth_can_read(rec, user)
    end

    if not allowed then
        if not user then return nil, auth_challenge('authentication required') end
        return nil, http_response_error(404, 'no such repository')
    end

    -- From the record, not from the URL: the index is case-folded, so the
    -- path the client used may differ in case from the directory on disk.
    return rec, repo_dir_of(rec), user
end

-- ---------------------------------------------------------------------------
-- GET <repo>/info/refs
-- ---------------------------------------------------------------------------

local function info_refs(req, prefix)
    local service = req.query and req.query.service
    if not service or service == '' then
        return http_response_text(403, 'gitloom serves the smart HTTP protocol only ' ..
                              '(no ?service= in this request)\n')
    end
    local spec = SERVICES[service]
    if not spec then
        return http_response_text(403, 'unsupported service: ' .. tostring(service) .. '\n')
    end

    local rec, dir_or_resp, user = authorise(req, prefix, spec.write)
    if not rec then return dir_or_resp end

    local body, err = git_advertise(dir_or_resp, service,
                                    git_env_for_request(req, user))
    if not body then
        cfg_log_error('advertise failed for %s: %s', prefix, tostring(err))
        return http_response_text(500, 'ref advertisement failed\n')
    end

    return {
        status = 200,
        body = body,
        headers = no_cache({
            ['Content-Type'] = 'application/x-git-' .. spec.verb .. '-advertisement',
        }),
    }
end

-- ---------------------------------------------------------------------------
-- POST <repo>/git-upload-pack | <repo>/git-receive-pack
-- ---------------------------------------------------------------------------

-- ctx carries the connection, which the streaming path writes to directly.
local function service_rpc(req, ctx, prefix, service)
    local spec = SERVICES[service]

    -- The body is a protocol message, not a form. Requiring the content type
    -- keeps a stray cross-origin POST from reaching receive-pack.
    local ctype = (req.headers['content-type'] or ''):lower()
    local want  = 'application/x-git-' .. spec.verb .. '-request'
    if not util_str_starts(ctype, want) then
        return http_response_text(415, 'expected Content-Type: ' .. want .. '\n')
    end

    local rec, dir_or_resp, user = authorise(req, prefix, spec.write)
    if not rec then return dir_or_resp end

    local env = git_env_for_request(req, user)
    local result_type = 'application/x-git-' .. spec.verb .. '-result'

    -- Either a string the codec buffered, or a reader the serve loop is filling
    -- as the bytes arrive. Both transports below take either.
    local body = req.body_stream or req.body or ''

    -- Two ways to run this, chosen by what the platform can do.
    --
    -- STREAMING (Linux): the child's stdout goes out as chunked HTTP as it is
    -- produced, so the client sees bytes as soon as git emits them. Requires
    -- pollable pipes, which means POSIX — see git_stream_enabled.
    --
    -- STAGED (Windows, or GIT_STREAM=off): the whole output lands in a file
    -- first, because Content-Length cannot be known before git finishes. The
    -- client waits for the entire operation before the first byte moves.
    --
    -- The streaming path is capped (GIT_STREAM_MAX): a `false` return means
    -- every slot was busy and nothing was spawned, so this falls through to
    -- staging, which queues on the process pool instead of adding another git.
    -- Only `nil` is a failure.
    if git_stream_enabled() then
        local ok, serr = git_service_stream(dir_or_resp, service, body,
                                            env, ctx.conn, no_cache({
                                                ['Content-Type'] = result_type,
                                            }))
        if ok then
            if spec.write then
                local hok, herr = pcall(repo_sync_head, rec)
                if not hok then cfg_log_warn('HEAD sync after push failed: %s', tostring(herr)) end
            end
            return stream_response()
        end
        if ok == nil then
            cfg_log_error('%s stream failed for %s: %s', service, prefix, tostring(serr))
            return http_response_text(500, service .. ' failed\n')
        end
    end

    local out_path, err = git_service(dir_or_resp, service, body, env)
    if not out_path then
        cfg_log_error('%s failed for %s: %s', service, prefix, tostring(err))
        return http_response_text(500, service .. ' failed\n')
    end

    -- A push can create the repository's first branch, or a branch other than
    -- the one HEAD names. Fix HEAD up now, while we know a push just landed.
    if spec.write then
        local sok, serr = pcall(repo_sync_head, rec)
        if not sok then
            cfg_log_warn('HEAD sync after push failed: %s', tostring(serr))
        end
    end

    local resp = http_response_file(out_path, 'application/x-git-' .. spec.verb .. '-result',
                           no_cache({}))
    -- Not os.remove: the C layer holds this file open until the response has
    -- drained. The serve loop releases it to the sweeper once the send is queued.
    resp.release_file = out_path
    return resp
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local SUFFIXES = {
    { suffix = '/info/refs',       method = 'GET',  fn = 'info_refs' },
    { suffix = '/git-upload-pack', method = 'POST', service = 'git-upload-pack' },
    { suffix = '/git-receive-pack',method = 'POST', service = 'git-receive-pack' },
}

-- Paths a dumb-protocol client asks for. Answering them with a clear 403 beats
-- a generic 404, which git reports as "repository not found" and sends the user
-- looking in the wrong place.
local DUMB_HINTS = { '/HEAD', '/objects/info/packs', '/objects/info/alternates' }

local function smart_dispatch(req, ctx)
    local path = req.path or '/'

    for _, s in ipairs(SUFFIXES) do
        if util_str_ends(path, s.suffix) then
            if req.method ~= s.method then
                return http_response_text(405, s.method .. ' required for ' .. s.suffix .. '\n')
            end
            local prefix = path:sub(1, #path - #s.suffix)
            if s.fn == 'info_refs' then return info_refs(req, prefix) end
            return service_rpc(req, ctx, prefix, s.service)
        end
    end

    for _, hint in ipairs(DUMB_HINTS) do
        if util_str_ends(path, hint) or path:find('/objects/[0-9a-f][0-9a-f]/') then
            return http_response_text(403, 'gitloom serves the smart HTTP protocol only\n')
        end
    end

    return nil    -- not ours; let the next fallback look
end

-- ---------------------------------------------------------------------------
-- Which requests get their body streamed rather than buffered
--
-- Only the two smart-HTTP POSTs. Everything else on this server has a body
-- measured in kilobytes, and `req.body` is what its handler wants.
--
-- NOT A CONTENT-ENCODED ONE. git gzips a request body only when it has already
-- buffered the whole thing itself (http.postBuffer, 1 MiB by default), and the
-- runtime's inflate is one-shot — there is no incremental decompressor to feed.
-- Those two facts fit together exactly: a compressed body is small by
-- construction, so the bodies that need streaming are never the compressed ones.
--
-- NOR A SMALL ONE. Under BODY_STREAM_MIN_KB a body costs nothing to hold, and
-- buffering keeps the connection reusable when a handler answers 401 or 415
-- without reading it (see the serve loop: an undrained stream ends the
-- connection). git crosses this line exactly where it gives up on buffering and
-- switches to chunked, which is the case that needs streaming in the first
-- place.
-- ---------------------------------------------------------------------------
local function body_stream_wanted(head)
    if head.method ~= 'POST' then return false end

    -- Only where the streaming transport runs. Both halves need the same thing
    -- of the platform — pollable pipes to a child on the way out, working read
    -- flow control on the way in — and on Windows neither is there: pausing an
    -- accepted connection to hold back a body the handler has not drained
    -- leaves the client reset. GIT_STREAM=off therefore turns off both
    -- directions, which is the one switch an operator has to understand.
    if not git_stream_enabled() then return false end

    local path = head.path or ''
    if not (util_str_ends(path, '/git-upload-pack') or
            util_str_ends(path, '/git-receive-pack')) then
        return false
    end

    local enc = tostring(head.headers['content-encoding'] or ''):lower()
    if enc ~= '' and enc ~= 'identity' then return false end

    if head.chunked then return true end
    return (head.content_length or 0) >= cfg_int('BODY_STREAM_MIN_KB', 64) * 1024
end

function g_exports.smart_install()
    http_fallback(smart_dispatch)
    http_body_stream(body_stream_wanted)
    cfg_log_info('git smart-HTTP transport installed')
end
