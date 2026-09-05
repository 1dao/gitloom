-- app/migrate.lua — the schema, and the runner that applies it.
--
-- Exports: migrate_run, migrate_status, migrate_latest
--
-- Every table gitloom owns is created here and nowhere else, as a numbered
-- migration that is applied once and then recorded. Adding a column later means
-- appending an entry; it never means editing one that has shipped, because the
-- databases that already ran it will not run it again.
--
-- COROUTINE-ONLY: every statement goes through db_exec, which yields.
--
-- TWO RULES FOR A NEW MIGRATION, both of them consequences of how this runs:
--
--   1. Statements must be idempotent — IF NOT EXISTS, or a guard. A crash
--      between a statement and the record that says it ran leaves the migration
--      pending, and the next boot starts it again from the top.
--
--      CREATE TABLE says IF NOT EXISTS and ALTER TABLE ... ADD COLUMN does not:
--      that spelling is MariaDB's, and this runs on MySQL. So a step may also
--      be a FUNCTION returning the same (ok, err) db_exec does, which is where
--      the "does this column already exist" question gets asked. See
--      column_absent below.
--   2. A first boot of two processes against one empty database is NOT
--      coordinated. GET_LOCK would be the obvious answer and does not work
--      here: the xmysql pool hands each query to whichever connection is free,
--      and an advisory lock belongs to the connection that took it, so the
--      release would arrive on a different one. Rule 1 is what makes the
--      uncoordinated case survivable rather than the lock. Revisit when more
--      than one process is actually a supported deployment — see the roadmap's
--      open decision on multi-process.

-- Names are fixed rather than configurable. A table prefix read from the config
-- would have to be pasted into every statement below, and db_ident cannot check
-- what it never sees.
local MIGRATIONS_TABLE = 'gl_schema_migrations'

-- VARCHAR(100) is not a round number: repo_name_ok caps an owner, repository or
-- account name at exactly 100 characters, so the column is the constraint the
-- application already enforces rather than a guess about it.
--
-- utf8mb4_bin on the identity columns, because the comparison has to mean what
-- Lua's == means. Accounts are case-sensitive (auth.lua looks users up by the
-- exact string); repositories are not, and repo.lua folds the case itself into
-- owner_key/name_key. A case-insensitive collation here would quietly make
-- `Alice` and `alice` one account.
-- Is `column` missing from `table_name`? Returns true, false, or nil plus a
-- message when the catalogue itself cannot be read.
--
-- information_schema rather than a failed ALTER: MySQL answers a duplicate
-- column with error 1060, and keying a migration off an error STRING is how a
-- server upgrade or a translated build turns a working migration into a broken
-- one. Asking is cheap and says what it means.
local function column_absent(table_name, column)
    local rows, err = db_query(string.format(
        'SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE() ' ..
        'AND table_name = %s AND column_name = %s LIMIT 1',
        db_quote(table_name), db_quote(column)))
    if not rows then return nil, err end
    return #rows == 0
end

-- ALTER TABLE ... ADD COLUMN, but only when it is not already there.
local function add_column(table_name, column, definition)
    local absent, err = column_absent(table_name, column)
    if absent == nil then return nil, err end
    if not absent then return true end
    return db_exec(string.format('ALTER TABLE %s ADD COLUMN %s %s',
        db_ident(table_name), db_ident(column), definition))
end

local MIGRATIONS = {
    {
        id = 1,
        name = 'accounts and repositories',
        up = {
            [[CREATE TABLE IF NOT EXISTS gl_users (
                username   VARCHAR(100)  NOT NULL,
                pwhash     VARCHAR(255)  NOT NULL,
                email      VARCHAR(255)  NOT NULL DEFAULT '',
                is_admin   TINYINT       NOT NULL DEFAULT 0,
                created_at BIGINT        NOT NULL DEFAULT 0,
                tokens     TEXT          NULL,
                PRIMARY KEY (username)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],

            -- owner_key/name_key are the case-folded identity, and reproduce
            -- repo.lua's index key exactly: two repositories differing only in
            -- case are one repository, because on a case-insensitive filesystem
            -- they are one directory.
            [[CREATE TABLE IF NOT EXISTS gl_repos (
                owner_key      VARCHAR(100) NOT NULL,
                name_key       VARCHAR(100) NOT NULL,
                owner          VARCHAR(100) NOT NULL,
                name           VARCHAR(100) NOT NULL,
                description    TEXT         NULL,
                is_private     TINYINT      NOT NULL DEFAULT 0,
                default_branch VARCHAR(100) NOT NULL DEFAULT 'main',
                created_at     BIGINT       NOT NULL DEFAULT 0,
                collaborators  TEXT         NULL,
                PRIMARY KEY (owner_key, name_key),
                KEY gl_repos_owner (owner_key)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
        },
    },
    {
        id = 2,
        name = 'issues',
        up = {
            -- owner/name alongside owner_key/name_key for the same reason
            -- gl_repos carries both: the key is the case-folded identity, and
            -- these keep the casing the repository was created with. The DAO
            -- reads them, so leaving them out is not a smaller table — it is a
            -- SELECT of a column that does not exist, on every boot.
            --
            -- comments is MEDIUMTEXT, not TEXT. issue.lua allows 1000 comments
            -- of 8 KiB, which is 8 MB; TEXT holds 65,535 bytes, so the declared
            -- limit and the column disagreed by a factor of 125 and an issue
            -- became unwritable — including unclosable — long before the cap.
            [[CREATE TABLE IF NOT EXISTS gl_issues (
                owner_key  VARCHAR(100) NOT NULL,
                name_key   VARCHAR(100) NOT NULL,
                owner      VARCHAR(100) NOT NULL,
                name       VARCHAR(100) NOT NULL,
                number     INT          NOT NULL,
                title      VARCHAR(200) NOT NULL,
                body       TEXT         NOT NULL,
                state      VARCHAR(10)  NOT NULL DEFAULT 'open',
                author     VARCHAR(100) NOT NULL,
                created_at BIGINT       NOT NULL DEFAULT 0,
                updated_at BIGINT       NOT NULL DEFAULT 0,
                comments   MEDIUMTEXT   NULL,
                PRIMARY KEY (owner_key, name_key, number),
                KEY gl_issues_repo (owner_key, name_key)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
        },
    },
    {
        id = 3,
        name = 'account recovery codes',
        up = {
            -- The one credential someone who has forgotten their password can
            -- still produce. Stored exactly like a password — pbkdf2$... — and
            -- therefore with its own embedded salt, which is what keeps a
            -- password change from silently invalidating the code the user
            -- wrote down months ago.
            function()
                return add_column('gl_users', 'recovery',
                    "VARCHAR(255) NOT NULL DEFAULT ''")
            end,
        },
    },
}

function g_exports.migrate_latest()
    local top = 0
    for _, m in ipairs(MIGRATIONS) do
        if m.id > top then top = m.id end
    end
    return top
end

local function ensure_ledger()
    return db_exec(string.format([[CREATE TABLE IF NOT EXISTS %s (
        id         INT          NOT NULL,
        name       VARCHAR(190) NOT NULL,
        applied_at BIGINT       NOT NULL,
        PRIMARY KEY (id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]], db_ident(MIGRATIONS_TABLE)))
end

local function applied_ids()
    local rows, err = db_query('SELECT id FROM ' .. db_ident(MIGRATIONS_TABLE))
    if not rows then return nil, err end
    local seen = {}
    for _, r in ipairs(rows) do
        local id = db_number(r.id)
        if id then seen[id] = true end
    end
    return seen
end

-- Apply everything not yet recorded. Returns the number applied (0 is a
-- success — a database that is already current), or nil plus a message.
function g_exports.migrate_run()
    local ok, err = ensure_ledger()
    if not ok then return nil, 'could not create the migration ledger: ' .. tostring(err) end

    local seen, serr = applied_ids()
    if not seen then return nil, 'could not read the migration ledger: ' .. tostring(serr) end

    local applied = 0
    for _, m in ipairs(MIGRATIONS) do
        if not seen[m.id] then
            for i, step in ipairs(m.up) do
                local rc, xerr
                if type(step) == 'function' then rc, xerr = step()
                else rc, xerr = db_exec(step) end
                if not rc then
                    return nil, string.format('migration %d (%s) step %d failed: %s',
                        m.id, m.name, i, tostring(xerr))
                end
            end
            -- Recorded only once every statement has succeeded. The other order
            -- would mark a half-applied schema as done.
            local rc, ierr = db_exec(string.format(
                'INSERT INTO %s (id, name, applied_at) VALUES (%s, %s, %s)',
                db_ident(MIGRATIONS_TABLE),
                db_quote(m.id), db_quote(m.name), db_quote(os.time())))
            if not rc then
                return nil, string.format('migration %d (%s) applied but not recorded: %s',
                    m.id, m.name, tostring(ierr))
            end
            cfg_log_system('schema migration %d applied: %s', m.id, m.name)
            applied = applied + 1
        end
    end
    return applied
end

-- For the boot line and for tests: how far the database has got.
-- Returns { applied = n, latest = n, pending = n }, or nil plus a message.
function g_exports.migrate_status()
    local seen, err = applied_ids()
    if not seen then return nil, err end
    local count, pending = 0, 0
    for _, m in ipairs(MIGRATIONS) do
        if seen[m.id] then count = count + 1 else pending = pending + 1 end
    end
    return { applied = count, latest = migrate_latest(), pending = pending }
end
