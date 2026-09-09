-- app/browse.lua — reading a repository's contents.
--
-- Exports: browse_path_ok, browse_decode_path, browse_resolve,
--          browse_tree, browse_blob_info, browse_blob_file,
--          browse_log, browse_last_commits, browse_commit, browse_diff,
--          browse_merge_base, browse_compare, browse_compare_diff,
--          browse_refs, browse_search
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
-- opts = { limit, skip, path, lookahead, exclude }
function g_exports.browse_log(dir, oid, opts)
    opts = opts or {}
    local limit = math.min(math.max(math.floor(tonumber(opts.limit) or 30), 1), MAX_LOG)
    local skip  = math.max(math.floor(tonumber(opts.skip) or 0), 0)
    local fetch_limit = opts.lookahead and (limit + 1) or limit

    local args = { 'log', '--format=' .. LOG_FORMAT,
                   '--max-count=' .. fetch_limit, '--skip=' .. skip,
                   '--end-of-options', oid }
    -- `^<oid>` drops everything reachable from it, which is what turns a walk
    -- over one revision's history into the commits it has and another does not.
    -- Only ever an object id, checked here as well as by its caller: this is a
    -- revision expression on a command line.
    if opts.exclude and tostring(opts.exclude):match('^%x+$') then
        args[#args + 1] = '^' .. opts.exclude
    end
    -- `--` separates revisions from paths. Without it a path that happens to
    -- look like a ref makes git guess, and it guesses differently depending on
    -- what exists in the repository.
    if opts.path and opts.path ~= '' then
        args[#args + 1] = '--'
        args[#args + 1] = opts.path
    end

    local r = git_exec(args, { cwd = dir, max_capture = 8 * 1024 * 1024 })
    if not r.ok then return nil, 'could not read the history' end
    local out = parse_log(r.stdout)
    local has_more = opts.lookahead and #out > limit or false
    if has_more then out[#out] = nil end
    return out, nil, { limit = limit, skip = skip, has_more = has_more }
end

-- How far back the listing walk is willing to look. See browse_last_commits.
local MAX_LASTCOMMIT_SCAN = 400

-- The newest commit touching each direct child of a directory — the "who last
-- changed this, and when" column a file listing wants.
--
-- ONE process, not one per entry. `git log --name-only` walks newest first and
-- prints the files each commit touched, so the FIRST time a name appears is by
-- definition the last commit that changed it. A `git log -1 -- <entry>` per
-- entry would be exact, but a directory of forty files is then forty forks
-- through a process pool that is also serving every other request.
--
-- The walk is capped, and that is the one thing this deliberately does not do:
-- a file nobody has touched in MAX_LASTCOMMIT_SCAN commits comes back with a
-- blank cell rather than making the listing wait for a full traversal of a long
-- history. Blank is the honest answer for an entry the cap did not reach.
--
-- `-c` is what makes a MERGE attributable. Without it a merge commit prints no
-- names at all, so a file whose current content was decided in the merge — a
-- conflict resolved there, which is the only way a change lands through a merge
-- and nowhere else — was credited to whichever parent's commit the walk reached
-- next. Not "unattributed": attributed to a commit that does not contain it.
-- `-c` prints the combined diff, which is exactly the set of files the merge
-- itself decided. Its `-z` framing differs — an extra NUL and no leading
-- newline before the first name — and the loop below already reads both,
-- because it skips empty runs rather than counting fields.
--
-- Returns an array of { name, commit }, and the newest commit touching the
-- directory as a whole as the third value.
function g_exports.browse_last_commits(dir, oid, path)
    -- %x01 and %x02 rather than the literal control bytes the other formats in
    -- this file use: git substitutes these itself, so neither byte has to
    -- survive the trip out through a command line.
    -- %b LAST, and for a reason: it is the only field that may contain
    -- newlines, and everything after the header is file names. A reader hovering
    -- the column wants the whole message -- the subject says what changed, the
    -- body says why -- so the walk that is already running carries it.
    local fmt = '%x02%H%x01%h%x01%cI%x01%an%x01%s%x01%b'
    local args = { 'log', '--format=' .. fmt, '--name-only', '-c', '-z',
                   '--no-renames', '--max-count=' .. MAX_LASTCOMMIT_SCAN,
                   '--end-of-options', oid }
    if path ~= '' then
        args[#args + 1] = '--'
        args[#args + 1] = path
    end

    local r = git_exec(args, { cwd = dir, max_capture = 8 * 1024 * 1024 })
    if not r.ok then return nil, 'could not read the history' end

    local prefix = (path == '' and '' or (path .. '/'))
    local plen = #prefix
    local seen, out, latest = {}, {}, nil

    for record in tostring(r.stdout):gmatch('([^' .. RECORD .. ']+)') do
        -- <header> NUL [ LF <name> NUL ... ]. Neither the header nor a name can
        -- contain a NUL, which is the whole reason -z is here: an UNQUOTED name
        -- may contain anything else, newlines included, so nothing but the NUL
        -- can be trusted to end one.
        local header, rest = record:match('^([^%z]*)%z(.*)$')
        if not header then header, rest = record, '' end
        local f = {}
        for field in (header .. FIELD):gmatch('([^' .. FIELD .. ']*)' .. FIELD) do
            f[#f + 1] = field
        end
        if f[1] and f[1]:match('^%x+$') then
            -- The tail is rejoined rather than taken as one field: a commit
            -- message may contain any byte, FIELD included, and the body is the
            -- one place where a stray one would silently cut off what a reader
            -- is being shown.
            local body = f[6] or ''
            for i = 7, #f do body = body .. FIELD .. f[i] end
            local commit = {
                oid = f[1], short = f[2], date = f[3],
                author = f[4] or '', subject = f[5] or '',
                body = util_str_trim(body),
            }
            if not latest then latest = commit end
            -- The LF git puts between the header and the first name is not part
            -- of that name; every other LF in there is.
            local files = rest:gsub('^\n', '', 1)
            for name in files:gmatch('([^%z]+)') do
                if prefix == '' or name:sub(1, plen) == prefix then
                    local child = name:sub(plen + 1):match('^([^/]+)')
                    if child and not seen[child] then
                        seen[child] = true
                        out[#out + 1] = { name = child, commit = commit }
                    end
                end
            end
        end
    end
    return out, nil, latest
end

-- `--name-status -z` output: STATUS NUL PATH NUL, and for a rename or a copy a
-- second path follows the first. That is why this walks pairs rather than
-- splitting on a separator — the record length depends on the status letter.
--
-- Shared by the per-commit file list and by the compare, because `diff-tree`
-- and `diff` print the same thing here. A second copy of a parser whose stride
-- varies by record is a second place to get the stride wrong.
local function parse_name_status(text)
    local fields, files = {}, {}
    for f in tostring(text or ''):gmatch('([^%z]*)%z') do fields[#fields + 1] = f end
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
    return files
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
    commit.files = util_json_array(r.ok and parse_name_status(r.stdout) or {})
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
local function capture_patch(dir, args, path)
    local max = cfg_int('MAX_DIFF_MB', 8) * 1024 * 1024
    if max <= 0 then return nil, 'diff output disabled' end

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

function g_exports.browse_diff(dir, oid, path)
    return capture_patch(dir, {
        'show', '--format=', '--patch', '--binary', '--full-index',
        '--no-color', '--no-ext-diff', '--root', '--end-of-options', oid,
    }, path)
end

-- ---------------------------------------------------------------------------
-- Comparing two revisions
-- ---------------------------------------------------------------------------

-- THREE DOTS, NOT TWO, and that is the whole design of this pair.
--
-- A comparison answers "what would this branch add", so it starts where the two
-- histories last agreed — the MERGE BASE — and not at the tip of base. Diffing
-- the two tips directly also reports everything that landed on base while this
-- branch was away, and attributes all of it to the branch. That difference is
-- what `base...head` means against `base..head`, and it is the whole of why a
-- pull request shows what it shows.
--
-- The merge base is computed HERE rather than left to `git diff base...head`,
-- for two reasons. It is worth reporting on its own — it is the answer to "what
-- is this branch measured against". And when there is no common ancestor at all
-- — two unrelated histories pushed into one repository, which happens — the
-- three-dot form is a fatal error, while doing it in two steps leaves somewhere
-- for that case to go.
--
-- Both oids must already have come from browse_resolve; the shape is checked
-- again here because these two are the only values in this file that are
-- CONCATENATED into a revision expression rather than passed as their own argv
-- entry, and a range is not something --end-of-options can protect.
--
-- Returns { base, head, merge_base, unrelated, ahead, behind, commits, files,
--           limit, skip, has_more }.
--
-- browse_merge_base is separate because the patch endpoint needs the same
-- starting point and nothing else the compare computes; sharing the whole of
-- browse_compare to get one object id would be four git processes for one
-- answer. Returns nil when the histories are unrelated, which is a state and
-- not a failure.
function g_exports.browse_merge_base(dir, a, b)
    if not tostring(a):match('^%x+$') or not tostring(b):match('^%x+$') then
        return nil
    end
    local r = git_exec({ 'merge-base', '--end-of-options', a, b }, { cwd = dir })
    local oid = util_str_trim(tostring(r.stdout or ''))
    if not r.ok or not oid:match('^%x+$') then return nil end
    return oid
end

function g_exports.browse_compare(dir, base_oid, head_oid, opts)
    opts = opts or {}
    if not tostring(base_oid):match('^%x+$') or
       not tostring(head_oid):match('^%x+$') then
        return nil, 'invalid revision'
    end

    local merge_base = browse_merge_base(dir, base_oid, head_oid)

    -- Everything below measures from here: the merge base when there is one,
    -- and the tip of base when there is not. Both the file list and the patch
    -- take it from this one variable, so the two halves of a comparison cannot
    -- disagree about where it starts.
    local from = merge_base or base_oid

    -- left is what base has and head does not (behind); right is the reverse
    -- (ahead). The symmetric difference is defined with or without a common
    -- ancestor, so this one needs no fallback.
    local behind, ahead = 0, 0
    local counts = git_exec({ 'rev-list', '--left-right', '--count',
                              '--end-of-options',
                              base_oid .. '...' .. head_oid }, { cwd = dir })
    if counts.ok then
        local l, r = tostring(counts.stdout or ''):match('(%d+)%s+(%d+)')
        behind, ahead = tonumber(l) or 0, tonumber(r) or 0
    end

    local commits, cerr, page = browse_log(dir, head_oid, {
        limit = opts.limit, skip = opts.skip, exclude = from, lookahead = true,
    })
    if not commits then return nil, cerr end
    page = page or {}

    local d = git_exec({ 'diff', '--name-status', '-z', '--find-renames',
                         '--no-color', '--no-ext-diff',
                         '--end-of-options', from, head_oid },
                       { cwd = dir, max_capture = 4 * 1024 * 1024 })

    return {
        base = base_oid, head = head_oid,
        merge_base = merge_base,
        -- Named rather than inferred from a null merge_base: a caller that did
        -- not think about this case should still be able to see that it is
        -- being shown a different comparison from the one it asked for.
        unrelated = merge_base == nil,
        ahead = ahead, behind = behind,
        commits = util_json_array(commits), count = #commits,
        files = util_json_array(d.ok and parse_name_status(d.stdout) or {}),
        limit = page.limit, skip = page.skip,
        has_more = page.has_more and true or false,
    }
end

-- The patch for a comparison. Same cap and the same 413 as browse_diff, because
-- both go through capture_patch — a comparison is an easier way to ask for a
-- very large diff than any single commit is, so it must not be the one path
-- that forgets the ceiling.
--
-- `from` is the merge base browse_compare already computed, passed in rather
-- than recomputed, so the patch and the file list beside it are the same
-- comparison rather than two that agree by coincidence.
function g_exports.browse_compare_diff(dir, from_oid, head_oid, path)
    if not tostring(from_oid):match('^%x+$') or
       not tostring(head_oid):match('^%x+$') then
        return nil, 'invalid revision'
    end
    return capture_patch(dir, {
        'diff', '--patch', '--binary', '--full-index', '--find-renames',
        '--no-color', '--no-ext-diff', '--end-of-options', from_oid, head_oid,
    }, path)
end

-- Search the contents of one revision: `git grep`, bounded.
--
-- FIXED STRINGS, not a regular expression. `-F` is not a convenience here: the
-- pattern is typed by whoever is looking and a regex engine given hostile input
-- is a way to spend the server's CPU without limit, which for a search anyone
-- with read access can run is the whole of the denial-of-service surface. The
-- shape people actually want -- "where is this identifier" -- is a fixed string
-- anyway.
--
-- Every other bound is there for the same reason. `--max-count` caps matches
-- PER FILE so one generated file cannot fill the answer, `max_capture` caps the
-- bytes git may hand back at all, and the total is cut at `limit` so the
-- response stays a page rather than a repository. `-I` skips binary files,
-- which is what makes the output text in the first place.
--
-- `oid` must come from browse_resolve, like every other function here: rule 1 at
-- the top of this file is that caller-supplied ref text never reaches a git
-- command line, and `git grep <ref>` would be exactly that.
--
-- Returns a list of { path, line, text } plus a flag saying the answer was cut.
function g_exports.browse_search(dir, oid, query, limit)
    local pattern = tostring(query or '')
    if pattern == '' then return nil, 'a search string is required' end
    if #pattern > 256 then return nil, 'search string is too long' end
    limit = math.max(1, math.min(tonumber(limit) or 200, 500))

    local r = git_exec({
        'grep', '--no-color', '-I', '-n', '-F', '--max-count=20',
        '--full-name', '-e', pattern,
        '--end-of-options', oid,
    }, { cwd = dir, max_capture = 2 * 1024 * 1024 })

    -- git grep exits 1 for "found nothing", which is an answer and not a
    -- failure, and 2 or more for an actual one. Branching on the EXIT CODE
    -- rather than on whether any output came back is the difference between
    -- those two, and getting it wrong is not a small thing: the first version
    -- of this treated "no output" as "no matches", so an invalid option --
    -- which is exactly what it shipped with -- reported every search as
    -- finding nothing, in a repository where the word was on line 1.
    if r.exit_code == 1 then
        return { results = {}, count = 0, truncated = false }
    end
    if not r.ok then
        cfg_log_warn('git grep failed (exit %s): %s', tostring(r.exit_code),
            util_str_trim(tostring(r.stderr or '')))
        return nil, 'search failed'
    end

    local out, truncated = {}, false
    for line in tostring(r.stdout):gmatch('[^\r\n]+') do
        -- <oid>:<path>:<lineno>:<text>. The object id is echoed back on every
        -- row because the search was given one, and a path may itself contain a
        -- colon, so this strips the known prefix rather than splitting on ':'.
        local rest = line
        if util_str_starts(rest, oid .. ':') then rest = rest:sub(#oid + 2) end
        local path, no, text = rest:match('^(.-):(%d+):(.*)$')
        if path and path ~= '' then
            if #out >= limit then truncated = true; break end
            -- One long line in a minified file would otherwise be the whole
            -- response. The reader wants to see WHERE the match is; the file
            -- view is one click away for the rest of it.
            if #text > 400 then text = text:sub(1, 400) end
            out[#out + 1] = { path = path, line = tonumber(no), text = text }
        end
    end
    return { results = out, count = #out, truncated = truncated }
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
