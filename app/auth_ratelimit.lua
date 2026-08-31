-- app/auth_ratelimit.lua — failure backoff for credential checks.
--
-- Exports: auth_ratelimit_check, auth_ratelimit_record_failure, auth_ratelimit_record_success,
--          auth_ratelimit_gc, auth_ratelimit_stats
--
-- Moving PBKDF2 onto its own thread (worker/kdf.lua) stops one bad login from
-- stalling the event loop. It does not stop a thousand of them from saturating
-- that thread, and it does nothing at all about password guessing. This is the
-- part that does.
--
-- Two independent counters, and a request is refused if EITHER trips:
--
--   by source address   an attacker spraying many usernames from one host
--   by username         a distributed attempt at one account
--
-- Counting only by address would let a botnet grind a single account; counting
-- only by username would let one host enumerate the whole instance while each
-- individual account stays under its limit. Neither alone is sufficient, and
-- they are cheap.
--
-- A refusal is returned BEFORE the KDF runs, which is the point: past the
-- threshold, guesses stop costing the server anything.
--
-- SUCCESS CLEARS THE COUNTER for that key, so a legitimate user who fumbles
-- their password a few times and then gets it right is not left in a penalty
-- box. It also means an attacker who guesses correctly resets it — irrelevant,
-- since by then they are in.

local by_ip   = {}    -- ip       -> { count, first_ts, until_ts }
local by_user = {}    -- username -> { count, first_ts, until_ts }

local function limits()
    return cfg_int('AUTH_FAIL_MAX', 10),
           cfg_int('AUTH_FAIL_WINDOW_SEC', 60),
           cfg_int('AUTH_LOCKOUT_SEC', 300)
end

-- Look up (and lazily expire) one bucket.
local function bucket(tbl, k, now, window)
    if not k or k == '' then return nil end
    local b = tbl[k]
    if not b then
        b = { count = 0, first_ts = now, until_ts = 0 }
        tbl[k] = b
    elseif b.until_ts == 0 and now - b.first_ts > window then
        -- The window rolled over without a lockout: start counting again.
        b.count, b.first_ts = 0, now
    end
    return b
end

-- May this (address, username) pair attempt a credential check right now?
-- Returns true, or false plus the number of seconds left on the lockout.
function g_exports.auth_ratelimit_check(ip, username)
    local max, window = limits()
    if max <= 0 then return true end            -- 0 disables the whole thing

    local now = os.time()
    for _, b in ipairs({ bucket(by_ip, ip, now, window),
                         bucket(by_user, username, now, window) }) do
        if b.until_ts > now then return false, b.until_ts - now end
        if b.until_ts > 0 and b.until_ts <= now then
            b.count, b.first_ts, b.until_ts = 0, now, 0   -- lockout served
        end
    end
    return true
end

function g_exports.auth_ratelimit_record_failure(ip, username)
    local max, window, lockout = limits()
    if max <= 0 then return end

    local now = os.time()
    for name, b in pairs({ ip = bucket(by_ip, ip, now, window),
                           user = bucket(by_user, username, now, window) }) do
        b.count = b.count + 1
        if b.count >= max and b.until_ts <= now then
            b.until_ts = now + lockout
            cfg_log_warn('credential failures locked out by %s (%s): %d in %ds, %ds lockout',
                name, name == 'ip' and tostring(ip) or tostring(username),
                b.count, window, lockout)
        end
    end
end

function g_exports.auth_ratelimit_record_success(ip, username)
    if ip then by_ip[ip] = nil end
    if username then by_user[username] = nil end
end

-- Drop buckets nobody has touched for a while. Without this the tables grow
-- once per distinct source address, which for a public instance is unbounded.
-- Called from the same timer as the scratch sweeper.
function g_exports.auth_ratelimit_gc()
    local _, window, lockout = limits()
    local now = os.time()
    local stale = math.max(window, lockout) * 2
    local n = 0
    for _, tbl in ipairs({ by_ip, by_user }) do
        for k, b in pairs(tbl) do
            if b.until_ts <= now and now - b.first_ts > stale then
                tbl[k] = nil
                n = n + 1
            end
        end
    end
    return n
end

-- For the admin endpoint and for tests.
function g_exports.auth_ratelimit_stats()
    local now = os.time()
    local ips, users, locked = 0, 0, 0
    for _, b in pairs(by_ip)   do ips   = ips   + 1; if b.until_ts > now then locked = locked + 1 end end
    for _, b in pairs(by_user) do users = users + 1 end
    return { addresses = ips, usernames = users, locked_out = locked }
end
