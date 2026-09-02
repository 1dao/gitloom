-- app/browse.lua — reading a repository's contents.
--
-- Exports: browse_path_ok, browse_decode_path, browse_resolve,
--          browse_tree, browse_blob_info, browse_blob_file,
--          browse_log, browse_commit, browse_diff, browse_refs
--
-- Everything here answers "what is IN this repository", as opposed to repo.lua,
-- which answers "which repositories are there". All of it shells out; all of it
-- is coroutine-only.
--
-- THE SECURITY PROBLEM THIS MODULE EXISTS TO CONTAIN
-- A browsing endpoint takes two things straight from the URL — a ref and a path
-- — and puts them on a `git` command line. Both are hostile input:
--
--   * A ref beginning with '-' is read by git as an OPTION. `git log
--     --output=/etc/cron.d/x` is a file write; `--upload-pack=...` on the
--     fetching side is command execution. This is the whole class of bug behind
--     several real CVEs in git-hosting front ends.
--   * A path can climb out of the repository, or name something git treats
--     specially.
--
-- Two rules, applied without exception:
--
--   1. A ref is RESOLVED TO AN OBJECT ID once, by rev-parse, and only the
--      40-character hex id is passed to anything afterwards. A hex id cannot be
--      an option, cannot be a path, and cannot be ambiguous. Nothing downstream
--      of browse_resolve ever sees caller-supplied ref text.
--   2. Every command that takes a path uses `--` before it, and the path is
--      validated first anyway. Belt and braces, because the cost is nothing.
--
-- OUTPUT PARSING
-- Plumbing commands with -z where they support it. git quotes and escapes
-- unusual filenames in its human-readable output, so a name containing a
-- newline or a quote parses wrongly from line-based output — and a repository
-- can legitimately contain one.

local MAX_PATH_LEN = 4096
local MAX_LOG      = 200

-- ---------------------------------------------------------------------------
-- Input validation
-- ---------------------------------------------------------------------------

-- Percent-decode ONE path segment.
--
-- Deliberately not codec.uri_decode: that also turns '+' into a space, which is
-- form-encoding and wrong here. A '+' in a URL path is a literal '+', and a
-- repository may well contain a file called `c++.md`.
local function decode_segment(seg)
    return (tostring(seg):gsub('%%(%x%x)', function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Decode a whole '/'-joined path from the URL. Returns nil when it decodes to
-- something we will not touch.
function g_exports.browse_decode_path(raw)
    if raw == nil or raw == '' then return '' end
    local out = {}
    for seg in tostring(raw):gmatch('[^/]+') do
        out[#out + 1] = decode_segment(seg)
    end
    local p = table.concat(out, '/')
    if not browse_path_ok(p) then return nil, 'invalid path' end
    return p
end

-- Is this a path we are willing to hand to git?
--
-- Checked AFTER percent-decoding, which is the only order that works: '%2e%2e'
-- is '..' and a check done before decoding would wave it through.
function g_exports.browse_path_ok(p)
    p = tostring(p or '')
    if p == '' then return true end                       -- the tree root
    if #p > MAX_PATH_LEN then return false end
    if p:find('%z') then return false end                 -- NUL
    if p:sub(1, 1) == '/' then return false end           -- absolute
    if p:sub(1, 1) == '-' then return false end           -- reads as an option
    if p:find('\\', 1, true) then return false end        -- backslash is a name, not a separator
    for seg in p:gmatch('[^/]+') do
        if seg == '.' or seg == '..' then return false end
        -- `.git` inside a tree is not a path we serve; git itself refuses to
        -- track one, so encountering it means something is being probed.
        if seg:lower() == '.git' then return false end
    end
    return true
end

-- A ref as it may appear in a URL, before resolution. This is a cheap
-- pre-filter, NOT the security boundary — browse_resolve is, because it turns
-- whatever survives this into an object id.
local function ref_shape_ok(ref)
    ref = tostring(ref or '')
    if ref == '' or #ref > 255 then return false end
    if ref:sub(1, 1) == '-' then return false end
    -- git's own ref rules, the subset that matters here.
    if ref:find('%z') or ref:find('%s') then return false end
    if ref:find('%.%.') or ref:find('^%.') or ref:find('%.$') then return false end
    if ref:find('[~^:?*%[%]\\]') then return false end
    if ref:find('@{', 1, true) then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Ref resolution
-- ---------------------------------------------------------------------------

-- Turn a branch name, tag, or object id into a commit object id.
--
-- `^{commit}` makes an annotated tag resolve to the commit it points at rather
-- than to the tag object, so every caller downstream can assume it holds a
-- commit. `--verify` makes rev-parse fail instead of echoing back garbage it
-- could not resolve, and `--end-of-options` stops even a ref that slipped
-- through ref_shape_ok from being read as a switch.
--
-- Returns (oid, decoded_ref) or (nil, message). The decoded ref goes back so a
-- caller can echo what it actually resolved, rather than the encoded form the
-- client happened to send.
function g_exports.browse_resolve(dir, ref)
    -- Decode first, validate second — the same order the path helpers use, and
    -- for the same reason: '%2e%2e' is '..', and a check run before decoding
    -- waves it through. Decoding here also makes a slashed branch name usable,
    -- since ':ref' is one URL segment and `feature/x` has to arrive as
    -- `feature%2Fx` to survive routing.
    ref = decode_segment(ref or '')
    if not ref_shape_ok(ref) then return nil, 'invalid ref' end

    local r = git_exec({ 'rev-parse', '--verify', '--quiet', '--end-of-options',
                         ref .. '^{commit}' }, { cwd = dir })
    local oid = util_str_trim(r.stdout or '')
    if not r.ok or not oid:match('^%x+$') then
        return nil, 'unknown ref'
    end
    return oid, ref
end

-- ---------------------------------------------------------------------------
-- Trees and blobs
-- ---------------------------------------------------------------------------

-- One directory level. `oid` must come from browse_resolve; `path` from
-- browse_decode_path ('' for the root).
--
-- Returns an array of { name, path, type, mode, oid, size } sorted directories
-- first, then by name — the order a file listing is expected in, which git does
-- not provide.
function g_exports.browse_tree(dir, oid, path)
    local spec = oid .. ':' .. (path == '' and '' or (path .. '/'))
    -- -z: NUL-terminated records and UNQUOTED names. Without it a file called
    -- `we"ird` or one containing a newline comes back quoted and escaped, and
    -- any line-based parse of it is wrong.
    -- -l: include the blob size, so a listing does not need a call per entry.
    local r = git_exec({ 'ls-tree', '-z', '-l', '--full-tree', '--end-of-options',
                         spec }, { cwd = dir, max_capture = 4 * 1024 * 1024 })
    if not r.ok then return nil, 'not a directory in this revision' end

    local out = {}
    for record in tostring(r.stdout):gmatch('([^%z]+)') do
        -- <mode> SP <type> SP <oid> SP* <size> TAB <name>
        local meta, name = record:match('^(.-)\t(.*)$')
        if meta and name then
            local mode, kind, id, size =
                meta:match('^(%d+)%s+(%S+)%s+(%x+)%s+(%S+)$')
            if mode then
                out[#out + 1] = {
                    name = name,
                    path = (path == '' and name or (path .. '/' .. name)),
                    type = kind,
                    mode = mode,
                    oid  = id,
                    size = tonumber(size) or nil,   -- '-' for trees
                }
            end
        end
    end

    table.sort(out, function(a, b)
        local ad, bd = (a.type == 'tree'), (b.type == 'tree')
        if ad ~= bd then return ad end
        return a.name < b.name
    end)
    return out
end

-- Metadata for one blob, without reading it: type, size, and whether it looks
-- binary. Returns nil plus a message when the path is not a blob.
function g_exports.browse_blob_info(dir, oid, path)
    if path == '' then return nil, 'not a file' end
    local spec = oid .. ':' .. path

    local r = git_exec({ 'cat-file', '-t', '--end-of-options', spec }, { cwd = dir })
    local kind = util_str_trim(r.stdout or '')
    if not r.ok or kind ~= 'blob' then return nil, 'not a file' end

    r = git_exec({ 'cat-file', '-s', '--end-of-options', spec }, { cwd = dir })
    local size = tonumber(util_str_trim(r.stdout or ''))
    if not r.ok or not size then return nil, 'could not size the file' end

    return { path = path, size = size, oid = spec }
end

-- Write a blob to a scratch file and return its path, for http_response_file to stream.
--
-- Through a file rather than captured into a string on purpose: this is the one
-- browsing endpoint whose response can be arbitrarily large, and the same
-- send_file_response path the packfiles use costs nothing extra here.
--
-- The caller MUST proc_tmp_release() the returned path once the response is queued.
function g_exports.browse_blob_file(dir, spec)
    local out = proc_tmp_path('blob')
    local r = git_exec({ 'cat-file', 'blob', '--end-of-options', spec },
                       { cwd = dir, stdout_file = out })
    if not r.ok then
        proc_tmp_release(out)
        return nil, 'could not read the file'
    end
    return out
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

-- A record separator that cannot occur in commit metadata. git's --format
-- placeholders are substituted verbatim, so any printable delimiter can appear
-- inside a commit message; these two control characters cannot survive in one,
-- because git strips them from messages.
local FIELD = '\1'
local RECORD = '\2'

local LOG_FORMAT = table.concat({
    '%H', '%h', '%an', '%ae', '%aI', '%cn', '%ce', '%cI', '%P', '%s', '%b',
}, FIELD) .. RECORD

local function parse_log(text)
    local out = {}
    for raw in tostring(text):gmatch('([^' .. RECORD .. ']+)') do
        -- git puts a newline between records; strip it rather than letting it
        -- become the first character of the next commit's object id.
        -- (A for-loop variable is const in Lua 5.5, hence the copy.)
        local record = (raw:gsub('^[\r\n]+', ''))
        if record ~= '' then
            local f = {}
            for field in (record .. FIELD):gmatch('([^' .. FIELD .. ']*)' .. FIELD) do
                f[#f + 1] = field
            end
            if f[1] and f[1]:match('^%x+$') then
                local parents = {}
                for p in tostring(f[9] or ''):gmatch('%S+') do parents[#parents + 1] = p end
                out[#out + 1] = {
                    oid = f[1], short = f[2],
                    author    = { name = f[3], email = f[4], date = f[5] },
                    committer = { name = f[6], email = f[7], date = f[8] },
                    parents = util_json_array(parents),
                    subject = f[10] or '',
                    body = util_str_trim(f[11] or ''),
                }
            end
        end
    end
    return out
end

-- Commit list reachable from `oid`, newest first.
-- opts = { limit, skip, path }
function g_exports.browse_log(dir, oid, opts)
    opts = opts or {}
    local limit = math.min(math.max(tonumber(opts.limit) or 30, 1), MAX_LOG)
    local skip  = math.max(tonumber(opts.skip) or 0, 0)

    local args = { 'log', '--format=' .. LOG_FORMAT,
                   '--max-count=' .. limit, '--skip=' .. skip,
                   '--end-of-options', oid }
    -- `--` separates revisions from paths. Without it a path that happens to
    -- look like a ref makes git guess, and it guesses differently depending on
    -- what exists in the repository.
    if opts.path and opts.path ~= '' then
        args[#args + 1] = '--'
        args[#args + 1] = opts.path
    end

    local r = git_exec(args, { cwd = dir, max_capture = 8 * 1024 * 1024 })
    if not r.ok then return nil, 'could not read the history' end
    return parse_log(r.stdout)
end

-- One commit, with the list of files it touched.
function g_exports.browse_commit(dir, oid)
    local r = git_exec({ 'show', '--no-patch', '--format=' .. LOG_FORMAT,
                         '--end-of-options', oid }, { cwd = dir })
    if not r.ok then return nil, 'unknown commit' end
    local list = parse_log(r.stdout)
    if #list == 0 then return nil, 'unknown commit' end
    local commit = list[1]

    -- --root is what makes the INITIAL commit list its files. diff-tree
    -- compares against the first parent, and a root commit has none, so without
    -- it the first commit in every repository reports that it changed nothing.
    local diff = { 'diff-tree', '-z', '--root', '--no-commit-id',
                   '--name-status', '-r', '--end-of-options', oid }
    r = git_exec(diff, { cwd = dir, max_capture = 4 * 1024 * 1024 })
    local files = {}
    if r.ok then
        -- -z output is STATUS NUL PATH NUL ... with renames adding a second
        -- path, so this walks pairs rather than splitting on a separator.
        local fields = {}
        for f in tostring(r.stdout):gmatch('([^%z]*)%z') do fields[#fields + 1] = f end
        local i = 1
        while i <= #fields do
            local status = fields[i]
            if status == '' then break end
            local letter = status:sub(1, 1)
            if letter == 'R' or letter == 'C' then
                files[#files + 1] = { status = letter,
                                      from = fields[i + 1], path = fields[i + 2] }
                i = i + 3
            else
                files[#files + 1] = { status = letter, path = fields[i + 1] }
                i = i + 2
            end
        end
    end
    commit.files = util_json_array(files)
    return commit
end

-- Unified patch for one commit. The commit id must already have come from
-- browse_resolve, so caller-controlled ref text never reaches this command.
-- A path filter is optional and MUST have been checked by browse_decode_path
-- before it arrives here.
--
-- Keep the cap on the captured output rather than letting a large generated
-- patch become an unbounded Lua string. Reading one byte past the configured
-- limit lets us distinguish an exact-size patch from a truncated capture.
function g_exports.browse_diff(dir, oid, path)
    local max = cfg_int('MAX_DIFF_MB', 8) * 1024 * 1024
    if max <= 0 then return nil, 'diff output disabled' end

    local args = {
        'show', '--format=', '--patch', '--binary', '--full-index',
        '--no-color', '--no-ext-diff', '--root', '--end-of-options', oid,
    }
    if path and path ~= '' then
        args[#args + 1] = '--'
        args[#args + 1] = path
    end

    local r = git_exec(args, { cwd = dir, max_capture = max + 1 })
    if not r.ok then return nil, 'could not read the diff' end

    local patch = tostring(r.stdout or '')
    if #patch > max then
        return nil, string.format('diff exceeds MAX_DIFF_MB (%d MiB)',
                                  math.floor(max / (1024 * 1024)))
    end
    return patch
end

-- Branches and tags, from one call each.
function g_exports.browse_refs(dir, kind)
    local prefix = (kind == 'tags') and 'refs/tags/' or 'refs/heads/'
    local r = git_exec({ 'for-each-ref', '--format=%(refname:short)\1%(objectname)\1%(creatordate:iso-strict)',
                         '--end-of-options', prefix }, { cwd = dir })
    if not r.ok then return nil, 'could not list refs' end

    local out = {}
    for line in tostring(r.stdout):gmatch('[^\r\n]+') do
        local name, id, date = line:match('^([^\1]*)\1([^\1]*)\1(.*)$')
        if name and name ~= '' then
            out[#out + 1] = { name = name, oid = id, date = date }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end
