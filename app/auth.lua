-- app/auth.lua — accounts, HTTP Basic authentication, and access decisions.
--
-- Exports: auth_load, auth_save, auth_user_get, auth_user_list,
--          auth_user_create, auth_user_set_password, auth_user_delete,
--          auth_token_create, auth_token_revoke,
--          auth_identify, auth_can_read, auth_can_write, auth_challenge,
--          auth_bootstrap, auth_kdf_setup, auth_too_many
--
-- Phase 0 keeps accounts in data/users.json. The shape is deliberately the one
-- a `users` table would have, so moving to MySQL later is a change of storage
-- and not of callers.
--
-- HOW GIT AUTHENTICATES
-- The git client speaks HTTP Basic and re-sends the header on EVERY request of
-- a clone or push — there is no session. So credential verification sits
-- directly on the hot path, and a deliberately slow password hash would be paid
-- several times per operation. Two things follow:
--
--   * Passwords use PBKDF2-HMAC-SHA256, not a bare salted digest: the file is
--     the whole secret, and a single SHA-256 falls to an offline attack at
--     billions of guesses per second.
--   * A successful verification is cached for AUTH_CACHE_SEC against the
--     presented credential, so the second and later requests of one clone skip
--     the KDF. The cache key includes the credential itself, so a changed or
--     revoked password is never satisfied from it.
--
-- Access tokens skip the KDF entirely and are stored as a plain SHA-256: a
-- token is 32 random bytes we generated, so there is nothing to guess and
-- nothing to stretch.

local xutils = require('xutils')

local users = nil          -- username -> record
-- Verification cache. The VALUE carries the verdict, not just an expiry:
-- 'ok' for a credential that verified, 'bad' for one that did not. Storing an
-- expiry alone and treating any live entry as success — which is what a plain
-- `cache_hit` does once failures are cached too — would authenticate every
-- wrong password for the length of its own negative TTL.
local verify_cache = {}    -- cache key -> { verdict = 'ok'|'bad', expires = ts }

local function users_path()
    return cfg('USERS_FILE', 'data/users.json')
end

-- ---------------------------------------------------------------------------
-- Password hashing
-- ---------------------------------------------------------------------------

-- The KDF itself runs on a dedicated thread (worker/kdf.lua). PBKDF2 is
-- deliberately expensive, and paying that on the event loop let a handful of
-- bad logins per second stall every clone on the instance — see that file.
--
-- Coroutine-only in the normal case. auth_bootstrap runs on the main state at
-- boot, where yielding is impossible, so a direct fallback is kept for exactly
-- that path; it blocks, which at boot costs nothing because nothing is being
-- served yet.
local KDF_TID = xthread.COMPUTE
local kdf_started = false

function auth_kdf_setup()
    if kdf_started then return true end
    local ok, err = xthread.create_thread(KDF_TID, 'gitloom-kdf', 'worker/kdf.lua')
    if not ok then return nil, err end
    kdf_started = true
    return true
end

-- Same computation as the worker's, for the boot path only.
local function pbkdf2_inline(password, salt, iterations)
    local u = xutils.hmac_sha256(password, salt .. '\0\0\0\1')
    local out = u
    for _ = 2, iterations do
        u = xutils.hmac_sha256(password, u)
        local acc = {}
        for i = 1, 32 do acc[i] = string.char(out:byte(i) ~ u:byte(i)) end
        out = table.concat(acc)
    end
    return xutils.hex_encode(out)
end

local function pbkdf2_hex(password, salt, iterations)
    if kdf_started and coroutine.isyieldable() then
        local ok, hex = xthread.rpc(KDF_TID, 'kdf_pbkdf2', 30000,
                                    password, salt, iterations)
        if ok and type(hex) == 'string' then return hex end
        -- A transport failure must not silently downgrade to "password wrong";
        -- fall through to the inline path so the request still gets a truthful
        -- answer, and say so, because it means the worker is in trouble.
        log_error('kdf worker did not answer (%s); hashing inline on the event loop',
            tostring(hex))
    end
    return pbkdf2_inline(password, salt, iterations)
end

local function password_hash(password, salt, iterations)
    iterations = iterations or cfg_int('AUTH_PBKDF2_ITER', 10000)
    salt = salt or rand_hex(16)
    return string.format('pbkdf2$%d$%s$%s', iterations, salt,
                         pbkdf2_hex(password, salt, iterations))
end

-- Constant-time-ish comparison. Lua string == on equal-length strings is not
-- guaranteed constant time, and these are hashes rather than secrets, but the
-- accumulate-then-compare shape costs nothing and removes the question.
local function digest_equal(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do diff = diff | (a:byte(i) ~ b:byte(i)) end
    return diff == 0
end

local function password_verify(password, stored)
    local iter, salt, hex = tostring(stored or ''):match('^pbkdf2%$(%d+)%$(%x+)%$(%x+)$')
    if not iter then return false end
    return digest_equal(pbkdf2_hex(password, salt, tonumber(iter)), hex)
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

function auth_load()
    users = {}
    local raw = file_read(users_path())
    if not raw or raw == '' then return users end
    local parsed = xutils.json_unpack(raw)
    if type(parsed) ~= 'table' or type(parsed.users) ~= 'table' then
        log_warn('account file %s is unreadable; starting with no accounts',
            users_path())
        return users
    end
    for _, u in ipairs(parsed.users) do
        if type(u) == 'table' and type(u.username) == 'string' then
            u.tokens = u.tokens or {}
            users[u.username] = u
        end
    end
    return users
end

function auth_save()
    local list = {}
    for _, u in pairs(users or {}) do list[#list + 1] = u end
    table.sort(list, function(a, b) return a.username < b.username end)

    local json = xutils.json_pack({ version = 1, users = list })
    if not json then return nil, 'account serialisation failed' end

    dir_make(cfg('DATA_DIR', 'data'))
    local ok, err = file_write_atomic(users_path(), json)
    if not ok then return nil, 'account save failed: ' .. tostring(err) end
    return true
end

function auth_user_get(username)
    if not users then auth_load() end
    return users[tostring(username or '')]
end

function auth_user_list()
    if not users then auth_load() end
    local out = {}
    for _, u in pairs(users) do
        out[#out + 1] = { username = u.username, admin = u.admin or false,
                          email = u.email, created_at = u.created_at,
                          token_count = #(u.tokens or {}) }
    end
    table.sort(out, function(a, b) return a.username < b.username end)
    return out
end

function auth_user_create(username, password, opts)
    opts = opts or {}
    if not repo_name_ok(username) then
        return nil, 'username must match ' .. '[A-Za-z0-9_][A-Za-z0-9._-]*'
    end
    if type(password) ~= 'string' or #password < cfg_int('AUTH_MIN_PASSWORD', 8) then
        return nil, string.format('password must be at least %d characters',
            cfg_int('AUTH_MIN_PASSWORD', 8))
    end
    if not users then auth_load() end
    if users[username] then return nil, 'user already exists' end

    users[username] = {
        username   = username,
        pwhash     = password_hash(password),
        email      = opts.email or (username .. '@gitloom.local'),
        admin      = opts.admin and true or false,
        tokens     = {},
        created_at = os.time(),
    }
    local ok, err = auth_save()
    if not ok then
        users[username] = nil
        return nil, err
    end
    return users[username]
end

function auth_user_set_password(username, password)
    local u = auth_user_get(username)
    if not u then return nil, 'no such user' end
    if type(password) ~= 'string' or #password < cfg_int('AUTH_MIN_PASSWORD', 8) then
        return nil, 'password too short'
    end
    u.pwhash = password_hash(password)
    verify_cache = {}     -- an old password must stop working immediately
    return auth_save()
end

function auth_user_delete(username)
    if not users then auth_load() end
    if not users[username] then return nil, 'no such user' end
    users[username] = nil
    verify_cache = {}
    return auth_save()
end

-- Issue an access token. Returns the CLEAR token exactly once — only its digest
-- is stored, so a lost token is reissued rather than recovered.
function auth_token_create(username, label)
    local u = auth_user_get(username)
    if not u then return nil, 'no such user' end
    local clear = rand_hex(32)
    u.tokens = u.tokens or {}
    u.tokens[#u.tokens + 1] = {
        label      = tostring(label or 'token'),
        hash       = xutils.sha256_hex(clear),
        created_at = os.time(),
    }
    local ok, err = auth_save()
    if not ok then return nil, err end
    return clear
end

function auth_token_revoke(username, label)
    local u = auth_user_get(username)
    if not u then return nil, 'no such user' end
    local kept, removed = {}, 0
    for _, t in ipairs(u.tokens or {}) do
        if t.label == label then removed = removed + 1 else kept[#kept + 1] = t end
    end
    if removed == 0 then return nil, 'no token with that label' end
    u.tokens = kept
    verify_cache = {}
    return auth_save()
end

-- ---------------------------------------------------------------------------
-- Request authentication
-- ---------------------------------------------------------------------------

local function cache_key(username, secret)
    -- The secret is hashed into the key so the cache cannot be used to satisfy
    -- a credential that has since changed, and so no plaintext lives in it.
    return username .. ':' .. xutils.sha256_hex(secret)
end

-- 'ok', 'bad', or nil when there is nothing usable cached.
local function cache_lookup(k)
    local e = verify_cache[k]
    if not e then return nil end
    if os.time() >= e.expires then verify_cache[k] = nil; return nil end
    return e.verdict
end

local function cache_put(k, verdict, ttl)
    verify_cache[k] = { verdict = verdict, expires = os.time() + ttl }
end

-- Identify the caller from an Authorization header.
--
-- Returns the user record, or nil when the request is anonymous (no header) or
-- the credentials do not verify — the two are distinguished by the second
-- return: 'anonymous' or 'bad credentials'. Callers turn the latter into a 401
-- with a challenge, never a 403, or git will not retry with credentials.
--
-- Coroutine-only when a password has to be derived (the KDF is an RPC); the
-- cached and token paths do no I/O.
--
-- The second return distinguishes 'anonymous' (no header — a legitimate state)
-- from 'bad credentials' (a failed authentication) and 'rate limited'. Callers
-- must not collapse them: anonymous may proceed to the public view, the other
-- two may not.
function auth_identify(req)
    local hdr = req.headers and req.headers['authorization']
    if not hdr or hdr == '' then return nil, 'anonymous' end

    local ip = req.peer_ip or '?'

    local b64 = hdr:match('^[Bb]asic%s+(%S+)$')
    if not b64 then return nil, 'bad credentials' end
    local decoded = xutils.base64_decode(b64)
    if not decoded then return nil, 'bad credentials' end

    -- Only the FIRST colon separates; a password may contain colons.
    local username, secret = decoded:match('^([^:]*):(.*)$')
    if not username or username == '' then return nil, 'bad credentials' end

    -- A hit on the positive cache is checked BEFORE the rate limit, so a client
    -- in the middle of a legitimate clone is never locked out by someone else
    -- hammering the same account from elsewhere. It costs one hash of a
    -- credential we have already verified.
    local k = cache_key(username, secret)
    local u = auth_user_get(username)
    local cached = cache_lookup(k)
    if cached == 'ok' and u then return u end
    -- A cached failure is answered without touching the rate limiter: it has
    -- already been counted once, and re-counting the retries of one clone would
    -- lock out a user for a single typo.
    if cached == 'bad' then return nil, 'bad credentials' end

    local allowed, retry_after = authrl_check(ip, username)
    if not allowed then
        return nil, 'rate limited', retry_after
    end

    -- An unknown username still counts as a failure, and still costs the same
    -- from the caller's point of view: returning early without recording it
    -- would turn this into a free username oracle.
    if not u then
        authrl_record_failure(ip, username)
        return nil, 'bad credentials'
    end

    local ok = false
    -- Tokens first: a plain SHA-256, and the common case for automation.
    for _, t in ipairs(u.tokens or {}) do
        if digest_equal(xutils.sha256_hex(secret), t.hash) then ok = true; break end
    end
    if not ok then ok = password_verify(secret, u.pwhash) end

    if not ok then
        -- Cache the failure too, for a shorter time than a success. git re-sends
        -- the same wrong credential on every request of a clone, so without this
        -- one mistyped password costs a full KDF several times over.
        cache_put(k, 'bad', cfg_int('AUTH_NEG_CACHE_SEC', 10))
        authrl_record_failure(ip, username)
        return nil, 'bad credentials'
    end

    cache_put(k, 'ok', cfg_int('AUTH_CACHE_SEC', 60))
    authrl_record_success(ip, username)
    return u
end

-- 429 for a caller past the failure threshold.
--
-- Deliberately NOT a 401: a 401 tells git to retry with credentials, which is
-- exactly the loop we are trying to break, and some clients will retry several
-- times per operation. Retry-After tells a well-behaved client when to come
-- back, and the body says why so a locked-out human is not left guessing.
function auth_too_many(retry_after)
    return {
        status = 429,
        body = string.format(
            'too many failed authentication attempts; retry in %d second(s)\n',
            tonumber(retry_after) or 60),
        headers = {
            ['Retry-After']  = tostring(math.max(1, tonumber(retry_after) or 60)),
            ['Content-Type'] = 'text/plain; charset=utf-8',
        },
    }
end

-- The 401 that makes a git client prompt for, or re-send, credentials. Without
-- WWW-Authenticate the client reports the failure and stops.
function auth_challenge(message)
    return {
        status = 401,
        body = (message or 'authentication required') .. '\n',
        headers = {
            ['WWW-Authenticate'] = string.format('Basic realm="%s"',
                cfg('AUTH_REALM', 'gitloom')),
            ['Content-Type'] = 'text/plain; charset=utf-8',
        },
    }
end

-- ---------------------------------------------------------------------------
-- Access decisions
--
-- `rec` is the repository index record; `user` may be nil (anonymous).
-- ---------------------------------------------------------------------------

local function collaborator_level(rec, user)
    if not user or type(rec.collaborators) ~= 'table' then return nil end
    return rec.collaborators[user.username]
end

function auth_can_read(rec, user)
    if not rec then return false end
    if not rec.private then
        -- A public repository is readable anonymously only when the instance
        -- allows it; otherwise "public" just means "visible to any account".
        if not user and not cfg_bool('ANON_READ', true) then return false end
        return true
    end
    if not user then return false end
    if user.admin then return true end
    if rec.owner == user.username then return true end
    local level = collaborator_level(rec, user)
    return level == 'read' or level == 'write'
end

function auth_can_write(rec, user)
    if not rec or not user then return false end
    if user.admin then return true end
    if rec.owner == user.username then return true end
    return collaborator_level(rec, user) == 'write'
end

-- ---------------------------------------------------------------------------
-- Bootstrap
-- ---------------------------------------------------------------------------

-- Create the initial administrator from config when no account exists yet.
-- Runs at boot. Doing nothing when accounts already exist is what makes it safe
-- to leave ADMIN_PASSWORD in the config file across restarts — it will not
-- silently reset a password that has since been changed.
function auth_bootstrap()
    if not users then auth_load() end
    if next(users) ~= nil then return false end

    local name = cfg('ADMIN_USER', '')
    local pass = cfg('ADMIN_PASSWORD', '')
    if name == '' or pass == '' then
        log_warn('no accounts exist and ADMIN_USER/ADMIN_PASSWORD are unset — ' ..
                 'every authenticated route will refuse until an account is created')
        return false
    end

    local u, err = auth_user_create(name, pass, { admin = true })
    if not u then
        log_error('admin bootstrap failed: %s', tostring(err))
        return false
    end
    log_system('bootstrapped administrator account %q', name)
    return true
end
