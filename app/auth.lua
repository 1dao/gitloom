-- app/auth.lua — accounts, HTTP Basic authentication, and access decisions.
--
-- Exports: auth_load, auth_user_list, auth_user_create,
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

-- Bounds on the two free-text fields an account carries, and on how many live
-- tokens it may hold.
--
-- None of these existed while accounts were a JSON file that simply grew. They
-- are columns now — email is VARCHAR(255) and the token list is one TEXT blob —
-- so without them a long email is a 500 out of the database, and enough tokens
-- make the row too large to write AT ALL, which would take revoking them down
-- with it. Refusing at the boundary keeps both stores answering the same way.
local MAX_EMAIL = 255
local MAX_LABEL = 128

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

function g_exports.auth_kdf_setup()
    if kdf_started then return true end
    local ok, err = xthread.create_thread(KDF_TID, 'gitloom-kdf', 'worker/kdf.lua')
    if not ok then return nil, err end
    kdf_started = true
    return true
end

-- Hoisted out of the module environment. A bare name inside an app module costs
-- two metamethod hops (see app/boot.lua), and one for the stdlib is the slower
-- of the two because both hops miss before the root `_G` answers. Measured at
-- ~59 ns each, and the XOR below runs 32 times per round: at the default 10000
-- rounds that was ~330k lookups, ~19 ms of pure name resolution stacked on top
-- of the HMACs, every time this path hashes a password.
local string_char, table_concat = string.char, table.concat

-- Bitwise XOR on both backends. `a ~ b` is Lua 5.3+ syntax that LuaJIT (5.1)
-- cannot even parse, so this asks the PARSER whether the operator exists rather
-- than asking for a library name: a module environment raises on an undefined
-- bare name, which makes the usual `if bit then` probe throw on 5.5 instead of
-- evaluating to nil. `load` and `require` are present on both.
--
-- Measured at +2 ms per 10000-round hash against the operator written inline —
-- not worth carrying two spellings of the loop to avoid.
local native_xor = load('return function(a, b) return a ~ b end')
local bxor = native_xor and native_xor() or require('bit').bxor

-- Same computation as the worker's, for the boot path only.
local function pbkdf2_inline(password, salt, iterations)
    local u = xutils.hmac_sha256(password, salt .. '\0\0\0\1')
    local out = u
    for _ = 2, iterations do
        u = xutils.hmac_sha256(password, u)
        local acc = {}
        for i = 1, 32 do acc[i] = string_char(bxor(out:byte(i), u:byte(i))) end
        out = table_concat(acc)
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
        cfg_log_error('kdf worker did not answer (%s); hashing inline on the event loop',
            tostring(hex))
    end
    return pbkdf2_inline(password, salt, iterations)
end

local function password_hash(password, salt, iterations)
    iterations = iterations or cfg_int('AUTH_PBKDF2_ITER', 10000)
    salt = salt or util_rand_hex(16)
    return string.format('pbkdf2$%d$%s$%s', iterations, salt,
                         pbkdf2_hex(password, salt, iterations))
end

-- Constant-time-ish comparison. Lua string == on equal-length strings is not
-- guaranteed constant time, and these are hashes rather than secrets, but the
-- accumulate-then-compare shape costs nothing and removes the question.
local function digest_equal(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' or #a ~= #b then return false end
    local diff = 0
    -- Accumulated with + rather than the bitwise |, which is 5.3+ syntax too.
    -- The property this needs is unchanged: the total is zero only when every
    -- byte matched, and neither operator introduces a data-dependent branch. It
    -- also means the file needs one portability probe rather than two.
    for i = 1, #a do diff = diff + bxor(a:byte(i), b:byte(i)) end
    return diff == 0
end

-- A token with no expires_at never expires — the shape every token issued
-- before this existed still has, and what automation asking for a CI credential
-- still gets. The browser is the caller that wants the other kind.
local function token_live(t)
    return not t.expires_at or os.time() < t.expires_at
end

-- Drop expired entries. Only called where the list is being rewritten anyway,
-- so an expired token costs nothing until somebody touches the account; it is
-- already refused by auth_identify from the moment it lapses.
local function prune_tokens(u)
    local live = {}
    for _, t in ipairs(u.tokens or {}) do
        if token_live(t) then live[#live + 1] = t end
    end
    u.tokens = live
end

local function live_token_count(u)
    local n = 0
    for _, t in ipairs(u.tokens or {}) do
        if token_live(t) then n = n + 1 end
    end
    return n
end

-- Decode an HTTP Basic header. Returns username, secret — or nil plus
-- 'anonymous' (no header, a legitimate state) / 'bad credentials'. Kept in one
-- place because two callers now read the presented credential: the one that
-- verifies it and the one that revokes it.
local function basic_credentials(req)
    local hdr = req.headers and req.headers['authorization']
    if not hdr or hdr == '' then return nil, 'anonymous' end

    local b64 = hdr:match('^[Bb]asic%s+(%S+)$')
    if not b64 then return nil, 'bad credentials' end
    local decoded = xutils.base64_decode(b64)
    if not decoded then return nil, 'bad credentials' end

    -- Only the FIRST colon separates; a password may contain colons.
    local username, secret = decoded:match('^([^:]*):(.*)$')
    if not username or username == '' then return nil, 'bad credentials' end
    return username, secret
end

local function cache_key(username, secret)
    -- The secret is hashed into the key so the cache cannot be used to satisfy
    -- a credential that has since changed, and so no plaintext lives in it.
    return username .. ':' .. xutils.sha256_hex(secret)
end

local function password_verify(password, stored)
    local iter, salt, hex = tostring(stored or ''):match('^pbkdf2%$(%d+)%$(%x+)%$(%x+)$')
    if not iter then return false end
    return digest_equal(pbkdf2_hex(password, salt, tonumber(iter)), hex)
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

-- Read every account into memory. COROUTINE-ONLY under MySQL, where it is a
-- query; main.lua loads it from boot_async for that reason.
--
-- Returns the map, or nil plus a message. On failure `users` is left nil rather
-- than set to {}: no accounts and "the store did not answer" are very different
-- answers to "may this person push", and only one of them is safe to cache.
function g_exports.auth_load()
    local map, err = store_users_load()
    if not map then
        cfg_log_error('accounts unavailable: %s', tostring(err))
        return nil, err
    end
    users = map
    return users
end

-- Returns true, or false once auth_load has logged why not.
local function have_users()
    if users then return true end
    return auth_load() ~= nil
end

-- Persist ONE account the caller has already changed in `users`. Under the file
-- backend that still rewrites the whole file; under MySQL it is a single row.
local function auth_save(u)
    return store_user_put(u)
end

local function auth_user_get(username)
    if not have_users() then return nil end
    return users[tostring(username or '')]
end

function g_exports.auth_user_list()
    if not have_users() then return {} end
    local out = {}
    for _, u in pairs(users) do
        out[#out + 1] = { username = u.username, admin = u.admin or false,
                          email = u.email, created_at = u.created_at,
                          token_count = live_token_count(u) }
    end
    table.sort(out, function(a, b) return a.username < b.username end)
    return out
end

function g_exports.auth_user_create(username, password, opts)
    opts = opts or {}
    if not repo_name_ok(username) then
        return nil, 'username must match ' .. '[A-Za-z0-9_][A-Za-z0-9._-]*'
    end
    if type(password) ~= 'string' or #password < cfg_int('AUTH_MIN_PASSWORD', 8) then
        return nil, string.format('password must be at least %d characters',
            cfg_int('AUTH_MIN_PASSWORD', 8))
    end
    if not have_users() then return nil, 'the account store is unavailable' end
    if users[username] then return nil, 'user already exists' end

    local email = tostring(opts.email or (username .. '@gitloom.local'))
    if #email > MAX_EMAIL then
        return nil, string.format('email must be at most %d bytes', MAX_EMAIL)
    end

    users[username] = {
        username   = username,
        pwhash     = password_hash(password),
        email      = email,
        admin      = opts.admin and true or false,
        tokens     = {},
        created_at = os.time(),
    }
    local ok, err = auth_save(users[username])
    if not ok then
        users[username] = nil
        return nil, err
    end
    return users[username]
end

-- Issue an access token. Returns the CLEAR token exactly once — only its digest
-- is stored, so a lost token is reissued rather than recovered — plus the unix
-- time it expires (nil when it never does). On failure: nil plus a message.
--
-- `ttl_sec` is what makes a browser session safe to store: the page exchanges a
-- password for a short-lived token, so what sits in sessionStorage is bounded
-- and revocable in a way the password behind it is not.
function g_exports.auth_token_create(username, label, ttl_sec)
    local u = auth_user_get(username)
    if not u then return nil, 'no such user' end
    ttl_sec = tonumber(ttl_sec)
    if ttl_sec ~= nil and ttl_sec <= 0 then return nil, 'ttl_seconds must be positive' end

    label = tostring(label or 'token')
    if #label > MAX_LABEL then
        return nil, string.format('label must be at most %d bytes', MAX_LABEL)
    end

    local clear = util_rand_hex(32)
    u.tokens = u.tokens or {}
    prune_tokens(u)

    -- Pruning first, so this counts only tokens that still work: an account
    -- that has issued thousands of short-lived browser sessions is not at its
    -- limit, an account holding that many live credentials is.
    local cap = cfg_int('AUTH_MAX_TOKENS', 64)
    if cap > 0 and #u.tokens >= cap then
        return nil, string.format(
            'this account already holds %d live tokens; revoke one first', #u.tokens)
    end
    local expires_at = ttl_sec and (os.time() + math.floor(ttl_sec)) or nil
    u.tokens[#u.tokens + 1] = {
        label      = label,
        hash       = xutils.sha256_hex(clear),
        created_at = os.time(),
        expires_at = expires_at,
    }
    local ok, err = auth_save(u)
    if not ok then return nil, err end
    return clear, expires_at
end

-- Revoke the token the caller is presenting — the browser's logout.
--
-- Self-revocation only: the credential comes out of the request rather than
-- being named in it, so one session can never end another's and there is no
-- endpoint that reaches somebody else's tokens. Returns true, or nil plus a
-- message when the request is not authenticated with a token at all.
function g_exports.auth_token_revoke(req)
    local username, secret = basic_credentials(req)
    if not username then return nil, secret end
    local u = auth_user_get(username)
    if not u then return nil, 'no such user' end

    local digest = xutils.sha256_hex(secret)
    local kept, found = {}, false
    for _, t in ipairs(u.tokens or {}) do
        if not found and digest_equal(digest, t.hash) then
            found = true
        elseif token_live(t) then
            kept[#kept + 1] = t
        end
    end
    if not found then return nil, 'this request is not authenticated with a token' end
    u.tokens = kept

    -- The positive verification cache would keep answering 'ok' for
    -- AUTH_CACHE_SEC with a credential that no longer exists, which is exactly
    -- the window a logout must not leave open.
    verify_cache[cache_key(username, secret)] = nil
    return auth_save(u)
end

-- ---------------------------------------------------------------------------
-- Request authentication
-- ---------------------------------------------------------------------------

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
function g_exports.auth_identify(req)
    local username, secret = basic_credentials(req)
    if not username then return nil, secret end

    local ip = req.peer_ip or '?'

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

    local allowed, retry_after = auth_ratelimit_check(ip, username)
    if not allowed then
        return nil, 'rate limited', retry_after
    end

    -- An unknown username still counts as a failure, and still costs the same
    -- from the caller's point of view: returning early without recording it
    -- would turn this into a free username oracle.
    if not u then
        auth_ratelimit_record_failure(ip, username)
        return nil, 'bad credentials'
    end

    local ok = false
    -- Tokens first: a plain SHA-256, and the common case for automation. An
    -- expired one is not a credential any more, so it is skipped here rather
    -- than waiting for something to rewrite the list and prune it.
    local digest = xutils.sha256_hex(secret)
    for _, t in ipairs(u.tokens or {}) do
        if token_live(t) and digest_equal(digest, t.hash) then ok = true; break end
    end
    if not ok then ok = password_verify(secret, u.pwhash) end

    if not ok then
        -- Cache the failure too, for a shorter time than a success. git re-sends
        -- the same wrong credential on every request of a clone, so without this
        -- one mistyped password costs a full KDF several times over.
        cache_put(k, 'bad', cfg_int('AUTH_NEG_CACHE_SEC', 10))
        auth_ratelimit_record_failure(ip, username)
        return nil, 'bad credentials'
    end

    cache_put(k, 'ok', cfg_int('AUTH_CACHE_SEC', 60))
    auth_ratelimit_record_success(ip, username)
    return u
end

-- 429 for a caller past the failure threshold.
--
-- Deliberately NOT a 401: a 401 tells git to retry with credentials, which is
-- exactly the loop we are trying to break, and some clients will retry several
-- times per operation. Retry-After tells a well-behaved client when to come
-- back, and the body says why so a locked-out human is not left guessing.
function g_exports.auth_too_many(retry_after)
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
function g_exports.auth_challenge(message)
    return {
        status = 401,
        body = (message or 'authentication required') .. '\n',
        headers = {
            ['WWW-Authenticate'] = string.format('Basic realm="%s"',
                cfg_get('AUTH_REALM', 'gitloom')),
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

function g_exports.auth_can_read(rec, user)
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

function g_exports.auth_can_write(rec, user)
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
function g_exports.auth_bootstrap()
    if not have_users() then return false, 'the account store is unavailable' end
    if next(users) ~= nil then return false end

    local name = cfg_get('ADMIN_USER', '')
    local pass = cfg_get('ADMIN_PASSWORD', '')
    if name == '' or pass == '' then
        cfg_log_warn('no accounts exist and ADMIN_USER/ADMIN_PASSWORD are unset — ' ..
                 'every authenticated route will refuse until an account is created')
        return false
    end

    local u, err = auth_user_create(name, pass, { admin = true })
    if not u then
        cfg_log_error('admin bootstrap failed: %s', tostring(err))
        return false
    end
    cfg_log_system('bootstrapped administrator account %q', name)
    return true
end
