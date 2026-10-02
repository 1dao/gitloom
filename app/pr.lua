-- Reviewed merges operate on immutable OIDs in a bare repository. A durable
-- intent precedes the atomic ref transaction; its private marker lets a retry
-- distinguish a committed merge from a crash before the ref update.
local prs = nil
local busy = false
local unpack_values = table.unpack or unpack

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end
local function key(owner, name) return owner:lower() .. '/' .. name:lower() end
local function oid(value)
    return type(value) == 'string' and (#value == 40 or #value == 64) and value:match('^[0-9a-f]+$')
end
local function number(value)
    local n = tonumber(value)
    if n and n > 0 and n <= 2147483647 and n == math.floor(n) then return tostring(n) end
end
local function text_ok(value, max, required)
    return type(value) == 'string' and #value <= max and not value:find('%z') and
        (not required or value:find('%S') ~= nil)
end
local function locked(fn)
    if busy then return nil, 'pull request operation in progress; retry', 409 end
    busy = true
    local result = { pcall(fn) }
    busy = false
    if not result[1] then
        cfg_log_error('pull request operation: %s', tostring(result[2]))
        return nil, 'pull request operation failed', 500
    end
    return unpack_values(result, 2, 4)
end

function g_exports.pr_index_load()
    local map, err = store_collaboration_load('pull_requests')
    if not map then cfg_log_error('pull request store: %s', tostring(err)); return nil end
    local normalized = {}
    for repo, records in pairs(map) do
        if type(repo) ~= 'string' or type(records) ~= 'table' then return nil end
        local target = {}
        for _, p in pairs(records) do
            if type(p) ~= 'table' or not number(p.number) or not text_ok(p.title, 200, true) or
               not text_ok(p.base, 255, true) or not text_ok(p.head, 255, true) or
               type(p.author) ~= 'string' or
               (p.state ~= 'open' and p.state ~= 'closed' and p.state ~= 'merged') then return nil end
            if p.comments ~= nil and type(p.comments) ~= 'table' or
               p.reviews ~= nil and type(p.reviews) ~= 'table' then return nil end
            p.number = tonumber(p.number)
            p.comments = p.comments or {}
            p.reviews = p.reviews or {}
            target[number(p.number)] = p
        end
        normalized[repo:lower()] = target
    end
    prs = normalized
    return prs
end

local function persist(map)
    local ok, err = store_collaboration_save('pull_requests', map)
    if not ok then
        cfg_log_error('pull request persistence: %s', tostring(err))
        return nil, 'could not persist pull request', 500
    end
    prs = map
    return true
end
local function put(rec, p)
    local map = copy(prs)
    local k = key(rec.owner, rec.name)
    map[k] = map[k] or {}
    map[k][number(p.number)] = p
    local ok, err, status = persist(map)
    if not ok then return nil, err, status end
    return p
end
local function get(rec, num)
    local k = number(num)
    return k and prs and (prs[key(rec.owner, rec.name)] or {})[k]
end
local function run(rec, args, options)
    options = options or {}
    options.cwd = repo_dir_of(rec)
    return git_exec(args, options)
end
local function branch(rec, ref)
    if not text_ok(ref, 255, true) or ref:find('[%c%s]') or ref:sub(1, 1) == '-' then
        return nil, 'invalid branch name', 400
    end
    local checked = run(rec, { 'check-ref-format', 'refs/heads/' .. ref })
    if not checked.ok then return nil, 'invalid branch name', 400 end
    local r = run(rec, { 'rev-parse', '--verify', '--quiet', '--end-of-options', 'refs/heads/' .. ref .. '^{commit}' })
    local value = util_str_trim(r.stdout or '')
    if not r.ok or not oid(value) then return nil, 'source or target branch is missing', 409 end
    return value
end
local function snapshot(rec, p)
    local base, err, status = branch(rec, p.base)
    if not base then return nil, err, status end
    local head, herr, hs = branch(rec, p.head)
    if not head then return nil, herr, hs end
    return { base_oid = base, head_oid = head }
end
local function marker(p) return 'refs/gitloom/pulls/' .. p.number .. '/merge' end

local function reconcile(rec, original)
    if not original.pending then return original end
    local p = copy(original)
    local r = run(rec, { 'rev-parse', '--verify', '--quiet', marker(p) })
    if r.ok and util_str_trim(r.stdout or '') == p.pending.oid then
        p.state, p.merge_oid = 'merged', p.pending.oid
        p.merged_by, p.merged_at = p.pending.actor, p.pending.at
        p.base_oid, p.head_oid = p.pending.base_oid, p.pending.head_oid
        p.merge_method = 'merge'
        local review = p.reviews[#p.reviews]
        if review then review.state = 'approve' end
    elseif r.exit_code == 1 then
        local review = p.reviews[#p.reviews]
        if review then review.state = 'merge_failed' end
    else
        return nil, 'merge result is pending reconciliation; retry', 503
    end
    p.pending = nil
    p.updated_at = os.time()
    return put(rec, p)
end

function g_exports.pr_list(rec, state)
    if not prs then return nil, 'pull request store unavailable', 503 end
    if state ~= 'all' and state ~= 'open' and state ~= 'closed' and state ~= 'merged' then
        return nil, 'invalid pull request state', 400
    end
    local list = {}
    for _, p in pairs(prs[key(rec.owner, rec.name)] or {}) do
        if state == 'all' or state == p.state then list[#list + 1] = copy(p) end
    end
    table.sort(list, function(a, b) return a.number > b.number end)
    return list
end

function g_exports.pr_get(rec, num)
    local p = get(rec, num)
    if not p then return nil, 'no such pull request', 404 end
    if p.pending then
        return locked(function() return reconcile(rec, get(rec, num)) end)
    end
    return copy(p)
end

function g_exports.pr_snapshot(rec, p)
    if p.state == 'merged' and p.base_oid and p.head_oid then
        return { base_oid = p.base_oid, head_oid = p.head_oid }
    end
    return snapshot(rec, p)
end

function g_exports.pr_create(rec, user, body)
    return locked(function()
        if not auth_can_write(rec, user) then return nil, 'repository write access required', 403 end
        if not text_ok(body.title, 200, true) or not text_ok(body.body or '', 65536) then
            return nil, 'title must be 1 to 200 bytes; body at most 65536 bytes', 400
        end
        if body.base == body.head then return nil, 'source and target must differ', 400 end
        local ends, err, status = snapshot(rec, body)
        if not ends then return nil, err, status end
        local common = run(rec, { 'merge-base', ends.base_oid, ends.head_oid })
        if not common.ok then return nil, 'branches have no common ancestor', 409 end
        local included = run(rec, { 'merge-base', '--is-ancestor', ends.head_oid, ends.base_oid })
        if included.ok then return nil, 'source has no new commits', 409 end
        if included.exit_code ~= 1 then return nil, 'could not compare branches', 500 end
        local top = 0
        for _, p in pairs(prs[key(rec.owner, rec.name)] or {}) do
            top = math.max(top, p.number)
            if p.state == 'open' and p.base == body.base and p.head == body.head then
                return nil, 'an open pull request already uses these branches', 409
            end
        end
        if top >= 2147483647 then return nil, 'pull request number limit reached', 409 end
        if not auth_can_write(rec, user) then return nil, 'repository write access required', 403 end
        return put(rec, { number = top + 1, title = body.title, body = body.body or '',
            base = body.base, head = body.head, author = user.username, state = 'open',
            created_at = os.time(), updated_at = os.time(), comments = {}, reviews = {} })
    end)
end

function g_exports.pr_update(rec, num, user, body)
    return locked(function()
        local old = get(rec, num)
        if not old then return nil, 'no such pull request', 404 end
        if old.pending then return nil, 'merge reconciliation required; refresh', 409 end
        if old.author ~= user.username and not auth_can_manage(rec, user) then
            return nil, 'author or repository administrator required', 403
        end
        if old.state == 'merged' then return nil, 'merged pull requests cannot be changed', 409 end
        if body.state and body.state ~= 'open' and body.state ~= 'closed' then
            return nil, 'state must be open or closed', 400
        end
        if body.title ~= nil and not text_ok(body.title, 200, true) or
           body.body ~= nil and not text_ok(body.body, 65536) then return nil, 'invalid title or body', 400 end
        if body.state == 'open' and old.state == 'closed' then
            local ends, err, status = snapshot(rec, old)
            if not ends then return nil, err, status end
            for _, other in pairs(prs[key(rec.owner, rec.name)] or {}) do
                if other.state == 'open' and other.base == old.base and other.head == old.head then
                    return nil, 'an open pull request already uses these branches', 409
                end
            end
        end
        local p = copy(old)
        for _, field in ipairs({ 'state', 'title', 'body' }) do
            if body[field] ~= nil then p[field] = body[field] end
        end
        p.updated_at = os.time()
        return put(rec, p)
    end)
end

function g_exports.pr_comment(rec, num, user, body)
    return locked(function()
        local old = get(rec, num)
        if not old then return nil, 'no such pull request', 404 end
        if old.pending then return nil, 'merge reconciliation required; refresh', 409 end
        if not text_ok(body, 8192, true) then return nil, 'comment must be 1 to 8192 bytes', 400 end
        if #old.comments >= 1000 then return nil, 'comment limit reached', 400 end
        local p = copy(old)
        p.comments[#p.comments + 1] = { author = user.username, body = body, created_at = os.time() }
        p.updated_at = os.time()
        return put(rec, p)
    end)
end

local function approve(rec, p, user, ends)
    local included = run(rec, { 'merge-base', '--is-ancestor', ends.head_oid, ends.base_oid })
    if included.ok then return nil, 'source has no new commits', 409 end
    if included.exit_code ~= 1 then return nil, 'could not compare branches', 500 end
    -- git-merge-tree --write-tree needs Git 2.38; the rest of the host retains
    -- its older minimum. Report unsupported binaries separately from conflicts.
    local version = git_version_cached() or ''
    local major, minor = version:match('^(%d+)%.(%d+)')
    if not major or tonumber(major) < 2 or tonumber(major) == 2 and tonumber(minor) < 38 then
        return nil, 'automatic merge requires Git 2.38 or newer', 503
    end
    local r = run(rec, { 'merge-tree', '--write-tree', ends.base_oid, ends.head_oid })
    if not r.ok then
        if r.exit_code == 1 then return nil, 'merge conflict; resolve on source branch and request review again', 409 end
        return nil, 'could not calculate merge', 500
    end
    local tree = util_str_trim(r.stdout or '')
    if not oid(tree) then return nil, 'invalid merge tree result', 500 end
    local identity = { GIT_AUTHOR_NAME = user.username, GIT_COMMITTER_NAME = user.username,
        GIT_AUTHOR_EMAIL = user.username .. '@gitloom.local', GIT_COMMITTER_EMAIL = user.username .. '@gitloom.local' }
    local commit = run(rec, { 'commit-tree', tree, '-p', ends.base_oid, '-p', ends.head_oid,
        '-m', 'Merge pull request #' .. p.number .. ': ' .. p.title }, { env = identity })
    local merged = util_str_trim(commit.stdout or '')
    if not commit.ok or not oid(merged) then return nil, 'could not create merge commit', 500 end
    if not auth_can_manage(rec, user) then return nil, 'review permission was revoked', 403 end
    p.pending = { oid = merged, actor = user.username, at = os.time(),
        base_oid = ends.base_oid, head_oid = ends.head_oid }
    p.reviews[#p.reviews].state = 'merging'
    local saved, err, status = put(rec, p)
    if not saved then return nil, err, status end
    -- The source and target must still be exactly what the reviewer saw.
    -- The private marker is created in the SAME transaction as the target.
    local commands = 'start\noption no-deref\nverify refs/heads/' .. p.head .. ' ' .. ends.head_oid ..
        '\nupdate refs/heads/' .. p.base .. ' ' .. merged .. ' ' .. ends.base_oid ..
        '\ncreate ' .. marker(p) .. ' ' .. merged .. '\nprepare\ncommit\n'
    local input = proc_tmp_path('pr-refs')
    local wrote = util_file_write(input, commands)
    if not wrote then return nil, 'could not stage ref transaction; refresh to reconcile', 500 end
    -- Recheck after the persistence RPC as it may have yielded to a revocation.
    if not auth_can_manage(rec, user) then
        proc_tmp_release(input)
        reconcile(rec, p)
        return nil, 'review permission was revoked', 403
    end
    local updated = run(rec, { 'update-ref', '--stdin' }, { stdin_file = input })
    proc_tmp_release(input)
    local result, why, code = reconcile(rec, p)
    if not result then return nil, why, code end
    if result.state ~= 'merged' then
        return nil, updated.exit_code and 'branches changed during review; refresh and review again' or
            'merge could not complete; refresh and retry', updated.exit_code and 409 or 500
    end
    repo_touch_push(rec)
    return result
end

function g_exports.pr_review(rec, num, user, body)
    return locked(function()
        local old = get(rec, num)
        if not old then return nil, 'no such pull request', 404 end
        if old.pending then return nil, 'merge reconciliation required; refresh', 409 end
        if old.state ~= 'open' then return nil, 'pull request is not open', 409 end
        if not auth_can_manage(rec, user) then return nil, 'repository administrator review required', 403 end
        if old.author == user.username then return nil, 'authors cannot approve their own pull requests', 403 end
        if body.state ~= 'approve' and body.state ~= 'request_changes' then return nil, 'invalid review state', 400 end
        if not text_ok(body.body or '', 8192, body.state == 'request_changes') then return nil, 'invalid review body', 400 end
        if #old.reviews >= 1000 then return nil, 'review limit reached', 400 end
        if not oid(body.head_oid) or not oid(body.base_oid) then return nil, 'reviewed head_oid and base_oid are required', 400 end
        local ends, err, status = snapshot(rec, old)
        if not ends then return nil, err, status end
        if ends.head_oid ~= body.head_oid or ends.base_oid ~= body.base_oid then
            return nil, 'branches changed during review; refresh and review again', 409
        end
        local p = copy(old)
        p.reviews[#p.reviews + 1] = { author = user.username, state = body.state, body = body.body or '',
            head_oid = ends.head_oid, base_oid = ends.base_oid, created_at = os.time() }
        p.updated_at = os.time()
        if body.state == 'approve' then return approve(rec, p, user, ends) end
        return put(rec, p)
    end)
end

-- Hold the same lock across directory/index changes and PR persistence: store
-- operations can yield, so a check before a rename alone does not exclude merges.
function g_exports.pr_repo_change(owner, name, new_name, action)
    return locked(function()
        if not prs then return nil, 'pull request store unavailable', 503 end
        local from = key(owner, name)
        local to = new_name and key(owner, new_name)
        for _, p in pairs(prs[from] or {}) do
            if p.pending then return nil, 'merge reconciliation required; refresh the pull request', 409 end
        end
        if to and to ~= from and prs[to] then return nil, 'destination has pull requests', 409 end
        local result, err, status = action()
        if not result then return nil, err, status end
        if from == to or not prs[from] then return result end
        local map = copy(prs)
        if to then map[to] = map[from] end
        map[from] = nil
        local ok, why = persist(map)
        if not ok then
            return nil, 'repository changed, but pull requests could not be updated: ' .. tostring(why), 500
        end
        return result
    end)
end
