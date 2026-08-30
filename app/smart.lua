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
    if not owner then return nil, resp_error(404, 'not found') end

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
        return nil, resp_error(404, 'no such repository')
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
        return nil, resp_error(404, 'no such repository')
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
        return resp_text(403, 'gitloom serves the smart HTTP protocol only ' ..
                              '(no ?service= in this request)\n')
    end
    local spec = SERVICES[service]
    if not spec then
        return resp_text(403, 'unsupported service: ' .. tostring(service) .. '\n')
    end

    local rec, dir_or_resp, user = authorise(req, prefix, spec.write)
    if not rec then return dir_or_resp end

    local body, err = git_advertise(dir_or_resp, service,
                                    git_env_for_request(req, user))
    if not body then
        log_error('advertise failed for %s: %s', prefix, tostring(err))
        return resp_text(500, 'ref advertisement failed\n')
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

local function service_rpc(req, prefix, service)
    local spec = SERVICES[service]

    -- The body is a protocol message, not a form. Requiring the content type
    -- keeps a stray cross-origin POST from reaching receive-pack.
    local ctype = (req.headers['content-type'] or ''):lower()
    local want  = 'application/x-git-' .. spec.verb .. '-request'
    if not str_starts(ctype, want) then
        return resp_text(415, 'expected Content-Type: ' .. want .. '\n')
    end

    local rec, dir_or_resp, user = authorise(req, prefix, spec.write)
    if not rec then return dir_or_resp end

    local out_path, err = git_service(dir_or_resp, service, req.body or '',
                                      git_env_for_request(req, user))
    if not out_path then
        log_error('%s failed for %s: %s', service, prefix, tostring(err))
        return resp_text(500, service .. ' failed\n')
    end

    local resp = resp_file(out_path, 'application/x-git-' .. spec.verb .. '-result',
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

local function smart_dispatch(req, _ctx)
    local path = req.path or '/'

    for _, s in ipairs(SUFFIXES) do
        if str_ends(path, s.suffix) then
            if req.method ~= s.method then
                return resp_text(405, s.method .. ' required for ' .. s.suffix .. '\n')
            end
            local prefix = path:sub(1, #path - #s.suffix)
            if s.fn == 'info_refs' then return info_refs(req, prefix) end
            return service_rpc(req, prefix, s.service)
        end
    end

    for _, hint in ipairs(DUMB_HINTS) do
        if str_ends(path, hint) or path:find('/objects/[0-9a-f][0-9a-f]/') then
            return resp_text(403, 'gitloom serves the smart HTTP protocol only\n')
        end
    end

    return nil    -- not ours; let the next fallback look
end

function smart_install()
    http_fallback(smart_dispatch)
    log_info('git smart-HTTP transport installed')
end
