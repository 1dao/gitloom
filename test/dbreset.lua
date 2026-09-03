-- test/dbreset.lua — drop and recreate the test database.
--
--   bin/xnet test/dbreset.lua DB_HOST=... DB_USER=... DB_PASSWORD=... DB_NAME=...
--
-- Test scaffolding, not part of the application. gitloom itself never creates a
-- database: xmysql names one in the handshake, and a pooled `USE` would only
-- move whichever connection happened to run it — so the database existing is a
-- deployment step, and this is what does that step for test/smoke.sh.
--
-- Exit code 0 = the database is present and empty.

local xmysql = dofile('scripts/core/server/xmysql.lua')
local router = dofile('scripts/core/share/xrouter.lua')

-- Same source and same precedence as the application: command-line KEY=VAL
-- arguments are already in xutils' store and beat both files, and
-- gitloom.local.cfg beats the committed defaults. So the credentials can live
-- wherever the developer already keeps them.
local xutils = require('xutils')
xutils.load_config('gitloom.local.cfg')
xutils.load_config('gitloom.cfg')

local function arg_or(k, default)
    local v = xutils.get_config(k, default)
    if v == nil or v == '' then return default end
    return v
end

local function fail(fmt, ...)
    io.write('dbreset: ', string.format(fmt, ...), '\n')
    io.flush()
    xthread.stop(1)
end

-- The name is pasted into a statement that cannot use a placeholder, so it is
-- whitelisted rather than escaped. A test database called `x; DROP ...` is not a
-- threat model, but neither is it something to leave working.
local name = arg_or('DB_NAME', 'gitloom_test')
if not name:match('^[A-Za-z_][A-Za-z0-9_]*$') then
    io.write('dbreset: refusing database name ', string.format('%q', name), '\n')
    os.exit(2)
end

local function __init()
    assert(xnet.init())
    xtimer.init(8)

    -- Connected to `mysql`, not to the database being dropped: a connection
    -- inside it would be one of the things holding it open.
    local ok, err = xmysql.start({
        host = arg_or('DB_HOST', '127.0.0.1'),
        port = tonumber(arg_or('DB_PORT', '3306')) or 3306,
        user = arg_or('DB_USER', ''),
        password = arg_or('DB_PASSWORD', ''),
        database = 'mysql',
        pool_size = 1,
    })
    if not ok then return fail('connect failed: %s', tostring(err)) end

    -- The pool connects asynchronously; the first query is what proves it is up.
    xtimer.add(600, function()
        local co = coroutine.create(function()
            local dok, derr = xmysql.query('DROP DATABASE IF EXISTS ' .. name)
            if not dok then return fail('drop failed: %s', tostring(derr)) end
            local cok, cerr = xmysql.query(
                'CREATE DATABASE ' .. name .. ' CHARACTER SET utf8mb4')
            if not cok then return fail('create failed: %s', tostring(cerr)) end
            io.write('dbreset: ', name, ' is empty\n')
            io.flush()
            xthread.stop(0)
        end)
        local rok, rerr = coroutine.resume(co)
        if not rok then fail('crashed: %s', tostring(rerr)) end
    end, 1)
end

return {
    __thread_handle = router.handle,
    __init = __init,
    __uninit = function() xnet.uninit() end,
}
