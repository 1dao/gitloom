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
--   PATCH  /api/v1/repos/:owner/:name     update description/private
--   DELETE /api/v1/repos/:owner/:name
--   GET    /api/v1/repos/:owner/:name/collaborators
--   PUT    /api/v1/repos/:owner/:name/collaborators/:username
--   DELETE /api/v1/repos/:owner/:name/collaborators/:username
--   GET    /api/v1/repos/:owner/:name/issues
--   POST   /api/v1/repos/:owner/:name/issues
--   GET    /api/v1/repos/:owner/:name/issues/:number
--   PATCH  /api/v1/repos/:owner/:name/issues/:number
--   POST   /api/v1/repos/:owner/:name/issues/:number/comments
--   GET    /api/v1/users                  admin only
--   POST   /api/v1/users                  admin only
--   POST   /api/v1/user/password          change it, given the current one
--   POST   /api/v1/user/password/reset    forgot it: spend a recovery code
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

local function h_repo_update(req, ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local owner = ctx.params.owner
    local name = tostring(ctx.params.name):gsub('%.git$', '')
    local rec = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) then
        return http_response_error(404, 'no such repository')
    end
    -- Keep the same existence boundary as DELETE: a caller who cannot read a
    -- private repository gets 404, while a reader gets the useful 403.
    if not auth_can_write(rec, user) or
       (rec.owner ~= user.username and not user.admin) then
        if auth_can_read(rec, user) then
            return http_response_error(403, 'only the owner or an administrator may update')
        end
        return http_response_error(404, 'no such repository')
    end

    local b, berr = body_json(req)
    if not b then return http_response_error(400, berr) end
    local updated, uerr, status = repo_update(owner, name, b)
    if not updated then return http_response_error(status or 400, http_safe_error(uerr)) end
    return http_response_json(200, repo_public(updated, req, ctx))
end

-- Resolve a repository for its owner or an administrator. A readable caller
-- gets a 403, while someone who cannot read a private repository gets the same
-- 404 boundary as the rest of the repository management API.
local function managed_repo(req, ctx)
    local user, resp = require_user(req)
    if not user then return nil, resp end
    local owner = ctx.params.owner
    local name = tostring(ctx.params.name):gsub('%.git$', '')
    local rec = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) then
        return nil, http_response_error(404, 'no such repository')
    end
    if rec.owner == user.username or user.admin then return rec, user end
    if auth_can_read(rec, user) then
        return nil, http_response_error(403, 'only the owner or an administrator may manage collaborators')
    end
    return nil, http_response_error(404, 'no such repository')
end

local function h_collaborator_list(req, ctx)
    local rec, resp = managed_repo(req, ctx)
    if not rec then return resp end
    local list = repo_collaborators(rec)
    return http_response_json(200, { collaborators = util_json_array(list), count = #list })
end

local function h_collaborator_put(req, ctx)
    local rec, resp = managed_repo(req, ctx)
    if not rec then return resp end
    local username = tostring(ctx.params.username or '')
    local exists, aerr = auth_user_exists(username)
    if aerr then return http_response_error(500, http_safe_error(aerr)) end
    if not exists then
        return http_response_error(404, 'no such user')
    end
    local b, berr = body_json(req)
    if not b then return http_response_error(400, berr) end
    local updated, uerr, status = repo_collaborator_put(
        rec.owner, rec.name, username, b.permission)
    if not updated then return http_response_error(status or 400, http_safe_error(uerr)) end
    return http_response_json(200, { collaborator = {
        username = username, permission = updated.collaborators[username],
    }})
end

local function h_collaborator_delete(req, ctx)
    local rec, resp = managed_repo(req, ctx)
    if not rec then return resp end
    local username = tostring(ctx.params.username or '')
    local updated, uerr, status = repo_collaborator_delete(rec.owner, rec.name, username)
    if not updated then return http_response_error(status or 400, http_safe_error(uerr)) end
    return http_response_json(200, { removed = username })
end

local function issue_public(issue, with_comments)
    local out = {
        number = issue.number,
        owner = issue.owner,
        name = issue.name,
        title = issue.title,
        body = issue.body,
        state = issue.state,
        author = issue.author,
        created_at = issue.created_at,
        updated_at = issue.updated_at,
        comment_count = #(issue.comments or {}),
    }
    if with_comments then out.comments = util_json_array(issue.comments or {}) end
    return out
end

local function issue_number_param(ctx)
    local n = tonumber(ctx.params.number)
    if not n or n < 1 or n ~= math.floor(n) then return nil end
    return n
end

local function issue_repo_for_user(req, ctx, need_user)
    local user, bad
    if need_user then user, bad = require_user(req) else user, bad = identify_optional(req) end
    if bad then return nil, nil, bad end
    local owner = ctx.params.owner
    local name = tostring(ctx.params.name):gsub('%.git$', '')
    local rec = repo_get(owner, name)
    if not rec or not repo_exists_of(rec) or not auth_can_read(rec, user) then
        return nil, user, http_response_error(404, 'no such repository')
    end
    return rec, user
end

local function h_issue_list(req, ctx)
    local rec, _, bad = issue_repo_for_user(req, ctx, false)
    if not rec then return bad end
    local state = (req.query or {}).state or 'open'
    if state ~= 'open' and state ~= 'closed' and state ~= 'all' then
        return http_response_error(400, 'issue state must be open, closed or all')
    end
    local list = issue_list(rec.owner, rec.name, state)
    local out = {}
    for _, issue in ipairs(list) do out[#out + 1] = issue_public(issue, false) end
    return http_response_json(200, { issues = util_json_array(out), count = #out, state = state })
end

local function h_issue_create(req, ctx)
    local rec, user, bad = issue_repo_for_user(req, ctx, true)
    if not rec then return bad end
    local b, berr = body_json(req)
    if not b then return http_response_error(400, berr) end
    local issue, ierr, status = issue_create(rec.owner, rec.name, user.username, b)
    if not issue then return http_response_error(status or 400, http_safe_error(ierr)) end
    return http_response_json(201, issue_public(issue, true))
end

local function h_issue_get(req, ctx)
    local rec, _, bad = issue_repo_for_user(req, ctx, false)
    if not rec then return bad end
    local number = issue_number_param(ctx)
    if not number then return http_response_error(400, 'issue number must be a positive integer') end
    local issue = issue_get(rec.owner, rec.name, number)
    if not issue then return http_response_error(404, 'no such issue') end
    return http_response_json(200, issue_public(issue, true))
end

local function issue_can_edit(rec, issue, user)
    return user and (user.admin or issue.author == user.username or auth_can_write(rec, user))
end

local function h_issue_update(req, ctx)
    local rec, user, bad = issue_repo_for_user(req, ctx, true)
    if not rec then return bad end
    local number = issue_number_param(ctx)
    if not number then return http_response_error(400, 'issue number must be a positive integer') end
    local issue = issue_get(rec.owner, rec.name, number)
    if not issue then return http_response_error(404, 'no such issue') end
    if not issue_can_edit(rec, issue, user) then
        return http_response_error(403, 'only the issue author, a collaborator with write access, or an administrator may update')
    end
    local b, berr = body_json(req)
    if not b then return http_response_error(400, berr) end
    local updated, uerr, status = issue_update(rec.owner, rec.name, number, b)
    if not updated then return http_response_error(status or 400, http_safe_error(uerr)) end
    return http_response_json(200, issue_public(updated, true))
end

local function h_issue_comment_create(req, ctx)
    local rec, user, bad = issue_repo_for_user(req, ctx, true)
    if not rec then return bad end
    local number = issue_number_param(ctx)
    if not number then return http_response_error(400, 'issue number must be a positive integer') end
    if not issue_get(rec.owner, rec.name, number) then
        return http_response_error(404, 'no such issue')
    end
    local b, berr = body_json(req)
    if not b then return http_response_error(400, berr) end
    local comment, cerr, status = issue_comment_create(
        rec.owner, rec.name, number, user.username, b.body)
    if not comment then return http_response_error(status or 400, http_safe_error(cerr)) end
    return http_response_json(201, comment)
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

    -- The recovery code is issued with the account and returned HERE, once.
    -- Only its hash is stored, so this response is the single copy that will
    -- ever exist — the same bargain the token endpoint makes, and the reason
    -- the administrator creating the account has to pass it on.
    local code = auth_recovery_ensure(u.username)
    return http_response_json(201, {
        username = u.username, admin = u.admin, email = u.email,
        recovery_code = code,
        note = code and 'give this recovery code to the account holder; ' ..
                        'it cannot be shown again' or nil,
    })
end

-- POST /api/v1/user/tokens  { label?, ttl_seconds? }
--
-- `ttl_seconds` is optional and absent means what it always meant: a token that
-- never expires, which is what a CI job wants. The browser passes one, because
-- a credential it has to keep in sessionStorage should stop working on its own.
-- POST /api/v1/user/password  { old_password, new_password }
--
-- Every token the account holds is revoked as part of the change, so a password
-- that has been given away stops working everywhere rather than only at the
-- next login.
local function h_password_change(req, _ctx)
    local user, resp = require_user(req)
    if not user then return resp end

    local b, berr = body_json(req)
    if not b then return http_response_error(400, berr) end

    local ok, err_or_code = auth_password_change(
        user.username, b.old_password, b.new_password)
    if not ok then return http_response_error(400, http_safe_error(err_or_code)) end

    local out = { changed = true, tokens_revoked = true,
                  note = 'every access token for this account was revoked' }
    -- Only present when the account had no recovery code yet, which is the one
    -- chance to hand one over: it is stored hashed and cannot be read back.
    if err_or_code then
        out.recovery_code = err_or_code
        out.recovery_note = 'store this now; it is the only way back in if the password is lost'
    end
    return http_response_json(200, out)
end

-- POST /api/v1/user/password/reset  { username, recovery_code, new_password }
--
-- DELIBERATELY UNAUTHENTICATED: somebody who has forgotten their password
-- cannot authenticate, which is the whole point. So the recovery code is the
-- credential, and this goes behind the same failure lockout a login uses —
-- every rejection here is a guess at a 16-character secret.
--
-- Answers with a fresh code, because spending one must never leave the account
-- with no way back in.
local function h_password_reset(req, ctx)
    local b, berr = body_json(req)
    if not b then return http_response_error(400, berr) end

    local username = tostring(b.username or '')
    local ip = ctx.ip or req.peer_ip

    local allowed, retry = auth_ratelimit_check(ip, username)
    if not allowed then return auth_too_many(retry) end

    local code, err, kind = auth_password_reset(username, b.recovery_code, b.new_password)
    if not code then
        -- Only a rejection is a guess. A malformed request is the caller's own
        -- mistake and a store failure is ours; counting either would let a
        -- database outage lock out everyone who tried during it — the same
        -- three-way split auth_identify makes, for the same reason.
        if kind == 'rejected' then
            auth_ratelimit_record_failure(ip, username)
            return http_response_error(403, http_safe_error(err))
        end
        return http_response_error(kind == 'error' and 500 or 400, http_safe_error(err))
    end

    auth_ratelimit_record_success(ip, username)
    return http_response_json(200, {
        reset = true,
        tokens_revoked = true,
        recovery_code = code,
        note = 'the previous recovery code is spent; store this replacement',
    })
end

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

    local list, err, page = browse_log(dir, oid, {
        limit = q.limit, skip = q.skip, path = path, lookahead = true,
    })
    if not list then return http_response_error(500, http_safe_error(err)) end
    page = page or {}
    return http_response_json(200, {
        ref = refused, oid = oid, path = path,
        commits = util_json_array(list), count = #list,
        limit = page.limit, skip = page.skip, has_more = page.has_more and true or false,
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
    http_patch('/api/v1/repos/:owner/:name', h_repo_update)
    http_delete('/api/v1/repos/:owner/:name', h_repo_delete)
    http_get('/api/v1/repos/:owner/:name/collaborators', h_collaborator_list)
    http_put('/api/v1/repos/:owner/:name/collaborators/:username', h_collaborator_put)
    http_delete('/api/v1/repos/:owner/:name/collaborators/:username', h_collaborator_delete)
    http_get('/api/v1/repos/:owner/:name/issues', h_issue_list)
    http_post('/api/v1/repos/:owner/:name/issues', h_issue_create)
    http_get('/api/v1/repos/:owner/:name/issues/:number', h_issue_get)
    http_patch('/api/v1/repos/:owner/:name/issues/:number', h_issue_update)
    http_post('/api/v1/repos/:owner/:name/issues/:number/comments', h_issue_comment_create)

    http_get('/api/v1/users', h_user_list)
    http_post('/api/v1/users', h_user_create)
    http_post('/api/v1/user/password', h_password_change)
    -- No credentials on this one, by design: see h_password_reset.
    http_post('/api/v1/user/password/reset', h_password_reset)
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
