-- app/store.lua — where accounts and repositories are kept.
--
-- Exports: store_backend, store_describe,
--          store_users_load, store_user_put,
--          store_repos_load, store_repo_put, store_repo_delete,
--          store_issues_load, store_issue_put, store_issue_repo_delete
--
-- Two backends behind one interface. JSON files are the default and are what
-- Phase 0 shipped: one process, one directory, nothing to install. MySQL is the
-- same data in two tables, and is what more than one process would need.
-- DB_DRIVER picks between them.
--
-- THE CONTRACT, identical for both, and what keeps repo.lua and auth.lua free
-- of any of this:
--
--   store_*_load()      returns THE map the caller then owns and mutates. Not a
--                       copy: repo.lua's index and auth.lua's user table ARE
--                       this table, so a record changed in place is already
--                       changed here.
--   store_*_put(rec)    persists ONE record the caller has already put in that
--                       map.
--   store_repo_delete() persists a removal the caller has already made.
--
-- That split is what lets the file backend keep doing the only thing a file can
-- do — rewrite the lot — while the SQL backend writes the single row that
-- changed, and neither caller has to know which happened.
--
-- COROUTINE-ONLY under MySQL: every statement yields on an RPC into the worker
-- thread. Callers must assume that rule whatever the backend, because which one
-- is running is a deployment choice and not a property of the call site.

local xutils = require('xutils')

-- The maps handed out by the loaders, kept so the file backend can rewrite the
-- whole file from the caller's own table without being handed it again.
local users_map = nil
local repos_map = nil
local issues_map = nil

function g_exports.store_backend()
    return db_enabled() and 'mysql' or 'json'
end

-- One line for the boot log: which store, and where.
function g_exports.store_describe()
    if db_enabled() then
        return string.format('mysql %s@%s:%d/%s',
            cfg_get('DB_USER', ''), cfg_get('DB_HOST', '127.0.0.1'),
            cfg_int('DB_PORT', 3306), cfg_get('DB_NAME', ''))
    end
    return string.format('json files (%s, %s)',
        cfg_get('USERS_FILE', 'data/users.json'),
        util_path_join(repo_root(), 'index.json'))
end

-- ---------------------------------------------------------------------------
-- JSON, for the sub-fields with no column of their own
--
-- Tokens are a list and collaborators are a map; both are open-ended, and both
-- are only ever read through the record they belong to. A table each would be a
-- join for data that nothing queries by.
--
-- json_pack returns nil rather than raising on invalid UTF-8, and a token label
-- is user-supplied, so that is reachable. Storing the string "nil" instead is
-- exactly the kind of quiet corruption this codebase keeps refusing, so both
-- directions check.
-- ---------------------------------------------------------------------------

local function encode_sub(value, what)
    if type(value) ~= 'table' then return nil end
    if next(value) == nil then return nil end          -- empty is simply absent
    local json = xutils.json_pack(value)
    if not json then
        return nil, what .. ' could not be serialised (invalid UTF-8?)'
    end
    return json
end

local function decode_sub(text)
    if text == nil or text == '' then return nil end
    local ok, parsed = pcall(xutils.json_unpack, text)
    if not ok or type(parsed) ~= 'table' then return nil end
    if next(parsed) == nil then return nil end
    return parsed
end

-- ---------------------------------------------------------------------------
-- The file backend
-- ---------------------------------------------------------------------------

local function users_path()
    return cfg_get('USERS_FILE', 'data/users.json')
end

local function repos_path()
    return util_path_join(repo_root(), 'index.json')
end

local function issues_path()
    return util_path_join(cfg_get('DATA_DIR', 'data'), 'issues.json')
end

local function file_users_load()
    local map = {}
    local raw = util_file_read(users_path())
    if not raw or raw == '' then return map end
    local parsed = xutils.json_unpack(raw)
    if type(parsed) ~= 'table' or type(parsed.users) ~= 'table' then
        cfg_log_warn('account file %s is unreadable; starting with no accounts',
            users_path())
        return map
    end
    for _, u in ipairs(parsed.users) do
        if type(u) == 'table' and type(u.username) == 'string' then
            u.tokens = u.tokens or {}
            map[u.username] = u
        end
    end
    return map
end

-- Rewrite the account file through util_file_write_atomic, so a crash can never
-- leave the instance with no accounts at all — see the note there on why the
-- obvious delete-then-rename is worse than no atomicity.
local function file_users_save()
    -- A put before a load would rewrite the file from an empty map, which is to
    -- say it would delete every account. Nothing reaches this today — every
    -- caller goes through have_users first — but the cost of being wrong about
    -- that later is the whole account file, so it refuses instead.
    if not users_map then return nil, 'accounts have not been loaded' end

    local list = {}
    for _, u in pairs(users_map or {}) do list[#list + 1] = u end
    table.sort(list, function(a, b) return a.username < b.username end)

    local json = xutils.json_pack({ version = 1, users = list })
    if not json then return nil, 'account serialisation failed' end

    util_dir_make(cfg_get('DATA_DIR', 'data'))
    local ok, err = util_file_write_atomic(users_path(), json)
    if not ok then return nil, 'account save failed: ' .. tostring(err) end
    return true
end

local function file_repos_load()
    local map = {}
    local raw = util_file_read(repos_path())
    if not raw or raw == '' then return map end
    local parsed = xutils.json_unpack(raw)
    if type(parsed) ~= 'table' or type(parsed.repos) ~= 'table' then
        cfg_log_warn('repository index at %s is unreadable; starting empty', repos_path())
        return map
    end
    for _, r in ipairs(parsed.repos) do
        if type(r) == 'table' and repo_name_ok(r.owner) and repo_name_ok(r.name) then
            map[repo_key(r.owner, r.name)] = r
        end
    end
    return map
end

local function file_repos_save()
    -- As above: an empty map here would truncate the index to nothing.
    if not repos_map then return nil, 'the repository index has not been loaded' end

    local list = {}
    for _, r in pairs(repos_map or {}) do list[#list + 1] = r end
    table.sort(list, function(a, b)
        if a.owner ~= b.owner then return a.owner < b.owner end
        return a.name < b.name
    end)

    local json = xutils.json_pack({ version = 1, repos = list })
    if not json then
        -- A description pasted from a mis-decoded source can do this. Refusing
        -- beats truncating the index to nothing.
        return nil, 'index serialisation failed (invalid UTF-8 in a field?)'
    end

    local ok, err = util_file_write_atomic(repos_path(), json)
    if not ok then return nil, 'index save failed: ' .. tostring(err) end
    return true
end

local function file_issues_load()
    local map = {}
    local raw = util_file_read(issues_path())
    if not raw or raw == '' then return map end
    local parsed = xutils.json_unpack(raw)
    if type(parsed) ~= 'table' or type(parsed.issues) ~= 'table' then
        cfg_log_warn('issue store at %s is unreadable; starting empty', issues_path())
        return map
    end
    for _, issue in ipairs(parsed.issues) do
        if type(issue) == 'table' and repo_name_ok(issue.owner) and
           repo_name_ok(issue.name) and tonumber(issue.number) and
           tonumber(issue.number) > 0 and
           type(issue.title) == 'string' and type(issue.body) == 'string' and
           type(issue.author) == 'string' and
           (issue.state == 'open' or issue.state == 'closed') then
            local key = repo_key(issue.owner, issue.name)
            map[key] = map[key] or {}
            issue.number = math.floor(tonumber(issue.number))
            issue.comments = type(issue.comments) == 'table' and issue.comments or {}
            map[key][issue.number] = issue
        end
    end
    return map
end

local function file_issues_save()
    if not issues_map then return nil, 'issues have not been loaded' end

    local list = {}
    for _, by_number in pairs(issues_map) do
        for _, issue in pairs(by_number) do list[#list + 1] = issue end
    end
    table.sort(list, function(a, b)
        if a.owner ~= b.owner then return a.owner < b.owner end
        if a.name ~= b.name then return a.name < b.name end
        return a.number < b.number
    end)

    local json = xutils.json_pack({ version = 1, issues = list })
    if not json then return nil, 'issue serialisation failed (invalid UTF-8?)' end
    util_dir_make(cfg_get('DATA_DIR', 'data'))
    local ok, err = util_file_write_atomic(issues_path(), json)
    if not ok then return nil, 'issue save failed: ' .. tostring(err) end
    return true
end

-- ---------------------------------------------------------------------------
-- The MySQL backend
--
-- Every column arrives as a string and a NULL one is absent, so nothing here
-- reads a row field directly — db_number, db_boolean and db_text are what turn
-- a row back into the record shape the application has always used.
-- ---------------------------------------------------------------------------

local function row_to_user(row)
    return {
        username   = db_text(row.username, ''),
        pwhash     = db_text(row.pwhash, ''),
        email      = db_text(row.email, ''),
        admin      = db_boolean(row.is_admin),
        created_at = db_number(row.created_at, 0),
        tokens     = decode_sub(row.tokens) or {},
    }
end

local function db_users_load()
    local rows, err = db_query(
        'SELECT username, pwhash, email, is_admin, created_at, tokens FROM gl_users')
    if not rows then return nil, 'could not read accounts: ' .. tostring(err) end
    local map = {}
    for _, row in ipairs(rows) do
        local u = row_to_user(row)
        if u.username ~= '' then map[u.username] = u end
    end
    return map
end

-- One statement, so a concurrent reader never sees the row missing. The update
-- list repeats every column but the key, because an insert-only upsert would
-- fail the moment somebody changed a password.
local function db_user_put(u)
    local tokens, terr = encode_sub(u.tokens, 'token list')
    if terr then return nil, terr end

    local ok, err = db_exec(string.format(
        'INSERT INTO gl_users (username, pwhash, email, is_admin, created_at, tokens) ' ..
        'VALUES (%s, %s, %s, %s, %s, %s) ' ..
        'ON DUPLICATE KEY UPDATE pwhash=VALUES(pwhash), email=VALUES(email), ' ..
        'is_admin=VALUES(is_admin), created_at=VALUES(created_at), tokens=VALUES(tokens)',
        db_quote(u.username), db_quote(u.pwhash or ''), db_quote(u.email or ''),
        db_quote(u.admin and true or false), db_quote(u.created_at or 0),
        db_quote(tokens)))
    if not ok then return nil, 'could not save the account: ' .. tostring(err) end
    return true
end

local function row_to_repo(row)
    return {
        owner          = db_text(row.owner, ''),
        name           = db_text(row.name, ''),
        description    = db_text(row.description, ''),
        private        = db_boolean(row.is_private),
        default_branch = db_text(row.default_branch, cfg_get('DEFAULT_BRANCH', 'main')),
        created_at     = db_number(row.created_at, 0),
        collaborators  = decode_sub(row.collaborators),
    }
end

local function db_repos_load()
    local rows, err = db_query('SELECT owner, name, description, is_private, ' ..
        'default_branch, created_at, collaborators FROM gl_repos')
    if not rows then return nil, 'could not read the repository index: ' .. tostring(err) end
    local map = {}
    for _, row in ipairs(rows) do
        local r = row_to_repo(row)
        if repo_name_ok(r.owner) and repo_name_ok(r.name) then
            map[repo_key(r.owner, r.name)] = r
        end
    end
    return map
end

-- owner_key/name_key are the case-folded identity and are what the primary key
-- is on; owner/name keep the casing the request used. repo.lua relies on
-- exactly that split, which is why repo_dir_of reads the record and never the
-- URL.
local function db_repo_put(r)
    local collab, cerr = encode_sub(r.collaborators, 'collaborator list')
    if cerr then return nil, cerr end

    local ok, err = db_exec(string.format(
        'INSERT INTO gl_repos (owner_key, name_key, owner, name, description, ' ..
        'is_private, default_branch, created_at, collaborators) ' ..
        'VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) ' ..
        'ON DUPLICATE KEY UPDATE owner=VALUES(owner), name=VALUES(name), ' ..
        'description=VALUES(description), is_private=VALUES(is_private), ' ..
        'default_branch=VALUES(default_branch), created_at=VALUES(created_at), ' ..
        'collaborators=VALUES(collaborators)',
        db_quote(r.owner:lower()), db_quote(r.name:lower()),
        db_quote(r.owner), db_quote(r.name),
        db_quote(r.description or ''), db_quote(r.private and true or false),
        db_quote(r.default_branch or cfg_get('DEFAULT_BRANCH', 'main')),
        db_quote(r.created_at or 0), db_quote(collab)))
    if not ok then return nil, 'could not save the repository: ' .. tostring(err) end
    return true
end

local function db_repo_delete(owner, name)
    local ok, err = db_exec(string.format(
        'DELETE FROM gl_repos WHERE owner_key = %s AND name_key = %s',
        db_quote(tostring(owner):lower()), db_quote(tostring(name):lower())))
    if not ok then return nil, 'could not delete the repository: ' .. tostring(err) end
    return true
end

local function row_to_issue(row)
    return {
        owner      = db_text(row.owner, ''),
        name       = db_text(row.name, ''),
        number     = db_number(row.number, 0),
        title      = db_text(row.title, ''),
        body       = db_text(row.body, ''),
        state      = db_text(row.state, 'open'),
        author     = db_text(row.author, ''),
        created_at = db_number(row.created_at, 0),
        updated_at = db_number(row.updated_at, 0),
        comments   = decode_sub(row.comments) or {},
    }
end

local function db_issues_load()
    local rows, err = db_query(
        'SELECT owner_key, name_key, owner, name, number, title, body, state, ' ..
        'author, created_at, updated_at, comments FROM gl_issues')
    if not rows then return nil, 'could not read issues: ' .. tostring(err) end
    local map = {}
    for _, row in ipairs(rows) do
        local issue = row_to_issue(row)
        if repo_name_ok(issue.owner) and repo_name_ok(issue.name) and
           issue.number and issue.number > 0 and
           (issue.state == 'open' or issue.state == 'closed') then
            local key = repo_key(issue.owner, issue.name)
            map[key] = map[key] or {}
            map[key][issue.number] = issue
        end
    end
    return map
end

local function db_issue_put(issue)
    local comments, cerr = encode_sub(issue.comments, 'issue comments')
    if cerr then return nil, cerr end
    local ok, err = db_exec(string.format(
        'INSERT INTO gl_issues (owner_key, name_key, owner, name, number, title, ' ..
        'body, state, author, created_at, updated_at, comments) VALUES ' ..
        '(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ' ..
        'ON DUPLICATE KEY UPDATE title=VALUES(title), body=VALUES(body), ' ..
        'state=VALUES(state), updated_at=VALUES(updated_at), comments=VALUES(comments)',
        db_quote(issue.owner:lower()), db_quote(issue.name:lower()),
        db_quote(issue.owner), db_quote(issue.name), db_quote(issue.number),
        db_quote(issue.title), db_quote(issue.body), db_quote(issue.state),
        db_quote(issue.author), db_quote(issue.created_at or 0),
        db_quote(issue.updated_at or 0), db_quote(comments)))
    if not ok then return nil, 'could not save the issue: ' .. tostring(err) end
    return true
end

local function db_issue_repo_delete(owner, name)
    local ok, err = db_exec(string.format(
        'DELETE FROM gl_issues WHERE owner_key = %s AND name_key = %s',
        db_quote(tostring(owner):lower()), db_quote(tostring(name):lower())))
    if not ok then return nil, 'could not delete repository issues: ' .. tostring(err) end
    return true
end

-- ---------------------------------------------------------------------------
-- The interface
-- ---------------------------------------------------------------------------

function g_exports.store_users_load()
    local map, err
    if db_enabled() then map, err = db_users_load() else map = file_users_load() end
    if not map then return nil, err end
    users_map = map
    return users_map
end

function g_exports.store_user_put(u)
    if db_enabled() then return db_user_put(u) end
    return file_users_save()
end

function g_exports.store_repos_load()
    local map, err
    if db_enabled() then map, err = db_repos_load() else map = file_repos_load() end
    if not map then return nil, err end
    repos_map = map
    return repos_map
end

function g_exports.store_repo_put(r)
    if db_enabled() then return db_repo_put(r) end
    return file_repos_save()
end

function g_exports.store_repo_delete(owner, name)
    if db_enabled() then return db_repo_delete(owner, name) end
    return file_repos_save()
end

function g_exports.store_issues_load()
    local map, err
    if db_enabled() then map, err = db_issues_load() else map = file_issues_load() end
    if not map then return nil, err end
    issues_map = map
    return issues_map
end

function g_exports.store_issue_put(issue)
    if db_enabled() then return db_issue_put(issue) end
    return file_issues_save()
end

function g_exports.store_issue_repo_delete(owner, name)
    if db_enabled() then return db_issue_repo_delete(owner, name) end
    return file_issues_save()
end
