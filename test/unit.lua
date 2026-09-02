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
--
-- Like main.lua, this file runs twice: the first pass loads the loader and hands
-- the file back to it, the second arrives inside an app environment where the
-- short names below resolve. See main.lua for why the detour is worth it.
--
-- The root `_G` comes back as a chunk argument because it cannot be recovered
-- from inside an app environment, where `_G` is that environment — which is
-- exactly the difference the isolation checks below have to observe.

local boot, root_globals = ...
if type(boot) ~= 'table' then
    package.path = 'app/?.lua;' .. package.path
    boot = dofile('app/boot.lua')
    return boot.run_script('test/unit.lua', boot, _G)
end

boot.load_script('app/cfg.lua')
boot.load_script('app/util.lua')
boot.load_script('app/proc.lua')
boot.load_script('app/pkt.lua')
boot.load_script('app/repo.lua')
boot.load_script('app/git.lua')
boot.load_script('app/auth_ratelimit.lua')   -- before auth.lua; see main.lua
boot.load_script('app/auth.lua')
boot.load_script('app/http.lua')
boot.load_script('app/stream.lua')
boot.load_script('app/browse.lua')
boot.load_script('app/web.lua')
boot.load_script('test/module_scope.lua')
local codec = dofile('scripts/core/share/xhttp_codec.lua')

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
check('root _G resolves exports through __index',
    root_globals.repo_dir == g_exports.repo_dir,
    'root lookup did not reach g_exports')
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
    local export_ok = root_globals.repo_dir == g_exports.repo_dir
    local read_ok, read_err = pcall(function() return root_globals.__gitloom_missing_test end)
    local write_ok, write_err = pcall(function()
        root_globals.__gitloom_new_test = true
    end)
    boot.__strict_disable()
    check('strict mode keeps root export lookup', export_ok, 'export lookup was blocked')
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

    -- The guard keys on the normalised path. Keyed on the raw string, a second
    -- spelling of one file quietly becomes a second module, which re-runs its
    -- top level and then fails on a duplicate export instead of here.
    for _, respelt in ipairs({ './app/pkt.lua', 'app/./pkt.lua',
                               'app//pkt.lua', 'app\\pkt.lua',
                               'app/../app/pkt.lua' }) do
        local rok, rerr = pcall(boot.load_script, respelt)
        check(string.format('%q is the same module as app/pkt.lua', respelt),
            not rok and tostring(rerr):find('already loaded') ~= nil, rerr)
    end
end

do
    local ok, err = pcall(boot.load_script, 'test/module_bad_export.lua')
    check('exports must use the filename as their module prefix',
        not ok and tostring(err):find("invalid export 'wrong_prefix'") ~= nil, err)
end

do
    -- STRICT_GLOBALS guards the root _G, which holds one name. This is the same
    -- guarantee inside a module environment, where the code actually lives.
    local ok, err = pcall(module_scope_late_global)
    check('a sealed module rejects a name that first appears at runtime',
        not ok and tostring(err):find('assigned after load') ~= nil, err)
    eq('sealing leaves existing file state writable', module_scope_private_api(), 43)
end

do
    local ok, err = pcall(boot.load_script, 'test/module_partial_export.lua')
    check('a module that fails half-way reports its own error',
        not ok and tostring(err):find('deliberate failure') ~= nil, err)
    check('a failed load rolls back the exports it had registered',
        g_exports.module_partial_export_first == nil, 'a partial export survived')
end

do
    -- The longer module name owns the namespace: the live case is auth.lua,
    -- whose auth_ prefix also matches every auth_ratelimit_* name.
    --
    -- KNOWN LIMIT, and the reason this loads module_ns_sub first: ownership is
    -- decided against the modules already loaded, so the rule only holds when
    -- the longer module got there first. Listed the other way round, module_ns
    -- takes module_ns_sub_stolen and neither load fails. main.lua's ordering
    -- comment is what keeps the live case on the right side of that.
    boot.load_script('test/module_ns_sub.lua')
    local ok, err = pcall(boot.load_script, 'test/module_ns.lua')
    check('a shorter module cannot export into a longer one\'s namespace',
        not ok and tostring(err):find("belongs to module 'module_ns_sub'") ~= nil, err)
end

do
    -- Native dofile would run this in the root _G and leak its bare names. The
    -- 'already loaded' refusal is what proves it went to load_script instead:
    -- native dofile has no such notion and would happily run it a second time.
    local ok, err = pcall(dofile, 'test/module_scope.lua')
    check('dofile of an app module is redirected to load_script',
        not ok and tostring(err):find('already loaded') ~= nil, err)
    check('the redirected dofile left root _G clean',
        rawget(root_globals, 'private_value') == nil, 'private_value leaked into _G')

    -- scripts/core/ is the runtime's own subset and keeps the native dofile —
    -- including the right to be loaded more than once.
    local a = dofile('scripts/core/share/xfs.lua')
    local b = dofile('scripts/core/share/xfs.lua')
    check('scripts/core keeps the native dofile',
        type(a) == 'table' and type(b) == 'table', 'a runtime helper failed to load twice')

    local win = pcall(dofile, 'scripts\\core\\share\\xfs.lua')
    check('the scripts/core test survives a backslash path', win, 'backslash path redirected')
end

do
    -- The runtime-script test decides whether a path escapes the module loader,
    -- so it is checked directly rather than only through its effects. It has to
    -- fail CLOSED: every spelling it cannot reduce is "not runtime".
    local case_folded = package.config:sub(1, 1) == '\\'
    local cases = {
        -- spellings of the same real file, all still the runtime's
        { 'scripts/core/share/xfs.lua',            true  },
        { './scripts/core/share/xfs.lua',          true  },
        { 'scripts//core/share/xfs.lua',           true  },
        { 'scripts/core/./share/xfs.lua',          true  },
        { 'scripts/core/../core/share/xfs.lua',    true  },
        { 'scripts\\core\\share\\xfs.lua',         true  },
        { 'scripts/core\\share/xfs.lua',           true  },
        -- traversal out of the runtime tree: this is the one that used to pass
        { 'scripts/core/../../app/repo.lua',       false },
        { 'scripts/core/../app/repo.lua',          false },
        { '../gitloom/scripts/core/share/xfs.lua', false },
        -- absolute in every spelling
        { '/scripts/core/share/xfs.lua',           false },
        { 'C:/gitloom/scripts/core/share/xfs.lua', false },
        { 'C:scripts/core/share/xfs.lua',          false },
        { '//host/share/scripts/core/xfs.lua',     false },
        -- a prefix is not a directory
        { 'scripts/coreX/share/xfs.lua',           false },
        { 'xscripts/core/share/xfs.lua',           false },
        { 'app/repo.lua',                          false },
        { '',                                      false },
        -- case follows the platform: Windows compares paths case-insensitively,
        -- POSIX does not, and folding there would let a real 'Scripts/Core'
        -- directory pass itself off as the runtime's
        { 'SCRIPTS/Core/share/xfs.lua',            case_folded },
    }
    for _, c in ipairs(cases) do
        local path, want = c[1], c[2]
        check(string.format('runtime-script test: %q is %s',
                path, want and 'runtime' or 'redirected'),
            boot.__is_runtime_script(path) == want, 'wrong verdict')
    end

    -- And the traversal is closed in practice, not just in the predicate:
    -- 'already loaded' can only come from load_script, so the redirect happened.
    local ok, err = pcall(dofile, 'scripts/core/../../app/repo.lua')
    check('a traversal out of scripts/core is actually redirected',
        not ok and tostring(err):find('already loaded') ~= nil, err)
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

-- ── client address behind a reverse proxy ──────────────────────────────────
--
-- The whole point of this function is deciding what to BELIEVE, so the cases
-- that matter are the ones where a caller lies. X-Forwarded-For is
-- client-supplied: getting this wrong lets anyone choose the address their
-- failed logins are counted against and walk past the lockout entirely.
do
    local NONE  = {}
    local PROXY = { ['10.0.0.1'] = true }
    local CHAIN = { ['10.0.0.1'] = true, ['10.0.0.2'] = true }

    local function xff(v) return { ['x-forwarded-for'] = v } end

    -- With no proxy configured the header is not evidence of anything.
    eq('no trusted proxies: header ignored',
       http_client_ip('203.0.113.9', xff('1.2.3.4'), NONE), '203.0.113.9')

    -- The peer is a stranger, so the header is a claim by that stranger.
    eq('untrusted peer: header ignored',
       http_client_ip('203.0.113.9', xff('1.2.3.4'), PROXY), '203.0.113.9')

    -- The peer IS the proxy, so its appended entry is worth reading.
    eq('trusted peer: header honoured',
       http_client_ip('10.0.0.1', xff('1.2.3.4'), PROXY), '1.2.3.4')

    -- The list grows left to right, so only the RIGHTMOST entry was written by
    -- our proxy. Everything left of it came from whoever spoke to the outermost
    -- hop and can be anything they liked.
    eq('rightmost entry wins',
       http_client_ip('10.0.0.1', xff('9.9.9.9, 1.2.3.4'), PROXY), '1.2.3.4')

    -- This is the spoof: a client sends its own X-Forwarded-For, and the proxy
    -- APPENDS the real address rather than replacing the header. Taking the
    -- leftmost entry would hand the attacker whatever address they typed.
    eq('a forged left-hand entry cannot win',
       http_client_ip('10.0.0.1', xff('evil-spoofed-value, 203.0.113.7'), PROXY),
       '203.0.113.7')

    -- Multiple hops of our own: skip the ones we recognise, stop at the first
    -- that is not ours.
    eq('trusted hops are skipped right to left',
       http_client_ip('10.0.0.1', xff('203.0.113.7, 10.0.0.2'), CHAIN), '203.0.113.7')

    -- Every hop is ours, so the chain never names a client.
    eq('an all-proxy chain falls back to the peer',
       http_client_ip('10.0.0.1', xff('10.0.0.2, 10.0.0.1'), CHAIN), '10.0.0.1')

    eq('an empty header falls back to the peer',
       http_client_ip('10.0.0.1', xff(''), PROXY), '10.0.0.1')
    eq('a missing header falls back to the peer',
       http_client_ip('10.0.0.1', {}, PROXY), '10.0.0.1')

    -- The result reaches log lines and rate-limit keys, so free text is not
    -- passed along even when the proxy is trusted.
    eq('a non-address entry is refused',
       http_client_ip('10.0.0.1', xff('not an address'), PROXY), '10.0.0.1')
    eq('an over-long entry is refused',
       http_client_ip('10.0.0.1', xff(string.rep('1', 200)), PROXY), '10.0.0.1')

    -- IPv6 has to survive: the charset check must not reject colons.
    eq('IPv6 survives the address check',
       http_client_ip('10.0.0.1', xff('2001:db8::1'), PROXY), '2001:db8::1')

    -- Surrounding spaces are normal in a real header.
    eq('spaces around an entry are trimmed',
       http_client_ip('10.0.0.1', xff('  1.2.3.4  '), PROXY), '1.2.3.4')
end

-- ── incremental HTTP request headers ───────────────────────────────────────
--
-- Smart-HTTP needs to route and authorise a request before its potentially
-- huge git body has arrived. The header parser must therefore expose framing
-- without materialising the body, while the legacy parser keeps its existing
-- body-size and decompression behaviour.
do
    local raw = table.concat({
        'POST /admin/demo.git/git-receive-pack HTTP/1.1\r\n',
        'Host: localhost\r\n',
        'Content-Type: application/x-git-receive-pack-request\r\n',
        'Content-Length: 104857600\r\n',
        'Connection: close\r\n',
        '\r\n',
        'body-prefix',
    })
    local head, body_start, err = codec.parse_request_head(raw)
    check('request head parses before the body is complete', head ~= nil, err)
    eq('request head body start', body_start,
       raw:find('\r\n\r\n', 1, true) + 4)
    eq('request head keeps content length', head and head.content_length, 104857600)
    eq('request head keeps body out of the table', head and head.body, nil)
    eq('request head parses target path', head and head.path,
       '/admin/demo.git/git-receive-pack')

    local chunked = 'POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n'
    local chead = codec.parse_request_head(chunked)
    check('request head recognises chunked framing', chead and chead.chunked == true,
          chead and tostring(chead.chunked))
    eq('chunked head has no content length', chead and chead.content_length, nil)

    local incomplete = codec.parse_request_head('POST / HTTP/1.1\r\nHost: x\r\n')
    eq('incomplete request head is reported', select(3,
       codec.parse_request_head('POST / HTTP/1.1\r\nHost: x\r\n')), 'incomplete')
end

out(string.format('\n[unit] %s (%d checks, %d failure(s))\n',
    fails == 0 and 'ALL PASS' or 'FAILED', total, fails))

return {
    __init = function() xthread.stop(fails == 0 and 0 or 1) end,
}
