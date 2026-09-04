-- app/repo.lua — the repository model: naming, on-disk layout, and the index.
--
-- Exports: repo_root, repo_name_ok, repo_parse_url, repo_dir, repo_dir_of,
--          repo_exists, repo_exists_of, repo_get, repo_list, repo_create,
--          repo_update, repo_delete, repo_sync_head, repo_index_load, repo_key
--
-- ON-DISK LAYOUT
--   <REPO_ROOT>/<owner>/<name>.git     one bare repository per directory
--
-- WHERE THE INDEX LIVES is app/store.lua's business, not this file's: a JSON
-- file next to the repositories, or a table in MySQL. What is here is the
-- in-memory map and what it means; `index` below IS the map store.lua handed
-- over, so a record changed in place needs only a store_repo_put to persist.
--
-- WHY AN INDEX FILE
-- Listing repositories by walking REPO_ROOT is not viable: xutils.scan_dir
-- recurses with no depth limit, so "list the repositories" would enumerate every
-- loose object in every repository. The index is the authority for what exists
-- and carries the metadata the filesystem cannot (description, private flag,
-- creation time, default branch). It is rewritten atomically on create/delete.
--
-- The index is the authority for LISTING only. Every request that touches a
-- repository still checks the directory, so an index that has drifted out of
-- sync produces a 404 rather than a corrupt operation.


-- Segment charset. Deliberately narrow, and it is a security boundary rather
-- than a style choice — three separate ones:
--   * no '/', no '..' → the name cannot escape REPO_ROOT
--   * no '%'          → cmd.exe expands %VAR% even inside double quotes and
--                       `cmd /c` has no escape for it, so a '%' in a name would
--                       be interpreted by the shell xproc runs through
--   * no '-' leading  → a name starting with '-' would be read by git as an
--                       option rather than a path
local NAME_PATTERN = '^[A-Za-z0-9_][A-Za-z0-9._-]*$'
local MAX_NAME     = 100

-- A description is free text, and until the store had columns nothing bounded
-- it: the JSON index simply grew, and every boot read the lot back. It is a
-- TEXT column now, so an unbounded one is the difference between a 400 that
-- says what is wrong and a 500 out of the database. 1 KiB is far more than a
-- one-line summary needs and far less than either store minds.
local MAX_DESCRIPTION = 1024

local index = nil     -- { ["owner/name"] = { owner, name, description, ... } }

-- ---------------------------------------------------------------------------
-- Naming
-- ---------------------------------------------------------------------------

function g_exports.repo_root()
    return cfg_get('REPO_ROOT', 'repos')
end

-- Windows device names. These are reserved at every path level and with any
-- extension, so `CON.git` is still the console device — `git init` fails on it
-- with "cannot mkdir ... Invalid argument", which reached the client as a 500
-- carrying the server's absolute filesystem path. Rejecting them up front turns
-- that into a clear 400 and keeps the path out of the response.
--
-- Enforced on every platform, not only Windows: a repository created on a Linux
-- server must remain checkoutable and servable if the instance is ever moved.
local WINDOWS_DEVICES = {
    con = true, prn = true, aux = true, nul = true,
}
for i = 1, 9 do
    WINDOWS_DEVICES['com' .. i] = true
    WINDOWS_DEVICES['lpt' .. i] = true
end

-- Is this a usable owner or repository segment?
function g_exports.repo_name_ok(s)
    s = tostring(s or '')
    if s == '' or #s > MAX_NAME then return false end
    if s:match(NAME_PATTERN) == nil then return false end
    if s == '.' or s == '..' then return false end
    -- '.git' would collide with the suffix we append; '.lock' is git's own.
    if s:lower() == '.git' or util_str_ends(s:lower(), '.lock') then return false end

    -- A trailing dot or space is silently stripped by the Windows filesystem,
    -- so `demo.` and `demo` would be one directory but two index entries — the
    -- index would claim two repositories where only one exists on disk.
    if s:match('[%.%s]$') then return false end

    -- Reserved device name, with or without an extension: CON, CON.git, com1.x
    local stem = s:match('^([^%.]+)') or s
    if WINDOWS_DEVICES[stem:lower()] then return false end

    return true
end

-- Split a request path into (owner, name, rest).
--
--   /alice/site.git/info/refs  ->  'alice', 'site', '/info/refs'
--   /alice/site/info/refs      ->  'alice', 'site', '/info/refs'
--   /site.git/git-upload-pack  ->  <DEFAULT_OWNER>, 'site', '/git-upload-pack'
--
-- Returns nil plus a reason when the path names nothing valid. `rest` is '' when
-- the path is exactly the repository.
function g_exports.repo_parse_url(path)
    local segs = util_str_split(tostring(path or ''), '/')
    if #segs == 0 then return nil, 'empty path' end

    -- Find the segment that ends the repository name. With an explicit .git
    -- suffix that is unambiguous; without one we take the first two segments
    -- (owner/name), or the first when only one is left.
    local repo_at = nil
    for i, s in ipairs(segs) do
        if util_str_ends(s, '.git') then repo_at = i; break end
    end
    if not repo_at then
        repo_at = math.min(2, #segs)
    end

    local owner, name
    if repo_at == 1 then
        owner = cfg_get('DEFAULT_OWNER', 'root')
        name  = segs[1]
    elseif repo_at == 2 then
        owner = segs[1]
        name  = segs[2]
    else
        return nil, 'repository path is at most owner/name'
    end

    name = name:gsub('%.git$', '')
    if not repo_name_ok(owner) then return nil, 'bad owner: ' .. tostring(owner) end
    if not repo_name_ok(name)  then return nil, 'bad repository: ' .. tostring(name) end

    local rest = ''
    for i = repo_at + 1, #segs do rest = rest .. '/' .. segs[i] end
    return owner, name, rest
end

-- Directory for an owner/name pair exactly as given. Callers that already hold
-- an index record must use repo_dir_of instead: the record carries the casing
-- the directory was actually created with, and a URL may differ from it.
function g_exports.repo_dir(owner, name)
    return util_path_join(repo_root(), owner, name .. '.git')
end

-- Directory of an existing repository, from its index record.
function g_exports.repo_dir_of(rec)
    return util_path_join(repo_root(), rec.owner, rec.name .. '.git')
end

-- Does this record's directory exist on disk?
function g_exports.repo_exists_of(rec)
    local dir = repo_dir_of(rec)
    return util_file_exists(util_path_join(dir, 'HEAD'))
       and util_file_exists(util_path_join(dir, 'config'))
end

-- A directory is a repository when it has the three things every bare repo has.
-- Cheaper and stricter than shelling out to `git rev-parse`, and it runs on the
-- request path so it must not block.
function g_exports.repo_exists(owner, name)
    local dir = repo_dir(owner, name)
    return util_file_exists(util_path_join(dir, 'HEAD'))
       and util_file_exists(util_path_join(dir, 'config'))
end

-- ---------------------------------------------------------------------------
-- Index
-- ---------------------------------------------------------------------------

-- Index keys are CASE-FOLDED, the directory keeps the name as typed.
--
-- Windows and macOS filesystems are case-insensitive, so `Demo.git` and
-- `demo.git` are one directory. A case-sensitive index would happily hold two
-- records pointing at it, and on Linux the same instance would then have two
-- real repositories that stop working the moment the data is moved to a Windows
-- host. Folding the key makes "already exists" mean the same thing everywhere.
--
-- The consequence for lookups: a record found by a case-folded key may have
-- different casing from the URL that found it, so the directory must be derived
-- from the RECORD (repo_dir_of) and never from the request path.
function g_exports.repo_key(owner, name)
    return owner:lower() .. '/' .. name:lower()
end

-- Read the whole index into memory. COROUTINE-ONLY under MySQL, where it is a
-- query; harmless from anywhere under the file backend. main.lua loads it from
-- boot_async for exactly that reason.
--
-- Returns the map, or nil plus a message. On failure `index` is deliberately
-- left nil rather than set to {}: an empty index does not mean "no
-- repositories", it means the store did not answer, and caching that would make
-- every repository vanish and let repo_create overwrite one that exists.
function g_exports.repo_index_load()
    local map, err = store_repos_load()
    if not map then
        cfg_log_error('repository index unavailable: %s', tostring(err))
        return nil, err
    end
    index = map
    return index
end

-- The index has to be there before a lookup can mean anything. Returns true, or
-- false once the failure has been logged by repo_index_load.
local function have_index()
    if index then return true end
    return repo_index_load() ~= nil
end

function g_exports.repo_get(owner, name)
    if not have_index() then return nil end
    return index[repo_key(owner, name)]
end

-- Every repository, optionally filtered by owner. Sorted, so the listing is
-- stable between calls.
function g_exports.repo_list(owner)
    if not have_index() then return {} end
    local out = {}
    for _, r in pairs(index) do
        if not owner or r.owner == owner then out[#out + 1] = r end
    end
    table.sort(out, function(a, b)
        if a.owner ~= b.owner then return a.owner < b.owner end
        return a.name < b.name
    end)
    return out
end

-- ---------------------------------------------------------------------------
-- Create / delete
--
-- Both are coroutine-only: they shell out to git through the xproc pool.
-- ---------------------------------------------------------------------------

-- opts = { description, private, default_branch }
function g_exports.repo_create(owner, name, opts)
    opts = opts or {}
    if not repo_name_ok(owner) then return nil, 'bad owner name' end
    if not repo_name_ok(name)  then return nil, 'bad repository name' end
    if not have_index() then return nil, 'the repository index is unavailable' end
    if index[repo_key(owner, name)] or repo_exists(owner, name) then
        return nil, 'repository already exists'
    end

    local dir = repo_dir(owner, name)
    util_dir_make(util_path_join(repo_root(), owner))

    local branch = opts.default_branch or cfg_get('DEFAULT_BRANCH', 'main')
    if not repo_name_ok(branch) then return nil, 'bad default branch name' end

    local description = tostring(opts.description or '')
    if #description > MAX_DESCRIPTION then
        return nil, string.format('description must be at most %d bytes',
            MAX_DESCRIPTION)
    end

    local r = git_exec({ 'init', '--bare', '-q',
                         '--initial-branch=' .. branch, dir })
    if not r.ok then
        return nil, 'git init failed: ' .. tostring(r.err) .. ' ' .. util_str_trim(r.stderr)
    end

    -- Without this a push over HTTP is refused by git with "cannot lock ref"
    -- style failures on a repo that has no worktree; it is what `git init
    -- --bare` sets for local use but not for the http path in every version.
    git_exec({ 'config', 'http.receivepack', 'true' }, { cwd = dir })

    local rec = {
        owner = owner,
        name = name,
        description = description,
        private = opts.private and true or false,
        default_branch = branch,
        created_at = os.time(),
    }
    index[repo_key(owner, name)] = rec
    local sok, serr = store_repo_put(rec)
    if not sok then
        -- The index is what makes a repository findable, so a repository that
        -- is not in it does not exist as far as every other code path is
        -- concerned. Roll the directory back and fail, rather than returning
        -- 201 for something that will have vanished by the next restart.
        index[repo_key(owner, name)] = nil
        local dok = proc_exec(util_is_windows
            and { argv = { 'cmd', '/c', 'rmdir', '/s', '/q', util_path_native(dir) } }
            or  { argv = { 'rm', '-rf', dir } })
        cfg_log_error('index save failed for %s/%s (%s); rolled the directory back (%s)',
            owner, name, tostring(serr), dok.ok and 'ok' or 'FAILED — orphan left on disk')
        return nil, 'could not persist the repository index: ' .. tostring(serr)
    end
    cfg_log_system('created repository %s/%s at %s', owner, name, dir)
    return rec
end

-- Update mutable repository metadata without changing its on-disk git data.
-- opts may contain description and/or private. The record is changed in memory
-- first so every caller sees one coherent value, then persisted; a failed
-- store rolls the record back before returning the error.
function g_exports.repo_update(owner, name, opts)
    if not repo_name_ok(owner) or not repo_name_ok(name) then
        return nil, 'bad repository name', 400
    end
    if not have_index() then return nil, 'the repository index is unavailable', 500 end
    opts = opts or {}
    if type(opts) ~= 'table' then return nil, 'expected a JSON object body', 400 end

    local has_description = opts.description ~= nil
    local has_private = opts.private ~= nil
    if not has_description and not has_private then
        return nil, 'no repository fields to update', 400
    end
    if has_description and type(opts.description) ~= 'string' then
        return nil, 'description must be a string', 400
    end
    if has_description and #opts.description > MAX_DESCRIPTION then
        return nil, string.format('description must be at most %d bytes', MAX_DESCRIPTION), 400
    end
    if has_private and type(opts.private) ~= 'boolean' then
        return nil, 'private must be a boolean', 400
    end

    local rec = index[repo_key(owner, name)]
    if not rec or not repo_exists_of(rec) then return nil, 'no such repository', 404 end

    local old_description, old_private = rec.description, rec.private
    if has_description then rec.description = opts.description end
    if has_private then rec.private = opts.private end
    local sok, serr = store_repo_put(rec)
    if not sok then
        rec.description, rec.private = old_description, old_private
        return nil, 'could not persist repository changes: ' .. tostring(serr), 500
    end
    return rec
end

-- Point HEAD at a branch that actually exists, after a push.
--
-- A bare repository is created with HEAD -> refs/heads/<DEFAULT_BRANCH>, but a
-- push does not move HEAD. So a client whose local branch is called something
-- else -- `master` against our `main` default is the common case -- leaves the
-- repository with a HEAD naming a branch that was never created. git clone then
-- succeeds but checks out nothing, and every browsing endpoint that defaults to
-- the repository's own default branch answers 404 on a repository that is
-- visibly full of commits.
--
-- Called after a successful receive-pack. The common case costs one rev-parse:
-- if HEAD resolves, there is nothing to do.
--
-- Coroutine-only.
function g_exports.repo_sync_head(rec)
    local dir = repo_dir_of(rec)

    -- Does HEAD point at something that exists?
    local r = git_exec({ 'rev-parse', '--verify', '--quiet', 'HEAD' }, { cwd = dir })
    if r.ok and util_str_trim(r.stdout or '') ~= '' then return false end

    local branches = browse_refs(dir, 'branches')
    if not branches or #branches == 0 then return false end   -- still empty

    -- Prefer what the record says, then the conventional names, then whatever
    -- exists -- sorted, so the choice is deterministic rather than depending on
    -- ref enumeration order.
    local have = {}
    for _, b in ipairs(branches) do have[b.name] = true end

    local pick
    for _, want in ipairs({ rec.default_branch, 'main', 'master' }) do
        if want and have[want] then pick = want; break end
    end
    pick = pick or branches[1].name

    r = git_exec({ 'symbolic-ref', 'HEAD', 'refs/heads/' .. pick }, { cwd = dir })
    if not r.ok then
        cfg_log_warn('could not point HEAD at %s in %s/%s: %s',
            pick, rec.owner, rec.name, util_str_trim(r.stderr or ''))
        return false
    end

    if rec.default_branch ~= pick then
        rec.default_branch = pick
        local sok, serr = store_repo_put(rec)
        if not sok then
            cfg_log_warn('HEAD moved to %s but the index was not saved: %s',
                pick, tostring(serr))
        end
    end
    cfg_log_info('%s/%s: HEAD now points at %s', rec.owner, rec.name, pick)
    return true
end

-- Remove a repository from the index and from disk. The on-disk removal is a
-- recursive delete through the shell — the one operation here with no undo, so
-- it re-validates the names right before building the command rather than
-- trusting that whoever called us did.
function g_exports.repo_delete(owner, name)
    if not repo_name_ok(owner) or not repo_name_ok(name) then
        return nil, 'bad repository name'
    end
    if not have_index() then return nil, 'the repository index is unavailable' end
    if not index[repo_key(owner, name)] and not repo_exists(owner, name) then
        return nil, 'no such repository'
    end

    local dir = repo_dir(owner, name)
    local r
    if util_is_windows then
        r = proc_exec({ argv = { 'cmd', '/c', 'rmdir', '/s', '/q', util_path_native(dir) } })
    else
        r = proc_exec({ argv = { 'rm', '-rf', dir } })
    end
    if not r.ok then
        return nil, 'delete failed: ' .. tostring(r.err) .. ' ' .. util_str_trim(r.stderr or '')
    end

    index[repo_key(owner, name)] = nil
    local sok, serr = store_repo_delete(owner, name)
    if not sok then
        -- The directory is already gone, so the in-memory index is now the
        -- truthful one and re-adding the record would be a lie. Report the
        -- failure instead of swallowing it: on restart the stale index comes
        -- back and lists a repository that is not there.
        cfg_log_error('repository %s/%s was deleted from disk but the index save failed: %s',
            owner, name, tostring(serr))
        return nil, 'repository deleted, but the index could not be saved: ' .. tostring(serr)
    end
    cfg_log_system('deleted repository %s/%s', owner, name)
    return true
end
