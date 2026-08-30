-- app/util.lua — path, file and string helpers.
--
-- Exports: SEP, IS_WIN,
--          str_trim, str_split, str_starts, str_ends,
--          path_join, path_native, path_is_abs,
--          file_read, file_write, file_write_atomic, file_size,
--          file_exists, file_remove,
--          dir_make, dir_walk,
--          json_array, json_fix_arrays,
--          rand_hex, now_ms

local xutils = require('xutils')
local xfs    = dofile('scripts/core/share/xfs.lua')

SEP    = package.config:sub(1, 1)
IS_WIN = (SEP == '\\')

-- ---------------------------------------------------------------------------
-- Strings
-- ---------------------------------------------------------------------------

function str_trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Split on a Lua pattern class of separators. Empty fields are dropped, which
-- is what every caller here wants (URL segments, comma lists).
function str_split(s, sep_class)
    local out = {}
    for part in tostring(s or ''):gmatch('[^' .. (sep_class or '/') .. ']+') do
        out[#out + 1] = part
    end
    return out
end

function str_starts(s, prefix)
    return tostring(s):sub(1, #prefix) == prefix
end

function str_ends(s, suffix)
    return suffix == '' or tostring(s):sub(-#suffix) == suffix
end

-- ---------------------------------------------------------------------------
-- Paths
--
-- Internally every path uses '/' — including on Windows, where the CRT accepts
-- it everywhere. path_native() converts at the one boundary that does not:
-- cmd.exe's `cd /d`. (xproc already does that conversion for spec.cwd; this is
-- here for messages and for anything else that has to look native.)
-- ---------------------------------------------------------------------------

function path_join(...)
    local parts = {}
    for _, p in ipairs({ ... }) do
        p = tostring(p or ''):gsub('\\', '/'):gsub('/+$', '')
        if p ~= '' then parts[#parts + 1] = p end
    end
    return (table.concat(parts, '/'):gsub('//+', '/'))
end

function path_native(p)
    if IS_WIN then return (tostring(p):gsub('/', '\\')) end
    return tostring(p)
end

function path_is_abs(p)
    p = tostring(p or '')
    if IS_WIN then
        return p:match('^%a:[/\\]') ~= nil or p:match('^[/\\][/\\]') ~= nil
    end
    return p:sub(1, 1) == '/'
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

function file_read(path)
    return xfs.read_file(path)
end

function file_write(path, data)
    return xfs.write_file(path, data)
end

-- Replace a file's contents so that a crash can never leave it missing or
-- half-written. Every reader either sees the old file or the new one.
--
-- The naive "write .tmp, delete the target, rename .tmp into place" has a
-- window between the delete and the rename where the file does not exist at
-- all — and for the account and repository indexes that window means losing
-- every account or every repository record, not losing one write.
--
-- POSIX rename(2) is atomic and replaces the destination, so there is nothing
-- to delete. Windows os.rename refuses to overwrite, which is why the delete
-- was there; instead the current file is moved aside first and only removed
-- once the new one is in place, and a failed swap puts it back.
function file_write_atomic(path, data)
    local tmp = path .. '.tmp'
    local ok, err = file_write(tmp, data)
    if not ok then return nil, 'write failed: ' .. tostring(err) end

    if not IS_WIN then
        local rok, rerr = os.rename(tmp, path)
        if not rok then
            file_remove(tmp)
            return nil, 'rename failed: ' .. tostring(rerr)
        end
        return true
    end

    local bak = path .. '.bak'
    local had_old = file_exists(path)
    if had_old then
        file_remove(bak)                       -- debris from an earlier crash
        local mok, merr = os.rename(path, bak)
        if not mok then
            file_remove(tmp)
            return nil, 'could not move the old file aside: ' .. tostring(merr)
        end
    end

    local rok, rerr = os.rename(tmp, path)
    if not rok then
        -- Put the original back rather than leaving nothing behind.
        if had_old then os.rename(bak, path) end
        file_remove(tmp)
        return nil, 'rename failed: ' .. tostring(rerr)
    end

    if had_old then file_remove(bak) end
    return true
end

-- Size in bytes, or nil when the file cannot be opened. Used to fill in
-- Content-Length before handing a packfile to send_file_response.
function file_size(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local n = f:seek('end')
    f:close()
    return n
end

function file_exists(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    f:close()
    return true
end

function file_remove(path)
    if not path then return false end
    local ok = pcall(os.remove, path)
    return ok
end

-- Create a directory and any missing parents.
--
-- There is no mkdir binding, so this costs a process either way. Which one
-- matters: xfs.mkdirp runs os.execute on the CALLING thread, and two of the
-- callers here (repo_create, auth_save) run on a request coroutine on the event
-- loop — forking a shell there stalls every other connection for the duration,
-- which is precisely what the worker pool exists to avoid.
--
-- So: inside a coroutine, go through the pool and yield; on the main state at
-- boot, where yielding is impossible and nothing is being served yet, call
-- xfs.mkdirp directly. coroutine.isyieldable() is the exact test for that,
-- and it keeps this one function correct in both contexts.
function dir_make(path)
    if coroutine.isyieldable() then
        local argv = IS_WIN
            and { 'cmd', '/c', 'if', 'not', 'exist', path_native(path),
                  'mkdir', path_native(path) }
            or  { 'mkdir', '-p', path }
        local r = proc_exec({ argv = argv, capture_stderr = true })
        if not r.ok then
            return nil, 'mkdir failed: ' .. str_trim(r.stderr or tostring(r.err))
        end
        return true
    end
    xfs.mkdirp(path_native(path))
    return true
end

-- Walk a directory tree. Returns xutils.scan_dir's array, or an empty table
-- when the directory is missing.
--
-- NOTE: scan_dir RECURSES, with no depth limit and no way to ask for one. Never
-- point it at repos/ — a bare repository holds one file per loose object, so
-- "list the repositories" would enumerate the entire object store. Repository
-- listing goes through the on-disk index in repo.lua instead; this is for
-- small trees (static assets, templates).
function dir_walk(path)
    local items = xutils.scan_dir(path)
    return items or {}
end

-- ---------------------------------------------------------------------------
-- JSON array typing
--
-- xutils.json_pack decides array-vs-object by inspecting the table: all keys
-- integer, >= 1, and contiguous — AND non-empty. An empty table therefore
-- always comes out as `{}`, so a field like `refs` changes JSON type depending
-- on whether the repository has commits, and every client has to handle both.
--
-- There is no metatable or sentinel the C packer honours, so the type cannot be
-- expressed at pack time. Instead json_array() substitutes a placeholder string
-- for an empty table and json_fix_arrays() turns that placeholder back into []
-- after packing.
--
-- The placeholder carries a random suffix generated once at boot and never sent
-- anywhere, so a repository description cannot collide with it — a fixed
-- marker string could be typed by a user and would then be rewritten into a
-- bare [] in the middle of their text. Alphanumerics only, so it needs no
-- escaping either as a Lua pattern or in JSON.
--
-- The real fix is array support in the runtime's packer; this goes away then.
-- ---------------------------------------------------------------------------

local empty_array_token = nil

local function array_token()
    if not empty_array_token then
        empty_array_token = 'ZZgitloomEmptyArrayZZ' .. rand_hex(8)
    end
    return empty_array_token
end

-- Mark a value as "serialise me as a JSON array". Pass every list-shaped field
-- through this on its way into a response.
function json_array(t)
    if type(t) ~= 'table' then return t end
    if next(t) == nil then return array_token() end
    return t
end

-- Apply after json_pack. Cheap when nothing was marked: one find, no rewrite.
function json_fix_arrays(json)
    if not empty_array_token or type(json) ~= 'string' then return json end
    local quoted = '"' .. empty_array_token .. '"'
    if not json:find(quoted, 1, true) then return json end
    return (json:gsub(quoted, '[]'))
end

-- ---------------------------------------------------------------------------
-- Misc
-- ---------------------------------------------------------------------------

-- Hex string from the OS CSPRNG. Used for session tokens and scratch filenames,
-- so it must not fall back to a predictable source silently — a failure raises.
function rand_hex(nbytes)
    nbytes = nbytes or 16
    local raw = xnet.random_bytes(nbytes)
    if not raw or #raw ~= nbytes then
        error('rand_hex: xnet.random_bytes failed', 2)
    end
    return xutils.hex_encode(raw)
end

function now_ms()
    return math.floor(os.time() * 1000)
end
