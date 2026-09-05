-- app/issue.lua — a small repository issue tracker.
--
-- Exports: issue_index_load, issue_list, issue_get, issue_create,
--          issue_update, issue_comment_create, issue_repo_delete
--
-- Issues are deliberately separate from the repository index. The JSON backend
-- keeps them in DATA_DIR/issues.json; MySQL stores one row per issue. That
-- keeps repository metadata small and gives the later pull-request work a
-- stable number/comment model to build on.

local issues = nil       -- { [repo_key] = { [number] = issue } }

-- Each limit is in the unit ITS COLUMN counts in, which is not the same unit
-- twice: title is VARCHAR(200), which MySQL counts in characters, while body
-- and a comment land in TEXT and MEDIUMTEXT, which it counts in bytes. Using
-- `#s` for all three made the title limit mean something different depending on
-- the language it was written in — 200 letters of English, 66 characters of
-- Chinese — and left the body one byte over what TEXT can hold.
local MAX_TITLE = 200         -- characters, matching VARCHAR(200)
local MAX_BODY = 65535        -- bytes, the whole of TEXT
local MAX_COMMENT = 8192      -- bytes
local MAX_COMMENTS = 1000     -- 1000 x 8 KiB = 8 MB, inside MEDIUMTEXT's 16 MB

-- Length as the title's column counts it.
--
-- utf8.len is Lua 5.3 and later; boot.lua still supports 5.1, and invalid UTF-8
-- makes it return nil. Both fall back to the byte count, which is never smaller
-- than the character count and so can only be stricter — never a value the
-- column cannot hold.
local function text_length(value)
    if utf8 and utf8.len then
        local n = utf8.len(value)
        if n then return n end
    end
    return #value
end

local function have_issues()
    if issues then return true end
    return issue_index_load() ~= nil
end

local function key(owner, name)
    return repo_key(owner, name)
end

local function valid_repo(owner, name)
    return repo_name_ok(owner) and repo_name_ok(name)
end

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function issue_map(owner, name, make)
    local k = key(owner, name)
    local map = issues[k]
    if not map and make then
        map = {}
        issues[k] = map
    end
    return map, k
end

function g_exports.issue_index_load()
    local map, err = store_issues_load()
    if not map then
        cfg_log_error('issue store unavailable: %s', tostring(err))
        return nil, err
    end
    issues = map
    return issues
end

local function issue_number(value)
    local n = tonumber(value)
    if not n or n < 1 or n ~= math.floor(n) then return nil end
    return n
end

function g_exports.issue_list(owner, name, state)
    if not valid_repo(owner, name) then return {} end
    if not have_issues() then return {} end
    local map = issue_map(owner, name)
    local out = {}
    for _, issue in pairs(map or {}) do
        if state == nil or state == 'all' or issue.state == state then
            out[#out + 1] = issue
        end
    end
    table.sort(out, function(a, b)
        if a.number ~= b.number then return a.number > b.number end
        return a.created_at > b.created_at
    end)
    return out
end

function g_exports.issue_get(owner, name, number)
    if not valid_repo(owner, name) or not have_issues() then return nil end
    local n = issue_number(number)
    if not n then return nil end
    local map = issue_map(owner, name)
    return map and map[n] or nil
end

function g_exports.issue_create(owner, name, author, opts)
    if not valid_repo(owner, name) then
        return nil, 'bad repository name', 400
    end
    if not repo_get(owner, name) then return nil, 'no such repository', 404 end
    if not repo_name_ok(author) then return nil, 'bad account name', 400 end
    if type(opts) ~= 'table' then return nil, 'expected a JSON object body', 400 end

    local title = trim(opts.title)
    if title == '' then return nil, 'issue title is required', 400 end
    if text_length(title) > MAX_TITLE then
        return nil, string.format('issue title must be at most %d characters', MAX_TITLE), 400
    end
    local body = opts.body == nil and '' or opts.body
    if type(body) ~= 'string' then return nil, 'issue body must be a string', 400 end
    if #body > MAX_BODY then
        return nil, string.format('issue body must be at most %d bytes', MAX_BODY), 400
    end
    if not have_issues() then return nil, 'the issue store is unavailable', 500 end

    local map = issue_map(owner, name, true)
    local number = 0
    for n in pairs(map) do if n > number then number = n end end
    number = number + 1
    local now = os.time()
    local issue = {
        owner = owner,
        name = name,
        number = number,
        title = title,
        body = body,
        state = 'open',
        author = author,
        created_at = now,
        updated_at = now,
        comments = {},
    }
    map[number] = issue
    local ok, err = store_issue_put(issue)
    if not ok then
        map[number] = nil
        if next(map) == nil then issues[key(owner, name)] = nil end
        return nil, 'could not persist issue: ' .. tostring(err), 500
    end
    return issue
end

function g_exports.issue_update(owner, name, number, opts)
    if not valid_repo(owner, name) then return nil, 'bad repository name', 400 end
    if type(opts) ~= 'table' then return nil, 'expected a JSON object body', 400 end
    local issue = issue_get(owner, name, number)
    if not issue then return nil, 'no such issue', 404 end

    local old_title, old_body, old_state, old_updated =
        issue.title, issue.body, issue.state, issue.updated_at
    if opts.title ~= nil then
        if type(opts.title) ~= 'string' then return nil, 'issue title must be a string', 400 end
        issue.title = trim(opts.title)
        if issue.title == '' then
            issue.title = old_title
            return nil, 'issue title is required', 400
        end
        if text_length(issue.title) > MAX_TITLE then
            issue.title = old_title
            return nil, string.format('issue title must be at most %d characters', MAX_TITLE), 400
        end
    end
    if opts.body ~= nil then
        if type(opts.body) ~= 'string' then
            issue.title, issue.body = old_title, old_body
            return nil, 'issue body must be a string', 400
        end
        if #opts.body > MAX_BODY then
            issue.title, issue.body = old_title, old_body
            return nil, string.format('issue body must be at most %d bytes', MAX_BODY), 400
        end
        issue.body = opts.body
    end
    if opts.state ~= nil then
        if opts.state ~= 'open' and opts.state ~= 'closed' then
            issue.title, issue.body = old_title, old_body
            return nil, 'issue state must be open or closed', 400
        end
        issue.state = opts.state
    end
    if issue.title == old_title and issue.body == old_body and issue.state == old_state then
        return issue
    end
    issue.updated_at = os.time()
    local ok, err = store_issue_put(issue)
    if not ok then
        issue.title, issue.body, issue.state, issue.updated_at =
            old_title, old_body, old_state, old_updated
        return nil, 'could not persist issue: ' .. tostring(err), 500
    end
    return issue
end

function g_exports.issue_comment_create(owner, name, number, author, body)
    if not valid_repo(owner, name) then return nil, 'bad repository name', 400 end
    if not repo_name_ok(author) then return nil, 'bad account name', 400 end
    if type(body) ~= 'string' or trim(body) == '' then
        return nil, 'comment body is required', 400
    end
    if #body > MAX_COMMENT then
        return nil, string.format('comment body must be at most %d bytes', MAX_COMMENT), 400
    end
    local issue = issue_get(owner, name, number)
    if not issue then return nil, 'no such issue', 404 end
    issue.comments = type(issue.comments) == 'table' and issue.comments or {}
    if #issue.comments >= MAX_COMMENTS then
        return nil, string.format('an issue may have at most %d comments', MAX_COMMENTS), 400
    end

    local id = 0
    for _, comment in ipairs(issue.comments) do
        if tonumber(comment.id) and comment.id > id then id = comment.id end
    end
    local comment = { id = id + 1, author = author, body = body, created_at = os.time() }
    issue.comments[#issue.comments + 1] = comment
    local old_updated = issue.updated_at
    issue.updated_at = os.time()
    local ok, err = store_issue_put(issue)
    if not ok then
        issue.comments[#issue.comments] = nil
        issue.updated_at = old_updated
        return nil, 'could not persist issue comment: ' .. tostring(err), 500
    end
    return comment
end

-- Called after a repository's git directory has been removed. Keeping issue
-- rows out of the store avoids records that can never be reached again.
function g_exports.issue_repo_delete(owner, name)
    if not valid_repo(owner, name) then return nil, 'bad repository name', 400 end
    if not have_issues() then return nil, 'the issue store is unavailable', 500 end
    local k = key(owner, name)
    local old = issues[k]
    issues[k] = nil
    local ok, err = store_issue_repo_delete(owner, name)
    if not ok then
        issues[k] = old
        return nil, err, 500
    end
    return true
end
