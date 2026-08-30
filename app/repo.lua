-- app/repo.lua — the repository model: naming, on-disk layout, and the index.
--
-- Exports: repo_root, repo_name_ok, repo_parse_url, repo_dir, repo_dir_of,
--          repo_exists, repo_exists_of, repo_get, repo_list, repo_create,
--          repo_delete, repo_sync_head, repo_index_load, repo_index_save
--
-- ON-DISK LAYOUT
--   <REPO_ROOT>/<owner>/<name>.git     one bare repository per directory
--   <REPO_ROOT>/index.json             the repository index (see below)
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

local xutils = require('xutils')

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

local index = nil     -- { ["owner/name"] = { owner, name, description, ... } }

local function index_path()
    return path_join(repo_root(), 'index.json')
end

-- ---------------------------------------------------------------------------
-- Naming
-- ---------------------------------------------------------------------------

function repo_root()
    return cfg('REPO_ROOT', 'repos')
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
function repo_name_ok(s)
    s = tostring(s or '')
    if s == '' or #s > MAX_NAME then return false end
    if s:match(NAME_PATTERN) == nil then return false end
    if s == '.' or s == '..' then return false end
    -- '.git' would collide with the suffix we append; '.lock' is git's own.
    if s:lower() == '.git' or str_ends(s:lower(), '.lock') then return false end

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
function repo_parse_url(path)
    local segs = str_split(tostring(path or ''), '/')
    if #segs == 0 then return nil, 'empty path' end

    -- Find the segment that ends the repository name. With an explicit .git
    -- suffix that is unambiguous; without one we take the first two segments
    -- (owner/name), or the first when only one is left.
    local repo_at = nil
    for i, s in ipairs(segs) do
        if str_ends(s, '.git') then repo_at = i; break end
    end
    if not repo_at then
        repo_at = math.min(2, #segs)
    end

    local owner, name
    if repo_at == 1 then
        owner = cfg('DEFAULT_OWNER', 'root')
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
function repo_dir(owner, name)
    return path_join(repo_root(), owner, name .. '.git')
end

-- Directory of an existing repository, from its index record.
function repo_dir_of(rec)
    return path_join(repo_root(), rec.owner, rec.name .. '.git')
end

-- Does this record's directory exist on disk?
function repo_exists_of(rec)
    local dir = repo_dir_of(rec)
    return file_exists(path_join(dir, 'HEAD'))
       and file_exists(path_join(dir, 'config'))
end

-- A directory is a repository when it has the three things every bare repo has.
-- Cheaper and stricter than shelling out to `git rev-parse`, and it runs on the
-- request path so it must not block.
function repo_exists(owner, name)
    local dir = repo_dir(owner, name)
    return file_exists(path_join(dir, 'HEAD'))
       and file_exists(path_join(dir, 'config'))
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
local function key(owner, name)
    return owner:lower() .. '/' .. name:lower()
end

function repo_index_load()
    index = {}
    local raw = file_read(index_path())
    if not raw or raw == '' then return index end
    local parsed = xutils.json_unpack(raw)
    if type(parsed) ~= 'table' or type(parsed.repos) ~= 'table' then
        log_warn('repository index at %s is unreadable; starting empty', index_path())
        return index
    end
    for _, r in ipairs(parsed.repos) do
        if type(r) == 'table' and repo_name_ok(r.owner) and repo_name_ok(r.name) then
            index[key(r.owner, r.name)] = r
        end
    end
    return index
end

-- Rewrite the index through file_write_atomic, so a crash can never leave the
-- listing without an index — see the note there on why the obvious
-- delete-then-rename is worse than no atomicity at all.
function repo_index_save()
    local list = {}
    for _, r in pairs(index or {}) do list[#list + 1] = r end
    table.sort(list, function(a, b)
        if a.owner ~= b.owner then return a.owner < b.owner end
        return a.name < b.name
    end)

    local json = xutils.json_pack({ version = 1, repos = list })
    if not json then
        -- json_pack returns nil (not an error) on invalid UTF-8 — a description
        -- pasted from a mis-decoded source can do it. Refusing here beats
        -- truncating the index to nothing.
        return nil, 'index serialisation failed (invalid UTF-8 in a field?)'
    end

    local ok, err = file_write_atomic(index_path(), json)
    if not ok then return nil, 'index save failed: ' .. tostring(err) end
    return true
end

function repo_get(owner, name)
    if not index then repo_index_load() end
    return index[key(owner, name)]
end

-- Every repository, optionally filtered by owner. Sorted, so the listing is
-- stable between calls.
function repo_list(owner)
    if not index then repo_index_load() end
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
function repo_create(owner, name, opts)
    opts = opts or {}
    if not repo_name_ok(owner) then return nil, 'bad owner name' end
    if not repo_name_ok(name)  then return nil, 'bad repository name' end
    if not index then repo_index_load() end
    if index[key(owner, name)] or repo_exists(owner, name) then
        return nil, 'repository already exists'
    end

    local dir = repo_dir(owner, name)
    dir_make(path_join(repo_root(), owner))

    local branch = opts.default_branch or cfg('DEFAULT_BRANCH', 'main')
    if not repo_name_ok(branch) then return nil, 'bad default branch name' end

    local r = git_exec({ 'init', '--bare', '-q',
                         '--initial-branch=' .. branch, dir })
    if not r.ok then
        return nil, 'git init failed: ' .. tostring(r.err) .. ' ' .. str_trim(r.stderr)
    end

    -- Without this a push over HTTP is refused by git with "cannot lock ref"
    -- style failures on a repo that has no worktree; it is what `git init
    -- --bare` sets for local use but not for the http path in every version.
    git_exec({ 'config', 'http.receivepack', 'true' }, { cwd = dir })

    local rec = {
        owner = owner,
        name = name,
        description = tostring(opts.description or ''),
        private = opts.private and true or false,
        default_branch = branch,
        created_at = os.time(),
    }
    index[key(owner, name)] = rec
    local sok, serr = repo_index_save()
    if not sok then
        -- The index is what makes a repository findable, so a repository that
        -- is not in it does not exist as far as every other code path is
        -- concerned. Roll the directory back and fail, rather than returning
        -- 201 for something that will have vanished by the next restart.
        index[key(owner, name)] = nil
        local dok = proc_exec(IS_WIN
            and { argv = { 'cmd', '/c', 'rmdir', '/s', '/q', path_native(dir) } }
            or  { argv = { 'rm', '-rf', dir } })
        log_error('index save failed for %s/%s (%s); rolled the directory back (%s)',
            owner, name, tostring(serr), dok.ok and 'ok' or 'FAILED — orphan left on disk')
        return nil, 'could not persist the repository index: ' .. tostring(serr)
    end
    log_system('created repository %s/%s at %s', owner, name, dir)
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
function repo_sync_head(rec)
    local dir = repo_dir_of(rec)

    -- Does HEAD point at something that exists?
    local r = git_exec({ 'rev-parse', '--verify', '--quiet', 'HEAD' }, { cwd = dir })
    if r.ok and str_trim(r.stdout or '') ~= '' then return false end

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
        log_warn('could not point HEAD at %s in %s/%s: %s',
            pick, rec.owner, rec.name, str_trim(r.stderr or ''))
        return false
    end

    if rec.default_branch ~= pick then
        rec.default_branch = pick
        local sok, serr = repo_index_save()
        if not sok then
            log_warn('HEAD moved to %s but the index was not saved: %s',
                pick, tostring(serr))
        end
    end
    log_info('%s/%s: HEAD now points at %s', rec.owner, rec.name, pick)
    return true
end

-- Remove a repository from the index and from disk. The on-disk removal is a
-- recursive delete through the shell — the one operation here with no undo, so
-- it re-validates the names right before building the command rather than
-- trusting that whoever called us did.
function repo_delete(owner, name)
    if not repo_name_ok(owner) or not repo_name_ok(name) then
        return nil, 'bad repository name'
    end
    if not index then repo_index_load() end
    if not index[key(owner, name)] and not repo_exists(owner, name) then
        return nil, 'no such repository'
    end

    local dir = repo_dir(owner, name)
    local r
    if IS_WIN then
        r = proc_exec({ argv = { 'cmd', '/c', 'rmdir', '/s', '/q', path_native(dir) } })
    else
        r = proc_exec({ argv = { 'rm', '-rf', dir } })
    end
    if not r.ok then
        return nil, 'delete failed: ' .. tostring(r.err) .. ' ' .. str_trim(r.stderr or '')
    end

    index[key(owner, name)] = nil
    local sok, serr = repo_index_save()
    if not sok then
        -- The directory is already gone, so the in-memory index is now the
        -- truthful one and re-adding the record would be a lie. Report the
        -- failure instead of swallowing it: on restart the stale index comes
        -- back and lists a repository that is not there.
        log_error('repository %s/%s was deleted from disk but the index save failed: %s',
            owner, name, tostring(serr))
        return nil, 'repository deleted, but the index could not be saved: ' .. tostring(serr)
    end
    log_system('deleted repository %s/%s', owner, name)
    return true
end
