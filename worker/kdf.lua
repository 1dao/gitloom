-- worker/kdf.lua — password hashing, off the event loop.
--
-- Runs in its own Lua state on a dedicated thread. `worker/` is for scripts
-- that are NOT part of the main state's flat-global namespace: nothing here is
-- visible to app/, and nothing from app/ is visible here. The only contract is
-- the RPC names registered below.
--
-- WHY THIS THREAD EXISTS
-- PBKDF2 is deliberately slow — that is the whole point of it — and it was
-- running inside the request coroutine on the main thread. Measured on the
-- development machine at AUTH_PBKDF2_ITER=10000: about 55 ms of solid CPU per
-- verification, during which the event loop serves nobody. git re-sends HTTP
-- Basic on every request of a clone, and a wrong password was never cached, so
-- an unauthenticated attacker could hold the entire instance at a standstill
-- with a couple of dozen bad logins per second. Moving the CPU here means a
-- slow hash costs one worker thread instead of the whole server.
--
-- Rate limiting still belongs upstream in app/auth.lua: this thread makes the
-- cost survivable, it does not make it free.

local router = dofile('scripts/core/share/xrouter.lua')
local xutils = require('xutils')
router.set_log_prefix('GITLOOM-KDF')

-- PBKDF2-HMAC-SHA256, RFC 8018. dkLen is fixed at one block (32 bytes), which
-- is why there is no block loop: for SHA-256 the derived key we want is exactly
-- the hash output size.
local function pbkdf2_sha256(password, salt, iterations)
    local u = xutils.hmac_sha256(password, salt .. '\0\0\0\1')
    local out = u
    for _ = 2, iterations do
        u = xutils.hmac_sha256(password, u)
        -- XOR accumulate. Lua has no bitwise operator over strings, so this
        -- walks the 32 bytes; the HMAC either side of it is C and dominates.
        local acc = {}
        for i = 1, 32 do
            acc[i] = string.char(out:byte(i) ~ u:byte(i))
        end
        out = table.concat(acc)
    end
    return out
end

-- Derive and return the hex digest. The caller formats and compares; this
-- thread holds no state and makes no decisions.
router.register('kdf_pbkdf2', function(password, salt, iterations)
    iterations = tonumber(iterations) or 10000
    -- A caller-supplied iteration count reaches a CPU loop, so bound it. The
    -- ceiling is high enough never to bind a real configuration and low enough
    -- that a corrupted stored hash cannot wedge this thread for minutes.
    if iterations < 1 then iterations = 1 end
    if iterations > 1000000 then
        error('kdf: iteration count ' .. iterations .. ' is out of range', 0)
    end
    return xutils.hex_encode(pbkdf2_sha256(tostring(password), tostring(salt), iterations))
end)

router.register('kdf_ping', function() return 'pong' end)

return {
    __thread_handle = router.handle,
}
