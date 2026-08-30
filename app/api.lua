-- app/api.lua — the JSON management API and the plain-text landing page.
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

local function require_admin(req)
    local user, resp = require_user(req)
    if not user then return nil, resp end
    if not user.admin then return nil, resp_error(403, 'administrator only') end
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
                 (cfg('LISTEN_HOST', '0.0.0.0') .. ':' .. cfg('LISTEN_PORT', '8686'))
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

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

local function h_index(_req, _ctx)
    return resp_text(200, table.concat({
        'gitloom ' .. VERSION,
        '',
        'Clone:   git clone http://<host>:' .. cfg('LISTEN_PORT', '8686') .. '/<owner>/<repo>.git',
        'API:     GET /api/v1/version',
        '         GET /api/v1/repos',
        '',
    }, '\n'))
end

-- git's version is read once at boot (main.lua) and served from there.
--
-- Calling git_version() per request made this unauthenticated endpoint a way to
-- occupy the whole process pool from outside: every hit spawned a child, and
-- GIT_WORKERS of them in flight blocks every clone on the instance. The version
-- of a binary does not change while the process runs, so there is nothing to
-- re-read.
local function h_version(_req, _ctx)
    return resp_json(200, {
        name = 'gitloom',
        version = VERSION,
        git = git_version_cached() or 'unavailable',
    })
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

local function h_repo_list(req, ctx)
    local user, bad = identify_optional(req)
    if bad then return bad end
    local out = {}
    for _, rec in ipairs(repo_list()) do
        if auth_can_read(rec, user) then
            out[#out + 1] = repo_public(rec, req, ctx)
        end
    end
    return resp_json(200, { repos = out, count = #out })
end

local function h_repo_create(req, ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local b, err = body_json(req)
    if not b then return resp_error(400, err) end

    -- Creating under another account is an administrator action; everyone else
    -- creates under their own name whatever they ask for.
    local owner = b.owner or user.username
    if owner ~= user.username and not user.admin then
        return resp_error(403, 'cannot create a repository under another account')
    end

    local rec, cerr = repo_create(owner, tostring(b.name or ''), {
        description    = b.description,
        private        = b.private,
        default_branch = b.default_branch,
    })
    if not rec then return resp_error(400, safe_error(cerr)) end
    return resp_json(201, repo_public(rec, req, ctx))
end

local function h_repo_get(req, ctx)
    local user, bad = identify_optional(req)
    if bad then return bad end
    local owner, name = ctx.params.owner, ctx.params.name
    name = tostring(name):gsub('%.git$', '')

    local rec = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) or not auth_can_read(rec, user) then
        return resp_error(404, 'no such repository')
    end

    local info = repo_public(rec, req, ctx)
    local dir = repo_dir_of(rec)
    info.head = git_head_ref(dir)
    local refs = git_refs(dir) or {}
    info.empty = (#refs == 0)
    -- An empty Lua table is indistinguishable from an empty object, and
    -- json_pack serialises it as {} — so `refs` changed shape from [] to {}
    -- depending on whether the repository had commits, and every client would
    -- have to special-case it. json_array keeps the type stable.
    info.refs = json_array(refs)
    return resp_json(200, info)
end

local function h_repo_delete(req, ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local owner, name = ctx.params.owner, tostring(ctx.params.name):gsub('%.git$', '')
    local rec = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) then
        -- Same reasoning as the transport: do not confirm existence to someone
        -- who could not have read it anyway.
        return resp_error(404, 'no such repository')
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
            return resp_error(403, 'only the owner or an administrator may delete')
        end
        return resp_error(404, 'no such repository')
    end

    local ok, derr = repo_delete(rec.owner, rec.name)
    if not ok then return resp_error(500, safe_error(derr)) end
    return resp_json(200, { deleted = owner .. '/' .. name })
end

local function h_user_list(req, _ctx)
    local _, resp = require_admin(req)
    if resp then return resp end
    return resp_json(200, { users = auth_user_list() })
end

local function h_user_create(req, _ctx)
    local _, resp = require_admin(req)
    if resp then return resp end

    local b, err = body_json(req)
    if not b then return resp_error(400, err) end

    local u, cerr = auth_user_create(tostring(b.username or ''),
                                     tostring(b.password or ''),
                                     { admin = b.admin, email = b.email })
    if not u then return resp_error(400, cerr) end
    return resp_json(201, { username = u.username, admin = u.admin, email = u.email })
end

local function h_token_create(req, _ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local b = codec.json(req)
    local label = type(b) == 'table' and b.label or 'token'

    local clear, err = auth_token_create(user.username, label)
    if not clear then return resp_error(400, err) end
    -- Shown once. Only the digest is stored, so there is no endpoint that can
    -- ever return this value again.
    return resp_json(201, {
        label = label,
        token = clear,
        note = 'store this now; it cannot be retrieved again',
    })
end

-- ---------------------------------------------------------------------------

function api_install()
    http_get('/', h_index)
    http_get('/api/v1/version', h_version)

    http_get('/api/v1/repos', h_repo_list)
    http_post('/api/v1/repos', h_repo_create)
    http_get('/api/v1/repos/:owner/:name', h_repo_get)
    http_delete('/api/v1/repos/:owner/:name', h_repo_delete)

    http_get('/api/v1/users', h_user_list)
    http_post('/api/v1/users', h_user_create)
    http_post('/api/v1/user/tokens', h_token_create)

    log_info('management API installed')
end
