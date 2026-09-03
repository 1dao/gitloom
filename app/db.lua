-- app/db.lua — the MySQL connection, and the only place SQL literals are built.
--
-- Exports: db_driver, db_enabled, db_start, db_stop, db_ready,
--          db_query, db_exec, db_quote, db_ident,
--          db_number, db_boolean, db_text
--
-- Thin layer over scripts/core/server/xmysql.lua, which owns the protocol and
-- the connection pool on its own thread. What is added here is the two things
-- that module deliberately does not have: a way to build a statement safely,
-- and a result shape the application can use without knowing MySQL's.
--
-- db_query and db_exec are COROUTINE-ONLY — they yield on an RPC into the
-- worker thread, exactly like proc_exec. Every HTTP request runs on its own
-- coroutine, so any handler may call them; boot code may not unless it wraps
-- itself, which is why main.lua loads the stores from boot_async.

local xmysql = dofile('scripts/core/server/xmysql.lua')

local started = false

function g_exports.db_driver()
    return tostring(cfg_get('DB_DRIVER', 'none')):lower()
end

function g_exports.db_enabled()
    return db_driver() == 'mysql'
end

function g_exports.db_ready()
    return started
end

-- ---------------------------------------------------------------------------
-- Building statements
--
-- xmysql.query takes a finished SQL string: there is no parameter binding and
-- no escape helper anywhere underneath. So every value that reaches a statement
-- goes through db_quote, and db_quote does not escape.
--
-- IT ENCODES. A string becomes a hex literal with a character-set introducer —
-- _utf8mb4 X'68656C6C6F' — which has no quote character in it to close early,
-- no backslash whose meaning depends on the server's sql_mode, and therefore no
-- escaping to get wrong. `x' OR '1'='1` comes back out of the database as the
-- fourteen characters somebody typed.
--
-- The introducer is not decoration. A bare X'...' is a *binary* string, and
-- comparing one against a utf8mb4 column risks an illegal mix of collations;
-- with it, MySQL plans the lookup as an ordinary constant — verified against
-- 8.4 with EXPLAIN, which reports type=const on the primary key.
-- ---------------------------------------------------------------------------

local function to_hex(s)
    return (s:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

function g_exports.db_quote(v)
    if v == nil then return 'NULL' end

    local t = type(v)
    if t == 'boolean' then return v and '1' or '0' end

    if t == 'number' then
        -- NaN and the infinities have no SQL literal, and %d on a fraction
        -- raises in Lua 5.3+. Both are programming errors, not data.
        if v ~= v or v == math.huge or v == -math.huge then
            error('db_quote: ' .. tostring(v) .. ' has no SQL literal', 2)
        end
        if math.floor(v) == v and math.abs(v) < 2 ^ 53 then
            return string.format('%d', v)
        end
        return string.format('%.17g', v)
    end

    if t ~= 'string' then
        error('db_quote: cannot quote a ' .. t, 2)
    end
    return "_utf8mb4 X'" .. to_hex(v) .. "'"
end

-- A table or column name. Identifiers cannot be hex literals, so this is a
-- whitelist instead: anything that is not a plain unquoted name is a bug in the
-- caller, never data, and raising says so at the call site.
function g_exports.db_ident(name)
    local s = tostring(name)
    if not s:match('^[A-Za-z_][A-Za-z0-9_]*$') then
        error('db_ident: refusing ' .. string.format('%q', s), 2)
    end
    return '`' .. s .. '`'
end

-- ---------------------------------------------------------------------------
-- Running statements
--
-- The worker answers a SELECT with { ok, fields, rows, values } and everything
-- else with { ok, affected_rows, last_insert_id }; a failure comes back as
-- ok=false with the server's message. Collapse both into the shapes the rest of
-- the application expects: a list of rows, or a count.
-- ---------------------------------------------------------------------------

-- Rows as a list of column->value maps, or nil plus a message. The list is
-- empty when nothing matched, which is not a failure.
function g_exports.db_query(sql)
    local ok, res = xmysql.query(sql)
    if not ok then return nil, tostring(res or 'query failed') end
    if type(res) ~= 'table' then return nil, 'unexpected result from the mysql worker' end
    return res.rows or {}
end

-- Affected rows, or nil plus a message. Note that 0 is a success: an UPDATE
-- that changed nothing is not an error, so callers must test for nil.
function g_exports.db_exec(sql)
    local ok, res = xmysql.query(sql)
    if not ok then return nil, tostring(res or 'statement failed') end
    if type(res) ~= 'table' then return nil, 'unexpected result from the mysql worker' end
    return tonumber(res.affected_rows) or 0
end

-- ---------------------------------------------------------------------------
-- Reading values back
--
-- EVERY column arrives as a string, whatever its declared type — a BIGINT comes
-- back as "42" and a TINYINT as "1". A NULL column is simply absent from the
-- row, so a missing key and a NULL are the same thing here.
--
-- These three exist so that no caller has to remember that.
-- ---------------------------------------------------------------------------

function g_exports.db_number(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

function g_exports.db_boolean(v)
    if v == nil then return false end
    local n = tonumber(v)
    if n then return n ~= 0 end
    local s = tostring(v):lower()
    return s == 'true' or s == 'y' or s == 't'
end

function g_exports.db_text(v, default)
    if v == nil then return default end
    return tostring(v)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Start the worker thread and its connection pool. Safe from the main state:
-- xmysql.start creates the thread and posts to it, and neither yields. Nothing
-- is connected yet when this returns — the first query is what proves that, and
-- db_start is followed by the migration run for exactly that reason.
--
-- Returns true, or nil plus a message.
function g_exports.db_start()
    if started then return true end
    if not db_enabled() then return nil, 'DB_DRIVER is not mysql' end

    local name = cfg_get('DB_NAME', '')
    if name == '' then return nil, 'DB_DRIVER=mysql needs DB_NAME' end

    local host, port = cfg_get('DB_HOST', '127.0.0.1'), cfg_int('DB_PORT', 3306)
    local user = cfg_get('DB_USER', '')

    local ok, err = xmysql.start({
        host     = host,
        port     = port,
        user     = user,
        password = cfg_get('DB_PASSWORD', ''),
        database = name,
        pool_size = cfg_int('DB_POOL', 4),
    })
    if not ok then return nil, tostring(err) end

    started = true
    -- Never the password, not even at debug level: this line is the first thing
    -- anybody pastes into a bug report.
    cfg_log_system('mysql: %s@%s:%d database %s, pool %d',
        user, host, port, name, cfg_int('DB_POOL', 4))
    return true
end

function g_exports.db_stop()
    if not started then return end
    started = false
    xmysql.stop(true)
end
