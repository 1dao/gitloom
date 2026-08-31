-- test/unit.lua — pure-Lua checks that need no server and no platform support.
--
--   Run: bin/xnet.exe test/unit.lua       (or bin/xnet on Linux)
--   Exit code 0 = all pass.
--
-- test/smoke.sh covers behaviour through real HTTP and a real git client, which
-- is the right level for almost everything. This file exists for the logic that
-- either has no HTTP surface yet or is awkward to provoke through one — chunk
-- framing being the case that prompted it, since the streaming transport it
-- belongs to only runs on Linux and would otherwise ship unexercised.

package.path = 'app/?.lua;' .. package.path

local root_globals = _G
local boot = dofile('app/boot.lua')

boot.load_script('app/cfg.lua')
boot.load_script('app/util.lua')
boot.load_script('app/proc.lua')
boot.load_script('app/pkt.lua')
boot.load_script('app/repo.lua')
boot.load_script('app/git.lua')
boot.load_script('app/auth_ratelimit.lua')
boot.load_script('app/auth.lua')
boot.load_script('app/http.lua')
boot.load_script('app/stream.lua')
boot.load_script('app/browse.lua')
boot.load_script('test/module_scope.lua')

local unit_env = boot.new_environment('test/unit.lua')
if _VERSION == 'Lua 5.1' then setfenv(1, unit_env) end
local _ENV = unit_env

local fails, total = 0, 0
local function out(s) io.write(s); io.flush() end
local function check(name, cond, detail)
    total = total + 1
    if cond then out('PASS ' .. name .. '\n')
    else fails = fails + 1; out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n') end
end
local function eq(name, got, want)
    check(name, got == want, string.format('got %q want %q', tostring(got), tostring(want)))
end

-- ── module isolation and exports ───────────────────────────────────────────
check('g_exports is the only app registry in root _G',
    rawget(root_globals, 'g_exports') == g_exports,
    'registry missing or replaced')
check('an exported function is not copied onto root _G',
    rawget(root_globals, 'repo_dir') == nil,
    'repo_dir leaked into _G')
check('a bare module variable stays out of root _G',
    rawget(root_globals, 'private_value') == nil,
    'private_value leaked into _G')
check('a bare module function stays out of root _G',
    rawget(root_globals, 'private_increment') == nil,
    'private_increment leaked into _G')
eq('an export can be called directly and reach file-private state',
    module_scope_private_api(), 42)

do
    boot.strict_enable()
    local read_ok, read_err = pcall(function() return root_globals.__gitloom_missing_test end)
    local write_ok, write_err = pcall(function()
        root_globals.__gitloom_new_test = true
    end)
    boot.strict_disable()
    check('strict mode rejects undefined global reads',
        not read_ok and tostring(read_err):find('undefined global read') ~= nil, read_err)
    check('strict mode rejects new global writes',
        not write_ok and tostring(write_err):find('undefined global write') ~= nil, write_err)
end

do
    local before = repo_dir
    local ok, err = pcall(function() g_exports.repo_dir = function() end end)
    check('duplicate exports are rejected', not ok and tostring(err):find('duplicate export') ~= nil,
        err)
    check('a rejected duplicate keeps the original', repo_dir == before, 'export changed')
end

do
    local ok, err = pcall(boot.load_script, 'app/pkt.lua')
    check('duplicate module loads are rejected',
        not ok and tostring(err):find('already loaded') ~= nil, err)
end

do
    local ok, err = pcall(boot.load_script, 'test/module_bad_export.lua')
    check('exports must use the filename as their module prefix',
        not ok and tostring(err):find("invalid export 'wrong_prefix'") ~= nil, err)
end

-- A stand-in for a connection: records every byte send_raw is given.
local function fake_conn()
    local c = { sent = {}, closed = nil, flushed = nil }
    function c:send_raw(data) self.sent[#self.sent + 1] = data; return true end
    function c:close(reason) self.closed = reason end
    function c:close_after_flush(reason) self.flushed = reason end
    function c:text() return table.concat(self.sent) end
    return c
end

-- ── chunk framing ──────────────────────────────────────────────────────────
-- The wire format is unforgiving and the mistakes are silent: a missing CRLF
-- after the payload, or a decimal length where hex is required, produces a
-- response a client rejects as corrupt rather than one that merely looks wrong.

do
    local c = fake_conn()
    stream_begin(c, 200, { ['Content-Type'] = 'application/x-git-upload-pack-result' })
    local head = c:text()
    check('begin sends a 200 status line', head:find('^HTTP/1%.1 200 ') ~= nil, head:sub(1, 40))
    check('begin declares chunked', head:find('Transfer%-Encoding: chunked') ~= nil, head)
    check('begin keeps the content type',
        head:find('Content%-Type: application/x%-git%-upload%-pack%-result') ~= nil, head)
    check('begin ends the header block', head:sub(-4) == '\r\n\r\n', 'no blank line')

    -- Content-Length alongside chunked is a request-smuggling primitive, not a
    -- cosmetic error, so stream_begin has to drop a caller-supplied one.
    local c2 = fake_conn()
    stream_begin(c2, 200, { ['Content-Length'] = '99' })
    check('begin refuses Content-Length', c2:text():lower():find('content%-length') == nil, c2:text())
end

do
    local c = fake_conn()
    stream_write(c, 'hello')
    eq('a 5-byte chunk is framed in hex', c:text(), '5\r\nhello\r\n')
end

do
    local c = fake_conn()
    stream_write(c, string.rep('x', 255))
    check('length is hex, not decimal', c:text():sub(1, 5) == 'ff\r\nx', c:text():sub(1, 8))
end

do
    -- A zero-length chunk TERMINATES the body. Emitting one mid-stream would
    -- truncate the response and the client would report a short packfile.
    local c = fake_conn()
    stream_write(c, '')
    eq('an empty write emits nothing', c:text(), '')
    stream_write(c, nil)
    eq('a nil write emits nothing', c:text(), '')
end

do
    local c = fake_conn()
    stream_finish(c)
    eq('finish sends the terminator', c:text(), '0\r\n\r\n')
end

do
    -- Binary must survive: a packfile contains every byte value, and anything
    -- that treats the payload as text breaks here and nowhere else.
    local blob = {}
    for b = 0, 255 do blob[#blob + 1] = string.char(b) end
    local data = table.concat(blob)

    local c = fake_conn()
    stream_begin(c, 200, {})
    stream_write(c, data)
    stream_finish(c)

    local body = c:text():match('\r\n\r\n(.*)$')
    local want = string.format('%x\r\n', #data) .. data .. '\r\n' .. '0\r\n\r\n'
    check('a 256-byte binary chunk round-trips', body == want,
        string.format('len got=%d want=%d', #body, #want))
end

do
    -- Aborting must NOT write the terminator: a client that receives one has
    -- been told the body is complete, and would treat a truncated packfile as
    -- a successful transfer.
    local c = fake_conn()
    stream_begin(c, 200, {})
    stream_write(c, 'partial')
    stream_abort(c, 'test')
    check('abort omits the terminator', c:text():sub(-5) ~= '0\r\n\r\n', 'terminator was sent')
    check('abort closes the connection', c.closed ~= nil, 'connection left open')
end

-- ── "the response is already committed" ────────────────────────────────────
-- The serve loop decides between send_response and closing on this flag. Get it
-- wrong in one direction and a 500's headers are appended to a packfile the
-- client is still reading; wrong in the other and an ordinary request on a
-- reused connection is answered by a hang-up instead of a response.
do
    local c = fake_conn()
    check('a fresh connection is uncommitted', stream_is_committed(c) == false, 'committed')

    stream_begin(c, 200, {})
    check('begin commits the connection', stream_is_committed(c) == true, 'not committed')

    stream_finish(c)
    check('finish leaves it committed', stream_is_committed(c) == true,
        'cleared by finish -- a later failure would send a second response')

    stream_reset(c)
    check('reset clears it for the next request', stream_is_committed(c) == false,
        'still committed')

    -- Two connections must not see each other's state; the table is keyed by
    -- connection precisely so a busy stream cannot mute an unrelated request.
    local a, b = fake_conn(), fake_conn()
    stream_begin(a, 200, {})
    check('commitment is per connection',
        stream_is_committed(a) == true and stream_is_committed(b) == false, 'leaked')
end

-- ── JSON array typing ──────────────────────────────────────────────────────
do
    local xutils = require('xutils')
    local packed = xutils.json_pack({ refs = util_json_array({}) })
    eq('an empty array survives packing as []', util_json_fix_arrays(packed), '{"refs":[]}')

    local full = xutils.json_pack({ refs = util_json_array({ 'a', 'b' }) })
    eq('a non-empty array is untouched', util_json_fix_arrays(full), '{"refs":["a","b"]}')
end

-- ── name and path rules ────────────────────────────────────────────────────
do
    for _, n in ipairs({ 'demo', 'a', 'x_1', 'a.b-c', '_leading' }) do
        check('name accepted: ' .. n, repo_name_ok(n) == true, 'rejected')
    end
    for _, n in ipairs({ '', '.', '..', '.git', 'a/b', 'a%b', '-lead', 'demo.',
                         'demo ', 'CON', 'nul', 'COM1', 'lpt9', 'x.lock' }) do
        check('name rejected: ' .. (n == '' and '<empty>' or n),
              repo_name_ok(n) == false, 'accepted')
    end
end

do
    for _, p in ipairs({ '', 'a', 'a/b/c.txt', 'a b+c.md', 'dot.in.name' }) do
        check('path accepted: ' .. (p == '' and '<root>' or p),
              browse_path_ok(p) == true, 'rejected')
    end
    for _, p in ipairs({ '/abs', '../up', 'a/../b', 'a/./b', '-opt',
                         'a\\b', '.git/config', 'x/.GIT/y' }) do
        check('path rejected: ' .. p, browse_path_ok(p) == false, 'accepted')
    end
    -- Decoding happens before validation, or %2e%2e walks straight through.
    check('encoded traversal is decoded then rejected',
        browse_decode_path('%2e%2e/%2e%2e/etc') == nil, 'accepted')
    eq('percent-decoding keeps a literal plus',
        browse_decode_path('a%20b%2Bc.md'), 'a b+c.md')
end

-- ── atomic file replace ────────────────────────────────────────────────────
do
    local dir = 'tmp/unit'
    util_dir_make(dir)
    local path = dir .. '/atomic.txt'

    util_file_remove(path)
    check('atomic write creates', util_file_write_atomic(path, 'first') == true, 'failed')
    eq('content is what was written', util_file_read(path), 'first')

    check('atomic write replaces', util_file_write_atomic(path, 'second') == true, 'failed')
    eq('replacement content', util_file_read(path), 'second')

    -- The failure mode this replaced was a window where the file did not exist
    -- at all; whatever happens, a reader must never see it missing.
    check('no .tmp is left behind', util_file_exists(path .. '.tmp') == false, 'leftover .tmp')
    check('no .bak is left behind', util_file_exists(path .. '.bak') == false, 'leftover .bak')
    util_file_remove(path)
end

-- ── pkt-line ───────────────────────────────────────────────────────────────
do
    eq('pkt_line frames with a 4-hex length', pkt_line('a'), '0005a')
    eq('pkt_flush', pkt_flush(), '0000')
    eq('service header', pkt_service_header('git-upload-pack'),
       '001e# service=git-upload-pack\n0000')
    local parsed = pkt_parse('0005a0000')
    check('pkt_parse reads data then flush',
        parsed and #parsed == 2 and parsed[1].payload == 'a' and parsed[2].kind == 'flush',
        'unexpected parse')
end

out(string.format('\n[unit] %s (%d checks, %d failure(s))\n',
    fails == 0 and 'ALL PASS' or 'FAILED', total, fails))

return {
    __init = function() xthread.stop(fails == 0 and 0 or 1) end,
}
