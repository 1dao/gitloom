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

-- PBKDF2-HMAC-SHA256 (RFC 8018) is `xutils.pbkdf2_sha256`, a C binding.
--
-- It used to be written here: a loop of C HMAC calls with the 32-byte XOR done
-- in interpreted Lua, plus a probe that compiled `a ~ b` to find out whether
-- this backend was 5.3+ or LuaJIT, because the two spell bitwise XOR
-- differently. The same loop existed a second time in app/auth.lua for the boot
-- path, with a comment on each saying they must not drift — two copies of a
-- password-hashing primitive that had to agree byte for byte forever.
--
-- Measured at AUTH_PBKDF2_ITER=10000 on the development machine: 44 ms in Lua
-- against 6 ms in C, identical output. The thread still earns its place — 6 ms
-- of deliberate CPU per verification is still 6 ms the event loop would not be
-- serving anyone — but the algorithm is now in one place and not ours.
router.register('kdf_pbkdf2', function(password, salt, iterations)
    iterations = tonumber(iterations) or 10000
    -- A caller-supplied iteration count reaches a CPU loop, so bound it. The
    -- ceiling is high enough never to bind a real configuration and low enough
    -- that a corrupted stored hash cannot wedge this thread for minutes.
    if iterations < 1 then iterations = 1 end
    if iterations > 1000000 then
        error('kdf: iteration count ' .. iterations .. ' is out of range', 0)
    end
    local dk = xutils.pbkdf2_sha256(tostring(password), tostring(salt), iterations)
    if not dk then error('kdf: pbkdf2 refused the parameters', 0) end
    return xutils.hex_encode(dk)
end)

router.register('kdf_ping', function() return 'pong' end)

return {
    __thread_handle = router.handle,
}
