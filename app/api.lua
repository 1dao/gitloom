-- app/api.lua — the JSON management API.
--
-- Exports: api_install
--
-- Everything a client needs to create, list, inspect and delete repositories,
-- plus the minimum of account administration. No HTML: the web UI is a later
-- phase and will be a single-page app talking to exactly these endpoints, so
-- keeping the server JSON-only now avoids building a template layer that would
-- then be thrown away.
--
--   GET    /                              plain-text index
--   GET    /api/v1/version
--   GET    /api/v1/repos                  repositories visible to the caller
--   POST   /api/v1/repos                  create
--   GET    /api/v1/repos/:owner/:name     detail, including refs
--   DELETE /api/v1/repos/:owner/:name
--   GET    /api/v1/users                  admin only
--   POST   /api/v1/users                  admin only
--   POST   /api/v1/user/tokens            issue an access token for the caller
--
--   GET    /api/v1/repos/:owner/:name/branches
--   GET    /api/v1/repos/:owner/:name/tags
--   GET    /api/v1/repos/:owner/:name/commits           ?ref= &limit= &skip= &path=
--   GET    /api/v1/repos/:owner/:name/commits/:oid
--   GET    /api/v1/repos/:owner/:name/commits/:oid/diff  ?path=
--   GET    /api/v1/repos/:owner/:name/tree/:ref/*path   directory listing
--   GET    /api/v1/repos/:owner/:name/raw/:ref/*path    file contents

local codec = dofile('scripts/core/share/xhttp_codec.lua')

local VERSION = '0.1.0'

-- ---------------------------------------------------------------------------
-- Request helpers
-- ---------------------------------------------------------------------------

-- Identify the caller, or hand back the response to send instead.
-- Returns (user, nil) or (nil, response).
local function require_user(req)
    local user, why, retry = auth_identify(req)
    if user then return user end
    if why == 'rate limited' then return nil, auth_too_many(retry) end
    if why == 'bad credentials' then
        return nil, auth_challenge('invalid username or password')
    end
    return nil, auth_challenge('authentication required')
end

-- Identify the caller on an endpoint that also serves anonymous requests.
-- Returns (user_or_nil, nil) to proceed, or (nil, response) to stop.
--
-- The distinction that matters: NO credentials is anonymous and fine, WRONG
-- credentials is a failed authentication and must be a 401. Collapsing the two
-- — which is what a bare `auth_identify(req)` does, since both return nil —
-- silently downgrades a caller who thinks they are authenticated to the public
-- view, so a typo'd password looks like an empty account rather than a login
-- failure, and a revoked token keeps appearing to work.
local function identify_optional(req)
    local user, why, retry = auth_identify(req)
    if not user and why == 'rate limited' then
        return nil, auth_too_many(retry)
    end
    if not user and why == 'bad credentials' then
        return nil, auth_challenge('invalid username or password')
    end
    return user
end

local function require_admin(req)
    local user, resp = require_user(req)
    if not user then return nil, resp end
    if not user.admin then return nil, http_response_error(403, 'administrator only') end
    return user
end

local function body_json(req)
    local parsed = codec.json(req)
    if type(parsed) ~= 'table' then return nil, 'expected a JSON object body' end
    return parsed
end

-- What a repository looks like on the wire. Never returns the collaborator
-- table: it names other accounts, and the caller may only be a collaborator.
local function repo_public(rec, req, ctx)
    local scheme = ctx.https and 'https' or 'http'
    local host = (req.headers and req.headers['host']) or
                 (cfg_get('LISTEN_HOST', '0.0.0.0') .. ':' .. cfg_get('LISTEN_PORT', '8686'))
    return {
        owner          = rec.owner,
        name           = rec.name,
        full_name      = rec.owner .. '/' .. rec.name,
        description    = rec.description or '',
        private        = rec.private and true or false,
        default_branch = rec.default_branch,
        created_at     = rec.created_at,
        clone_url      = string.format('%s://%s/%s/%s.git', scheme, host, rec.owner, rec.name),
    }
end

-- Resolve the repository named in the path and check the caller may read it.
-- Returns (rec, dir) or (nil, response).
--
-- Every browsing route funnels through here, so the read check lives in one
-- place rather than once per endpoint -- the shape that eventually lets one of
-- them be forgotten.
local function readable_repo(req, ctx)
    local user, bad = identify_optional(req)
    if bad then return nil, bad end

    local owner = ctx.params.owner
    local name  = tostring(ctx.params.name):gsub('%.git$', '')
    local rec   = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) or not auth_can_read(rec, user) then
        return nil, http_response_error(404, 'no such repository')
    end
    return rec, repo_dir_of(rec)
end

-- Resolve a ref against the repository, defaulting to its own default branch.
-- Returns (oid, ref_used) or (nil, response).
local function resolve_ref(dir, rec, ref)
    ref = (ref and ref ~= '') and ref or (rec.default_branch or 'HEAD')
    local oid, resolved = browse_resolve(dir, ref)
    if not oid then
        -- `resolved` is the error message on this branch.
        return nil, http_response_error(404, tostring(resolved) .. ': ' .. tostring(ref))
    end
    return oid, resolved
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

-- git's version is read once at boot (main.lua) and served from there.
--
-- Calling git_version() per request made this unauthenticated endpoint a way to
-- occupy the whole process pool from outside: every hit spawned a child, and
-- GIT_WORKERS of them in flight blocks every clone on the instance. The version
-- of a binary does not change while the process runs, so there is nothing to
-- re-read.
-- GET /api/v1/version
--
-- Version numbers are only served to an authenticated caller.
--
-- This is not paranoia about an unknown bug; it is the first step of an attack
-- chain that actually ran against two of this operator's gitea instances (see
-- the incident notes referenced in docs/ROADMAP.md). The sequence began
-- `GET /api/v1/version` — fingerprint the build, look it up against a CVE list,
-- then go straight for the matching exploit. A precise version handed to an
-- anonymous scanner is the one piece of that chain we can simply decline to
-- provide.
--
-- What stays anonymous is liveness: a health check, a reverse proxy or a person
-- wondering whether the port answers gets a 200 and the service name. Hiding
-- the NAME would be pointless anyway — anyone who can reach the git endpoints
-- can tell what this is — but the name maps to no CVE list, and the version
-- does.
--
-- API_VERSION_PUBLIC=1 restores the old behaviour for a closed network where
-- fingerprinting is not a concern and a monitoring probe wants the build.
local function h_version(req, _ctx)
    -- Wrong credentials are still a 401 here, as everywhere else. Downgrading
    -- them to the anonymous view would tell a monitoring probe with a stale
    -- password that everything is fine.
    local user, bad = identify_optional(req)
    if bad then return bad end

    local body = { name = 'gitloom', status = 'ok' }
    if user or cfg_bool('API_VERSION_PUBLIC', false) then
        body.version = VERSION
        body.git = git_version_cached() or 'unavailable'
    end
    return http_response_json(200, body)
end

local function h_repo_list(req, ctx)
    local user, bad = identify_optional(req)
    if bad then return bad end
    local out = {}
    for _, rec in ipairs(repo_list()) do
        if auth_can_read(rec, user) then
            out[#out + 1] = repo_public(rec, req, ctx)
        end
    end
    return http_response_json(200, { repos = out, count = #out })
end

local function h_repo_create(req, ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local b, err = body_json(req)
    if not b then return http_response_error(400, err) end

    -- Creating under another account is an administrator action; everyone else
    -- creates under their own name whatever they ask for.
    local owner = b.owner or user.username
    if owner ~= user.username and not user.admin then
        return http_response_error(403, 'cannot create a repository under another account')
    end

    local rec, cerr = repo_create(owner, tostring(b.name or ''), {
        description    = b.description,
        private        = b.private,
        default_branch = b.default_branch,
    })
    if not rec then return http_response_error(400, http_safe_error(cerr)) end
    return http_response_json(201, repo_public(rec, req, ctx))
end

local function h_repo_get(req, ctx)
    local user, bad = identify_optional(req)
    if bad then return bad end
    local owner, name = ctx.params.owner, ctx.params.name
    name = tostring(name):gsub('%.git$', '')

    local rec = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) or not auth_can_read(rec, user) then
        return http_response_error(404, 'no such repository')
    end

    local info = repo_public(rec, req, ctx)
    local dir = repo_dir_of(rec)
    info.head = git_head_ref(dir)
    local refs = git_refs(dir) or {}
    info.empty = (#refs == 0)
    -- An empty Lua table is indistinguishable from an empty object, and
    -- json_pack serialises it as {} — so `refs` changed shape from [] to {}
    -- depending on whether the repository had commits, and every client would
    -- have to special-case it. util_json_array keeps the type stable.
    info.refs = util_json_array(refs)
    return http_response_json(200, info)
end

local function h_repo_delete(req, ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local owner, name = ctx.params.owner, tostring(ctx.params.name):gsub('%.git$', '')
    local rec = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) then
        -- Same reasoning as the transport: do not confirm existence to someone
        -- who could not have read it anyway.
        return http_response_error(404, 'no such repository')
    end
    -- 404, not 403. A stranger who may not even read this repository must not
    -- learn that it exists, and h_repo_get already answers 404 for exactly the
    -- same caller — answering 403 here would hand back the difference and make
    -- DELETE an existence oracle for private repositories.
    --
    -- Someone who CAN read it gets the honest 403: they already know it is
    -- there, so the accurate reason is more useful than a false 404.
    if not auth_can_write(rec, user) or
       (rec.owner ~= user.username and not user.admin) then
        if auth_can_read(rec, user) then
            return http_response_error(403, 'only the owner or an administrator may delete')
        end
        return http_response_error(404, 'no such repository')
    end

    local ok, derr = repo_delete(rec.owner, rec.name)
    if not ok then return http_response_error(500, http_safe_error(derr)) end
    return http_response_json(200, { deleted = owner .. '/' .. name })
end

local function h_user_list(req, _ctx)
    local _, resp = require_admin(req)
    if resp then return resp end
    return http_response_json(200, { users = auth_user_list() })
end

local function h_user_create(req, _ctx)
    local _, resp = require_admin(req)
    if resp then return resp end

    local b, err = body_json(req)
    if not b then return http_response_error(400, err) end

    local u, cerr = auth_user_create(tostring(b.username or ''),
                                     tostring(b.password or ''),
                                     { admin = b.admin, email = b.email })
    if not u then return http_response_error(400, cerr) end
    return http_response_json(201, { username = u.username, admin = u.admin, email = u.email })
end

-- POST /api/v1/user/tokens  { label?, ttl_seconds? }
--
-- `ttl_seconds` is optional and absent means what it always meant: a token that
-- never expires, which is what a CI job wants. The browser passes one, because
-- a credential it has to keep in sessionStorage should stop working on its own.
local function h_token_create(req, _ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local b = codec.json(req)
    local label = type(b) == 'table' and b.label or 'token'
    local ttl = type(b) == 'table' and b.ttl_seconds or nil
    if ttl ~= nil and not tonumber(ttl) then
        return http_response_error(400, 'ttl_seconds must be a number of seconds')
    end

    local clear, expires_at = auth_token_create(user.username, label, ttl)
    if not clear then return http_response_error(400, expires_at) end
    -- Shown once. Only the digest is stored, so there is no endpoint that can
    -- ever return this value again.
    return http_response_json(201, {
        label = label,
        token = clear,
        expires_at = expires_at,
        note = 'store this now; it cannot be retrieved again',
    })
end

-- DELETE /api/v1/user/tokens
--
-- Revokes the token this request is authenticated with, and nothing else: the
-- credential is read out of the Authorization header rather than named in the
-- body, so there is no shape of this request that reaches another session's
-- token. It is what the browser calls on logout.
local function h_token_revoke(req, _ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local ok, err = auth_token_revoke(req)
    if not ok then return http_response_error(400, tostring(err)) end
    return http_response_json(200, { revoked = true })
end

-- ---------------------------------------------------------------------------
-- Browsing
-- ---------------------------------------------------------------------------

local function h_branches(req, ctx)
    local rec, dir = readable_repo(req, ctx)
    if not rec then return dir end
    local list, err = browse_refs(dir, 'branches')
    if not list then return http_response_error(500, http_safe_error(err)) end
    return http_response_json(200, { branches = util_json_array(list), count = #list })
end

local function h_tags(req, ctx)
    local rec, dir = readable_repo(req, ctx)
    if not rec then return dir end
    local list, err = browse_refs(dir, 'tags')
    if not list then return http_response_error(500, http_safe_error(err)) end
    return http_response_json(200, { tags = util_json_array(list), count = #list })
end

local function h_commits(req, ctx)
    local rec, dir = readable_repo(req, ctx)
    if not rec then return dir end

    local q = req.query or {}
    local oid, refused = resolve_ref(dir, rec, q.ref)
    if not oid then return refused end

    -- A path filter reaches a git command line like any other caller input.
    local path, perr = browse_decode_path(q.path)
    if path == nil then return http_response_error(400, perr) end

    local list, err = browse_log(dir, oid, { limit = q.limit, skip = q.skip, path = path })
    if not list then return http_response_error(500, http_safe_error(err)) end
    return http_response_json(200, {
        ref = refused, oid = oid, path = path,
        commits = util_json_array(list), count = #list,
    })
end

local function h_commit(req, ctx)
    local rec, dir = readable_repo(req, ctx)
    if not rec then return dir end

    -- Resolved, not trusted: this value reaches `git show`.
    local oid, refused = resolve_ref(dir, rec, ctx.params.oid)
    if not oid then return refused end

    local commit, err = browse_commit(dir, oid)
    if not commit then return http_response_error(404, http_safe_error(err)) end
    return http_response_json(200, commit)
end

local function h_commit_diff(req, ctx)
    local rec, dir = readable_repo(req, ctx)
    if not rec then return dir end

    -- Resolve the commit exactly as h_commit does; the resulting object id is
    -- the only revision text browse_diff is allowed to pass to git.
    local oid, refused = resolve_ref(dir, rec, ctx.params.oid)
    if not oid then return refused end

    local path, perr = browse_decode_path((req.query or {}).path)
    if path == nil then return http_response_error(400, perr) end

    local patch, err = browse_diff(dir, oid, path)
    if not patch then
        local message = http_safe_error(err)
        if tostring(err):find('exceeds MAX_DIFF_MB', 1, true) then
            return http_response_error(413, message)
        end
        return http_response_error(500, message)
    end
    return http_response_json(200, {
        ref = refused, oid = oid, path = path,
        diff = patch,
    })
end

local function h_tree(req, ctx)
    local rec, dir = readable_repo(req, ctx)
    if not rec then return dir end

    local oid, refused = resolve_ref(dir, rec, ctx.params.ref)
    if not oid then return refused end

    local path, perr = browse_decode_path(ctx.params.path)
    if path == nil then return http_response_error(400, perr) end

    local entries, err = browse_tree(dir, oid, path)
    if not entries then return http_response_error(404, http_safe_error(err)) end
    return http_response_json(200, {
        ref = refused, oid = oid, path = path,
        entries = util_json_array(entries), count = #entries,
    })
end

-- Types a browser may render inline. Everything else is octet-stream with an
-- attachment disposition.
--
-- This is a security decision, not a convenience. A repository can contain an
-- .html or .svg file, and serving that inline with a renderable type turns the
-- gitloom origin into attacker-controlled script -- which is why GitHub serves
-- raw content from a separate domain. We have one origin, so the answer is to
-- never hand the browser something it will execute.
local INLINE_TYPES = {
    txt = 'text/plain; charset=utf-8',
    md   = 'text/plain; charset=utf-8',
    lua  = 'text/plain; charset=utf-8',
    c    = 'text/plain; charset=utf-8',
    h    = 'text/plain; charset=utf-8',
    json = 'text/plain; charset=utf-8',
    png  = 'image/png',
    jpg  = 'image/jpeg',
    jpeg = 'image/jpeg',
    gif  = 'image/gif',
}

local function h_raw(req, ctx)
    local rec, dir = readable_repo(req, ctx)
    if not rec then return dir end

    local oid, refused = resolve_ref(dir, rec, ctx.params.ref)
    if not oid then return refused end

    local path, perr = browse_decode_path(ctx.params.path)
    if path == nil then return http_response_error(400, perr) end
    if path == '' then return http_response_error(400, 'no file named') end

    local info, ierr = browse_blob_info(dir, oid, path)
    if not info then return http_response_error(404, http_safe_error(ierr)) end

    local max = cfg_int('MAX_BLOB_MB', 32) * 1024 * 1024
    if info.size > max then
        return http_response_error(413, string.format(
            'file is %d bytes; MAX_BLOB_MB allows %d', info.size, max))
    end

    local out, berr = browse_blob_file(dir, info.oid)
    if not out then return http_response_error(500, http_safe_error(berr)) end

    local ext = path:match('%.([%w]+)$')
    local ctype = ext and INLINE_TYPES[ext:lower()] or nil
    -- Alongside the allowlist: nosniff stops a browser second-guessing
    -- octet-stream, and the sandbox CSP neuters anything still treated as a
    -- document.
    local headers = {
        ['X-Content-Type-Options']  = 'nosniff',
        ['Content-Security-Policy'] = "default-src 'none'; sandbox",
    }
    if not ctype then
        ctype = 'application/octet-stream'
        local base = (path:match('([^/]+)$') or 'file'):gsub('"', '')
        headers['Content-Disposition'] = 'attachment; filename="' .. base .. '"'
    end

    local resp = http_response_file(out, ctype, headers)
    resp.release_file = out
    return resp
end

-- ---------------------------------------------------------------------------

function g_exports.api_install()
    http_get('/api/v1/version', h_version)

    http_get('/api/v1/repos', h_repo_list)
    http_post('/api/v1/repos', h_repo_create)
    http_get('/api/v1/repos/:owner/:name', h_repo_get)
    http_delete('/api/v1/repos/:owner/:name', h_repo_delete)

    http_get('/api/v1/users', h_user_list)
    http_post('/api/v1/users', h_user_create)
    http_post('/api/v1/user/tokens', h_token_create)
    http_delete('/api/v1/user/tokens', h_token_revoke)

    -- Browsing. The tree and raw routes end in a wildcard because a file path
    -- inside a repository has no fixed segment count.
    http_get('/api/v1/repos/:owner/:name/branches', h_branches)
    http_get('/api/v1/repos/:owner/:name/tags', h_tags)
    http_get('/api/v1/repos/:owner/:name/commits', h_commits)
    http_get('/api/v1/repos/:owner/:name/commits/:oid', h_commit)
    http_get('/api/v1/repos/:owner/:name/commits/:oid/diff', h_commit_diff)
    http_get('/api/v1/repos/:owner/:name/tree/:ref', h_tree)
    http_get('/api/v1/repos/:owner/:name/tree/:ref/*path', h_tree)
    http_get('/api/v1/repos/:owner/:name/raw/:ref/*path', h_raw)

    cfg_log_info('management API installed')
end
