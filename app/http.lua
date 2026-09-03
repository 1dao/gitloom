-- app/http.lua — the HTTP server: routing, the serve loop, and responses.
--
-- Exports: http_get, http_post, http_put, http_delete, http_route,
--          http_fallback, http_body_stream, http_listen, http_dispatch,
--          http_wait_until, http_after,
--          http_response_text, http_response_json, http_response_error, http_response_file, http_response_redirect,
--          http_safe_error
--
-- Shape lifted from xpauth's main.lua: xnet.listen with raw framing, the codec
-- parsing whole requests out of a per-connection buffer, and ONE COROUTINE PER
-- REQUEST so a handler may yield on an xproc or MySQL RPC while the event loop
-- keeps serving everyone else. Requests on a single connection are serialised
-- behind a `busy` flag, because HTTP/1.1 responses must come back in order.
--
-- ROUTING
-- Two layers, checked in this order:
--   1. the table: exact paths and ':param' segments, per method
--   2. the fallback chain: functions that inspect the whole path and either
--      handle it or decline
-- Git's smart-HTTP endpoints go through the fallback chain, because their paths
-- are `<anything>/info/refs` — the interesting part is the SUFFIX, and the
-- repository name is whatever came before it. Matching that in a segment table
-- would mean enumerating every repository as a route.

local codec = dofile('scripts/core/share/xhttp_codec.lua')

local routes    = {}    -- method -> { {segs, names, handler, raw}, ... }
local fallbacks = {}
local server    = nil
local is_https  = false
local body_stream_wanted = nil   -- see http_body_stream

-- ---------------------------------------------------------------------------
-- Response helpers
--
-- A response is a plain table { status, body, headers, file }. `file` names a
-- path the C layer streams straight to the socket — see http_response_file.
-- ---------------------------------------------------------------------------

function g_exports.http_response_text(status, body, content_type)
    return {
        status = status or 200,
        body = tostring(body or ''),
        headers = { ['Content-Type'] = content_type or 'text/plain; charset=utf-8' },
    }
end

function g_exports.http_response_json(status, value)
    local xutils = require('xutils')
    local json = xutils.json_pack(value)
    if json then json = util_json_fix_arrays(json) end
    if not json then
        -- json_pack returns nil rather than raising when a string is not valid
        -- UTF-8. Letting that through would send an empty body with a 200.
        cfg_log_error('json_pack failed for a %s response', tostring(status))
        return http_response_text(500, 'response serialisation failed')
    end
    return {
        status = status or 200,
        body = json,
        headers = { ['Content-Type'] = 'application/json; charset=utf-8' },
    }
end

-- Strip anything that discloses where the server keeps its files.
--
-- Error text is routinely built from a child process's stderr, and git says
-- things like "cannot mkdir C:/Users/alice/gitloom/repos/bob/CON.git: Invalid
-- argument" — which handed an ordinary authenticated caller the absolute
-- install path, the operator's account name, and the on-disk layout. The full
-- text still goes to the log, where it belongs.
function g_exports.http_safe_error(message)
    local s = tostring(message or 'error')
    s = s:gsub('%a:[/\\][^%s\'"]*', '<path>')      -- C:\... or C:/...
    s = s:gsub('/[%w_.-]+/[^%s\'"]*', '<path>')    -- /home/alice/...
    return s
end

function g_exports.http_response_error(status, message)
    return http_response_json(status, { error = tostring(message or 'error'), status = status })
end

function g_exports.http_response_redirect(location, status)
    return { status = status or 302, body = '',
             headers = { ['Location'] = tostring(location) } }
end

-- Stream a file as the response body.
--
-- The codec fills in Content-Length by stat'ing the path and then calls
-- conn:send_file_response, which opens the file in C and drains it to the socket
-- as the socket accepts bytes. Nothing passes through a Lua string, which is
-- what makes serving a multi-gigabyte packfile possible in a runtime with no
-- response streaming.
--
-- The caller keeps ownership of the file: hand it to proc_tmp_release() after this,
-- never to os.remove — the C layer still has it open.
function g_exports.http_response_file(path, content_type, headers)
    return {
        status = 200,
        file = path,
        content_type = content_type or 'application/octet-stream',
        headers = headers or {},
    }
end

-- ---------------------------------------------------------------------------
-- Routing table
-- ---------------------------------------------------------------------------

-- Segment kinds: a literal string, PARAM for ':name', or WILD for '*name'.
-- WILD is only meaningful as the last segment and swallows everything left,
-- slashes included — file paths inside a repository need it, since
-- `tree/main/src/app.lua` has no fixed segment count.
local PARAM, WILD = false, true

local function compile(pattern)
    local segs, names = {}, {}
    for seg in tostring(pattern):gmatch('[^/]+') do
        local wild = seg:match('^%*(.+)$')
        local param = seg:match('^:(.+)$')
        if wild then
            segs[#segs + 1] = WILD
            names[#segs] = wild
        elseif param then
            segs[#segs + 1] = PARAM
            names[#segs] = param
        else
            segs[#segs + 1] = seg
        end
    end
    for i = 1, #segs - 1 do
        if segs[i] == WILD then
            error(string.format(
                "http_route: '*%s' must be the last segment of %q",
                names[i], pattern), 3)
        end
    end
    return segs, names
end

function g_exports.http_route(method, pattern, handler)
    method = method:upper()
    routes[method] = routes[method] or {}
    local segs, names = compile(pattern)
    table.insert(routes[method], { segs = segs, names = names,
                                   handler = handler, raw = pattern })
end

function g_exports.http_get(p, h)    http_route('GET', p, h)    end
function g_exports.http_post(p, h)   http_route('POST', p, h)   end
function g_exports.http_put(p, h)    http_route('PUT', p, h)    end
function g_exports.http_delete(p, h) http_route('DELETE', p, h) end

-- Register a whole-path matcher. It receives (req, ctx) and returns a response
-- table to claim the request, or nil to decline and let the next one look.
-- Checked in registration order, only after the route table misses.
function g_exports.http_fallback(fn)
    fallbacks[#fallbacks + 1] = fn
end

-- Register the predicate that decides whether a request's body reaches its
-- handler in pieces instead of whole. It is called with the parsed request HEAD
-- — method, path, headers, content_length, chunked — and returns true to stream.
-- One predicate; the last registration wins.
--
-- A hook rather than a rule because this module knows nothing about git, and
-- streaming is only ever right for a handler that consumes bytes as they
-- arrive. See "Streamed request bodies" in the serve loop below.
function g_exports.http_body_stream(fn)
    body_stream_wanted = fn
end

local function match_route(method, path)
    local list = routes[method:upper()]
    if not list then return nil end
    local parts = util_str_split(path, '/')

    for _, r in ipairs(list) do
        local n = #r.segs
        local wild_at = (n > 0 and r.segs[n] == WILD) and n or nil
        -- A wildcard route matches when everything before the wildcard lines up
        -- and there is at least nothing left over; an exact route needs the
        -- same number of segments.
        local viable = wild_at and (#parts >= wild_at - 1) or (#parts == n)

        if viable then
            local params, ok = {}, true
            local fixed = wild_at and (wild_at - 1) or n
            for i = 1, fixed do
                local seg = r.segs[i]
                if seg == PARAM then
                    params[r.names[i]] = parts[i]
                elseif seg ~= parts[i] then
                    ok = false
                    break
                end
            end
            if ok and wild_at then
                params[r.names[wild_at]] =
                    table.concat(parts, '/', wild_at, #parts)
            end
            if ok then return r.handler, params end
        end
    end
    return nil
end

-- Resolve one request to a response table. Exported so a test can drive routing
-- without opening a socket.
function g_exports.http_dispatch(req, ctx)
    local handler, params = match_route(req.method, req.path)
    -- HEAD is GET without a body, and the codec already drops the body while
    -- keeping the Content-Length it would have had -- so routing is the only
    -- part of it that needs saying. Without this every HEAD is a 404, which is
    -- what a reverse proxy or an uptime monitor sends at the browser's entry
    -- point before anything else.
    if not handler and req.method:upper() == 'HEAD' then
        handler, params = match_route('GET', req.path)
    end
    if handler then
        ctx.params = params
        return handler(req, ctx)
    end
    for _, fn in ipairs(fallbacks) do
        local resp = fn(req, ctx)
        if resp then return resp end
    end
    return http_response_error(404, 'not found')
end

-- ---------------------------------------------------------------------------
-- Client address behind a reverse proxy
--
-- gitloom is almost always fronted by something terminating TLS, and from
-- behind one every request arrives from the proxy. Two things then break, both
-- silently:
--
--   * every audit line records the proxy instead of the client
--   * auth_ratelimit keys on the source address, so ONE person guessing
--     passwords locks out everybody
--
-- X-Forwarded-For fixes that, but only when it can be trusted. The header is
-- client-supplied: anyone may send one, so honouring it unconditionally lets a
-- caller pick the address their failures are counted against and walk straight
-- past the lockout. It is therefore read ONLY when the socket's peer is itself
-- a configured proxy.
--
-- The list grows left to right as a request passes through proxies, so the
-- RIGHTMOST entry is the one our nearest proxy appended and the only one it
-- vouches for. Walking right to left and stopping at the first address that is
-- not itself a trusted proxy yields the real client; everything further left
-- was supplied by whoever spoke to the outermost hop and is not evidence.
-- ---------------------------------------------------------------------------

local trusted_proxies = nil     -- address -> true, built once

local function proxies()
    if trusted_proxies then return trusted_proxies end
    trusted_proxies = {}
    for addr in tostring(cfg_get('TRUSTED_PROXIES', '')):gmatch('[^,%s]+') do
        trusted_proxies[addr] = true
    end
    return trusted_proxies
end

-- Does this look like an address rather than free text? The result reaches log
-- lines and rate-limit keys, so a header carrying a novel is not something to
-- pass along. Deliberately loose: it accepts IPv4, IPv6 and the bracketed
-- host:port forms proxies emit, and rejects anything with whitespace, commas or
-- control characters.
local function address_like(s)
    if type(s) ~= 'string' or s == '' or #s > 64 then return false end
    return s:match('^[%x%.:%[%]]+$') ~= nil
end

-- The address to treat as the client's, given the socket peer and the request.
--
-- `trusted` overrides the configured set. Production never passes it; the tests
-- do, because the configured set is read once and cached, and the interesting
-- part of this function is precisely how it behaves across different sets.
function g_exports.http_client_ip(peer, headers, trusted)
    trusted = trusted or proxies()
    if not peer or not trusted[peer] then return peer end

    local fwd = headers and headers['x-forwarded-for']
    if not fwd then return peer end

    local hops = {}
    for hop in tostring(fwd):gmatch('[^,]+') do
        hops[#hops + 1] = (hop:gsub('^%s+', ''):gsub('%s+$', ''))
    end

    for i = #hops, 1, -1 do
        local hop = hops[i]
        if not trusted[hop] then
            -- The first hop from the right that is not one of ours.
            if address_like(hop) then return hop end
            -- Malformed: stop rather than keep walking left. Anything further
            -- along is even less trustworthy than the entry we just rejected.
            return peer
        end
    end

    -- Every hop was a proxy of ours, so the chain never names a client.
    return peer
end

-- For the boot banner: say whether the header is honoured at all, and from whom.
function g_exports.http_trusted_proxy_report()
    local list = {}
    for addr in pairs(proxies()) do list[#list + 1] = addr end
    table.sort(list)
    if #list == 0 then
        cfg_log_system('trusted proxies: none — X-Forwarded-For is ignored and ' ..
                       'the socket peer is the client address')
    else
        cfg_log_system('trusted proxies: %s (X-Forwarded-For honoured only from these)',
            table.concat(list, ', '))
    end
end

-- ---------------------------------------------------------------------------
-- Serve loop
-- ---------------------------------------------------------------------------

-- Weak keys: a connection that is closed and dropped by the runtime must not be
-- kept alive by this table.
local conns = setmetatable({}, { __mode = 'k' })

local MAX_REQUEST, HANDSHAKE_MS, resp_opts, parse_opts

-- What the channel layer may hold in ITS inbound buffer before it gives up on
-- the connection. Not a request ceiling, and it used to be set to one.
--
-- on_packet consumes every byte it is handed, so a request far larger than this
-- still arrives — in pieces, which is the whole point. What crosses this line is
-- a client that sends faster than the loop drains, and the C layer answers by
-- closing the channel with "packet_too_large": no status, no log line, nothing
-- a client can act on. Wired to MAX_REQUEST_SIZE_MB it therefore read like a
-- request ceiling and behaved like neither — an operator lowering that value to
-- bound JSON bodies silently broke every push instead of answering 413. The 413
-- still comes from on_packet, which counts what it has actually buffered.
local READ_BURST = 8 * 1024 * 1024

-- Defaults rather than nils: http_listen fills these in from the config, and
-- test/unit.lua exercises the machinery below without ever opening a socket.
local BODY_QUEUE_HIGH = 1024 * 1024
local MAX_PUSH        = 0            -- 0 = no ceiling on a streamed body
local BODY_TIMEOUT_MS = 600 * 1000   -- 0 = wait for a streamed body for ever

local function clear_handshake(st)
    if st.hs then st.hs:del(); st.hs = nil end
end

local pump   -- forward declaration: serve_one recurses into it for keep-alive

-- ---------------------------------------------------------------------------
-- Incoming byte accumulation
--
-- The obvious `st.buf = st.buf .. data` on every packet is quadratic: the
-- socket delivers in ~64 KiB reads, so a 64 MiB push copies the whole buffer
-- about a thousand times — gigabytes of memcpy and a matching amount of garbage,
-- all on the event loop, for one client. That is a denial of service anybody
-- with push rights (or an anonymous fetch, which also POSTs a body) can trigger.
--
-- Instead: chunks land in a list, and the buffer is only materialised when it
-- could actually satisfy a parse.
--
--   * While the request's total size is unknown, concatenate on every packet.
--     That is cheap — headers arrive in the first read or two — and it is what
--     lets us read Content-Length.
--   * Once the total IS known, accumulate without copying until enough bytes
--     have arrived, then concatenate exactly once.
--
-- A chunked request (no Content-Length) keeps the old behaviour, because its
-- length is not knowable up front. git does not use chunked for smart HTTP.
-- ---------------------------------------------------------------------------

local function buffered(st)
    return #st.buf + st.pending_n
end

-- Stop and start reading the connection. Used for exactly one thing: a streamed
-- body whose queue the handler has not drained yet.
--
-- POSIX ONLY, in practice. On Windows an accepted connection paused this way
-- does not come back — the read event is removed from the poll set and the
-- resume leaves the client reset — so a streamed body is only ever offered
-- where the streaming transport runs at all. smart.lua ties the two together.
local function read_pause(conn, st)
    if st.paused or st.dead then return end
    st.paused = true
    conn:pause_read()
end

local function read_resume(conn, st)
    if not st.paused then return end
    st.paused = false
    if not conn:is_closed() then conn:resume_read() end
end

-- Fold any pending chunks into st.buf. One concat, however many chunks.
local function materialise(st)
    if st.pending_n == 0 then return end
    -- Whatever is already in st.buf came first on the wire and must lead.
    if #st.buf > 0 then table.insert(st.pending, 1, st.buf) end
    st.buf = table.concat(st.pending)
    st.pending = {}
    st.pending_n = 0
end

-- Total bytes this request occupies, once the headers are in st.buf. nil while
-- the header block is incomplete or the request has no Content-Length.
local function request_size(st)
    local header_end = st.buf:find('\r\n\r\n', 1, true)
    if not header_end then return nil end
    local head = st.buf:sub(1, header_end + 3)
    -- Header names are case-insensitive; match on a lowercased copy but measure
    -- against the original, which is what the codec will parse.
    local len = head:lower():match('\r\ncontent%-length:%s*(%d+)')
    if not len then
        -- No body, or chunked. Either way the header block is the whole of what
        -- we can predict, and a chunked body falls back to per-packet concat.
        if head:lower():find('\r\ntransfer%-encoding:', 1, false) then return nil end
        return header_end + 3
    end
    return header_end + 3 + tonumber(len)
end

-- ---------------------------------------------------------------------------
-- The main-state ticker
--
-- Two things a request coroutine needs and cannot have for itself: to wait for
-- a condition the channel layer never announces — room in a child process's
-- stdin — and to schedule something for later, such as the timeout that kills
-- that child.
--
-- xtimer cannot give it either. It records the lua_State that armed the timer,
-- so one armed inside a request coroutine fires INTO that coroutine: the
-- callback is a lua_pcall on a state that is suspended mid-yield, and calling
-- coroutine.resume on it from there is a segfault — reliably, on the first push
-- large enough to make the wait happen. main.lua says the same thing about the
-- scratch sweeper, in the same words, for the same reason.
--
-- So there is ONE timer, armed from the main state by http_listen, and both
-- facilities are lists it walks. Its callbacks run on the main state, where
-- resuming a suspended coroutine is exactly what coroutine.resume is for.
--
-- It ticks whether or not anything is waiting, because arming it on demand
-- would mean arming it from a coroutine, which is the thing that does not work.
-- An empty tick is two length checks.
-- ---------------------------------------------------------------------------

local waiters = {}      -- coroutines parked on a condition
local timers  = {}      -- functions to run once, later
local tick_timer = nil

local function tick()
    if #timers > 0 then
        local now, live, due = util_now_ms(), {}, nil
        for i = 1, #timers do
            local t = timers[i]
            if t.cancelled then                       -- dropped, never run
            elseif now >= t.at then due = due or {}; due[#due + 1] = t
            else live[#live + 1] = t end
        end
        timers = live
        for i = 1, due and #due or 0 do
            local ok, e = pcall(due[i].fn)
            if not ok then cfg_log_error('scheduled callback failed: %s', tostring(e)) end
        end
    end

    if #waiters > 0 then
        local now, live, due = util_now_ms(), {}, nil
        for i = 1, #waiters do
            local w = waiters[i]
            local go = w.deadline ~= nil and now >= w.deadline
            if not go then
                local ok, ready = pcall(w.ready)
                -- A predicate that raises releases the coroutine rather than
                -- parking it for good; it will see the same failure itself.
                go = (not ok) or ready == true
            end
            if go then due = due or {}; due[#due + 1] = w
            else live[#live + 1] = w end
        end
        -- Swapped BEFORE anything is resumed: a coroutine that parks again
        -- straight away has to land on the new list, not on one that is about
        -- to be thrown away.
        waiters = live
        for i = 1, due and #due or 0 do
            local ok, e = coroutine.resume(due[i].co)
            if not ok then cfg_log_error('a parked coroutine crashed: %s', tostring(e)) end
        end
    end
end

-- Park the running coroutine until ready() answers true, or until timeout_ms
-- has passed. Returns what ready() says at that point. COROUTINE-ONLY.
--
-- NOTHING ELSE MAY RESUME a coroutine parked here: the ticker is holding it and
-- would resume it a second time, by then somewhere else entirely. Whatever the
-- other event is, say it in ready() instead.
function g_exports.http_wait_until(ready, timeout_ms)
    if ready() then return true end
    waiters[#waiters + 1] = {
        co       = coroutine.running(),
        ready    = ready,
        deadline = timeout_ms and (util_now_ms() + timeout_ms) or nil,
    }
    coroutine.yield()
    return ready() == true
end

-- Run fn once, on the main state, after delay_ms. Returns a function that
-- cancels it. Safe to call from a request coroutine, which xtimer.add is not.
-- Resolution is one tick, so this is for seconds, not for milliseconds.
function g_exports.http_after(delay_ms, fn)
    local t = { at = util_now_ms() + delay_ms, fn = fn, cancelled = false }
    timers[#timers + 1] = t
    return function() t.cancelled = true end
end

-- ---------------------------------------------------------------------------
-- Streamed request bodies
--
-- Everything above buffers a request whole before a handler sees it, which is
-- the right trade for a JSON API: the body is small, and `req.body` is what a
-- handler wants. A push is not that. `git receive-pack` is handed a packfile,
-- the packfile IS the repository, and buffering it makes MAX_REQUEST_SIZE_MB
-- the largest repository this server can ever accept — with a copy of it in Lua
-- memory for every push in flight.
--
-- So a request may instead be dispatched as soon as its HEADERS are complete,
-- carrying `req.body_stream` in place of `req.body`. Its handler pulls pieces
-- as they come off the socket and hands them straight to git's stdin; nothing
-- larger than one queue is ever held, and the ceiling goes away.
--
-- WHICH REQUESTS is not decided here — this module knows nothing about git.
-- http_body_stream() registers the predicate that is asked, once, per request.
--
-- BACKPRESSURE. Decoded bytes queue until the handler asks for them; above
-- BODY_QUEUE_HIGH the connection stops being read, which stops the client. The
-- queue is handed over whole on the next read and reading resumes. A handler
-- that never reads therefore costs one queue, not one repository.
-- ---------------------------------------------------------------------------

-- Longest chunk-size line and trailer block accepted. Real ones are a handful
-- of bytes; anything sending more is either broken or looking for a buffer that
-- grows without a limit.
local CHUNK_LINE_MAX = 1024
local TRAILER_MAX    = 8192

-- An incremental decoder for Transfer-Encoding: chunked.
--
-- codec.parse_chunked wants the whole body in one string, which is exactly what
-- this path exists not to have. This one takes bytes as they arrive and calls
-- emit() for each decoded piece.
--
-- feed(data, pos) returns the position one past the last byte it consumed, or
-- nil plus a message. Once `done` is set, the terminating chunk and its
-- trailers have been read and everything from the returned position on belongs
-- to the NEXT request on the connection.
local function chunked_decoder(emit)
    local d = { done = false }
    local state, part, remaining = 'size', '', 0

    function d.feed(data, pos)
        -- Past the terminating chunk everything belongs to the next request,
        -- so hand it straight back rather than reading it as more trailers.
        if d.done then return pos end
        local n = #data
        while pos <= n do
            if state == 'size' then
                local nl = data:find('\n', pos, true)
                if not nl then
                    part = part .. data:sub(pos)
                    if #part > CHUNK_LINE_MAX then
                        return nil, 'chunk size line too long'
                    end
                    return n + 1
                end
                local line = part .. data:sub(pos, nl - 1)
                part, pos = '', nl + 1
                -- STRICT, and deliberately stricter than being lenient would
                -- cost. A bare LF terminator, or trailing rubbish after the
                -- size, is a framing disagreement waiting to happen: a proxy in
                -- front of us that reads the line differently sees a different
                -- request boundary, which is the whole of request smuggling.
                -- Anything this rejects, git never sends.
                if line:sub(-1) ~= '\r' then return nil, 'bad chunk size' end
                local text = line:sub(1, -2)
                -- 1*HEXDIG, then optionally ';ext=value' that nothing here uses.
                local hex = text:match('^(%x+)$') or text:match('^(%x+);')
                if not hex or #hex > 8 then return nil, 'bad chunk size' end
                remaining = tonumber(hex, 16)
                if not remaining then return nil, 'bad chunk size' end
                state = remaining == 0 and 'trailer' or 'data'
            elseif state == 'data' then
                local take = remaining
                if take > n - pos + 1 then take = n - pos + 1 end
                emit(data:sub(pos, pos + take - 1))
                pos = pos + take
                remaining = remaining - take
                if remaining == 0 then state = 'crlf' end
            elseif state == 'crlf' then
                local take = 2 - #part
                if take > n - pos + 1 then take = n - pos + 1 end
                part = part .. data:sub(pos, pos + take - 1)
                pos = pos + take
                if #part == 2 then
                    if part ~= '\r\n' then return nil, 'bad chunk terminator' end
                    part, state = '', 'size'
                end
            else
                -- Trailers: header-shaped lines ended by an empty one. Read
                -- rather than skipped only so the body's end is found exactly;
                -- nothing here uses their contents.
                local nl = data:find('\n', pos, true)
                if not nl then
                    part = part .. data:sub(pos)
                    if #part > TRAILER_MAX then return nil, 'chunk trailer too long' end
                    return n + 1
                end
                local line = part .. data:sub(pos, nl - 1)
                part, pos = '', nl + 1
                if line:sub(-1) ~= '\r' then return nil, 'bad chunk trailer' end
                if #line == 1 then          -- the empty line: body over
                    d.done = true
                    return pos
                end
            end
        end
        return pos
    end

    return d
end

-- Exported under the test-only prefix. Chunk framing is far easier to get wrong
-- than to provoke through a real client, which is what test/unit.lua is for.
g_exports.__http_chunked_decoder = chunked_decoder

-- Resume whoever is parked in body_read. The handler can run to completion from
-- here — this is its event — so callers must be finished touching `st` before
-- they call it.
local function body_wake(b)
    local co = b.waiter
    if not co then return end
    b.waiter = nil
    local ok, e = coroutine.resume(co)
    if not ok then cfg_log_error('request coroutine crashed: %s', tostring(e)) end
end

-- Abandon a streamed body: a parked read returns the reason and the rest of the
-- bytes are discarded. For when the thing consuming the body has gone — a git
-- child that exited while the client was still uploading, say. Without it that
-- handler waits for a body nobody will ever read.
local function body_abort(b, reason)
    if b.err or b.eof then return end
    b.err = tostring(reason or 'aborted')
    body_wake(b)
end

-- The next piece of a streamed body: a non-empty string, nil at the end of the
-- body, or nil plus a message. COROUTINE-ONLY — it yields until bytes arrive
-- and is resumed from on_packet.
local function body_read(conn, st, b)
    while true do
        if b.n > 0 then
            local data = table.concat(b.q)
            b.q, b.n = {}, 0
            read_resume(conn, st)
            return data
        end
        if b.err then return nil, b.err end
        if b.eof then return nil end
        -- The socket is gone, so the body will never be completed. Without this
        -- the handler parks here for good: nothing else would resume it.
        if st.dead then return nil, 'client disconnected' end
        b.waiter = coroutine.running()
        coroutine.yield()
    end
end

-- Take bytes off the wire for a request whose body is being streamed.
--
-- Anything past the end of the body belongs to the next request and goes back
-- into st.buf BEFORE the handler is woken: the handler may finish and call
-- pump() from inside that wake, and pump reads st.buf.
local function body_feed(conn, st, data)
    local b = st.body
    local pos = 1

    if not b.eof and not b.err then
        if b.dec then
            local next_pos, derr = b.dec.feed(data, pos)
            if not next_pos then
                b.err = derr
            else
                pos = next_pos
                if b.dec.done then b.eof = true end
            end
        else
            local take = b.remaining
            if take > #data then take = #data end
            if take > 0 then
                b.q[#b.q + 1] = data:sub(1, take)
                b.n = b.n + take
                b.total = b.total + take
                pos = take + 1
                b.remaining = b.remaining - take
            end
            if b.remaining == 0 then b.eof = true end
        end
        if MAX_PUSH > 0 and b.total > MAX_PUSH and not b.err then
            b.err = 'request body too large'
        end
    end

    if pos <= #data then st.buf = st.buf .. data:sub(pos) end

    -- The body is in; the deadline below has nothing left to guard, and firing
    -- it later would abort a handler that is by then busy with the response.
    if (b.eof or b.err) and b.cancel_deadline then
        b.cancel_deadline()
        b.cancel_deadline = nil
    end

    body_wake(b)

    -- Everything below concerns a body that is still arriving; if the handler
    -- finished inside that wake, there is no longer one.
    if st.body ~= b then return end
    if not b.eof and b.n >= BODY_QUEUE_HIGH then read_pause(conn, st) end
end

-- Hand one parsed request to a handler on its own coroutine. Returns true: a
-- request has been taken off the buffer whatever happens next.
local function dispatch_request(conn, st, req)
    -- A parsed request proves this is an HTTP client and not a socket somebody
    -- opened and abandoned, so the handshake deadline has done its job.
    clear_handshake(st)
    -- The codec only fills peer_ip when it is handed the connection state; the
    -- credential rate limiter keys on it, so set it unconditionally here rather
    -- than threading a ctx through every handler.
    --
    -- Resolved once, from the socket peer and this request's headers: behind a
    -- trusted proxy the peer is the proxy, and everything that keys on an
    -- address — the audit log, the credential lockout — has to see the client.
    local client_ip = http_client_ip(st.ip, req.headers)
    req.peer_ip = client_ip
    st.need = nil          -- the next request has to be measured on its own
    st.head_done = false
    st.busy = true

    -- This request has written nothing yet. Cleared here rather than when the
    -- previous stream finished, so that a failure AFTER a stream's terminating
    -- chunk is still treated as "already committed" and not answered twice.
    stream_reset(conn)

    local co = coroutine.create(function()
        local ctx = { ip = client_ip, peer_ip = st.ip, conn = conn,
                      https = st.https }
        local ok, resp = pcall(http_dispatch, req, ctx)
        if not ok then
            cfg_log_error('handler error on %s %s: %s', req.method, req.path, tostring(resp))
            resp = http_response_error(500, 'internal error')
        end

        -- Unless a streamed body ended cleanly, this response is the last thing
        -- on the connection.
        --
        -- Two ways it does not. A handler can answer without reading the body
        -- out — a 401 or a 415 on a push — and the rest of it goes on arriving
        -- at a connection that has already been replied to. Or the body can
        -- FAIL: over MAX_PUSH_SIZE_MB, or misframed. body_feed stops decoding
        -- at that point and puts everything that follows into st.buf, so
        -- keeping the connection means the serve loop reads the remainder of a
        -- packfile as pipelined HTTP requests — which is how a ceiling that is
        -- supposed to refuse a push turned into a stream of 400s on a
        -- connection that was still being written to.
        --
        -- Nothing can be lined up behind bytes nobody is going to read, and
        -- draining a packfile only to discard it costs exactly what streaming
        -- saved. So: end the connection.
        if st.body then
            if st.body.err or not st.body.eof then req.keep_alive = false end
            if st.body.cancel_deadline then st.body.cancel_deadline() end
            st.body = nil
        end

        if not st.dead then
            if stream_is_committed(conn) then
                -- A streamed response has already written itself, headers and
                -- all, straight to the connection. Sending anything now — the
                -- 500 above included — appends it to a body that is already on
                -- the wire, so the client reports a corrupt packfile and never
                -- sees the error. Closing without the terminating chunk is the
                -- only signal left; see stream_abort.
                if not ok or not stream_response_is_streamed(resp) then
                    stream_abort(conn, 'handler did not finish a committed response')
                end
            elseif not stream_response_is_streamed(resp) then
                codec.send_response(conn, req, resp, resp_opts)
            end
            -- Scratch files handed to send_file_response stay open in C until
            -- the response drains; releasing them here queues them for the
            -- sweeper rather than deleting them out from under the send.
            if resp and resp.release_file then proc_tmp_release(resp.release_file) end
            if not req.keep_alive and not st.dead then
                -- close_after_flush, NOT close: everything above only QUEUES
                -- bytes — send_response hands a file to the C layer, and a
                -- streamed body can still have megabytes buffered behind the
                -- terminating chunk. close() drops whatever has not reached the
                -- socket, which on a `Connection: close` fetch is the tail of
                -- the packfile. This shuts down once the queue has drained.
                st.dead = true
                conn:close_after_flush('done')
            end
        end
        st.busy = false
        read_resume(conn, st)   -- reading stopped while this request was running
        pump(conn, st)          -- drain anything that arrived while we worked
    end)

    local resumed, e = coroutine.resume(co)
    if not resumed then
        cfg_log_error('request coroutine crashed: %s', tostring(e))
        st.busy = false
        -- The tail above never ran, so nothing else will start reading again.
        read_resume(conn, st)
    end
    return true
end

-- Dispatch a request whose body the handler will read in pieces. `req` is the
-- head as parse_request_head returned it: everything parse_request produces
-- except `body`, which is replaced by `body_stream`.
local function serve_streamed(conn, st, req, body_start)
    local b = { q = {}, n = 0, total = 0, eof = false, err = nil, waiter = nil }
    if req.chunked then
        b.dec = chunked_decoder(function(piece)
            b.q[#b.q + 1] = piece
            b.n = b.n + #piece
            b.total = b.total + #piece
        end)
    else
        b.remaining = req.content_length or 0
        b.eof = b.remaining == 0
    end
    st.body = b

    req.body_stream = {
        read  = function() return body_read(conn, st, b) end,
        abort = function(reason) body_abort(b, reason) end,
    }

    -- A deadline on the body itself, because nothing else is one.
    --
    -- HANDSHAKE_TIMEOUT_SEC is cleared the moment a request parses, and
    -- GIT_TIMEOUT_SEC lives inside stream_rpc — so it covers the streaming
    -- transport and not the file-staging fallback taken when every streaming
    -- slot is busy. A client that sends its headers and then stops would hold
    -- that request's coroutine, and its connection, until the process ended.
    if BODY_TIMEOUT_MS > 0 then
        b.cancel_deadline = http_after(BODY_TIMEOUT_MS, function()
            b.cancel_deadline = nil
            if st.body ~= b then return end
            cfg_log_warn('%s: streamed body did not finish in %ds, abandoning it',
                st.ip, math.floor(BODY_TIMEOUT_MS / 1000))
            body_abort(b, 'request body timed out')
        end)
    end

    -- Whatever of the body arrived alongside the headers goes through the same
    -- path as everything that follows it. Fed before the handler exists, so
    -- nothing is woken, and any bytes past the body's end land in st.buf.
    local rest = st.buf:sub(body_start)
    st.buf = ''
    if #rest > 0 then body_feed(conn, st, rest) end

    return dispatch_request(conn, st, req)
end

local function serve_one(conn, st)
    -- The head is read before anything waits on a length. A request whose body
    -- will be streamed has to be dispatched as soon as its headers are in, and
    -- waiting for its Content-Length is the one thing that would defeat the
    -- point. Once per request, not once per packet: scanning the whole buffer
    -- for the header terminator on every read of a 1 GiB push is quadratic.
    if not st.head_done then
        materialise(st)
        local head, body_start, herr = codec.parse_request_head(st.buf, 1, parse_opts)
        if not head and herr == 'incomplete' then return false end
        st.head_done = true
        -- A head that will not parse is left to parse_request below, which
        -- produces the same error and already knows how to answer it.
        if head and body_stream_wanted and body_stream_wanted(head) then
            return serve_streamed(conn, st, head, body_start)
        end
    end

    -- Cheap path: we already know how big this request is and it is not all
    -- here yet, so there is nothing to gain from copying.
    if st.need and buffered(st) < st.need then return false end
    materialise(st)

    if not st.need then
        st.need = request_size(st)
        if st.need and #st.buf < st.need then return false end
    end

    local req, next_pos, err = codec.parse_request(st.buf, 1, parse_opts)
    if not req then
        if err == 'incomplete' then return false end
        codec.send_error(conn, 400, err, resp_opts)
        st.dead = true
        -- The error was queued, not sent; close() would throw it away and the
        -- client would see a bare disconnect instead of the reason.
        conn:close_after_flush('bad request')
        return false
    end

    st.buf = st.buf:sub(next_pos)
    return dispatch_request(conn, st, req)
end

pump = function(conn, st)
    if not st or st.dead or st.busy then return end
    while not st.busy and not st.dead and buffered(st) > 0 do
        if not serve_one(conn, st) then break end
    end
end

local handler = {}

function handler.on_connect(conn, ip, _port)
    conn:set_framing({ type = 'raw', max_packet = READ_BURST })
    local st = { buf = '', pending = {}, pending_n = 0, need = nil,
                 head_done = false, body = nil, paused = false,
                 ip = ip or '?', busy = false, dead = false,
                 https = is_https }
    conns[conn] = st

    -- A public port collects scanners that open a socket and then say nothing.
    -- Each holds an fd and a table entry indefinitely and never reaches a
    -- handler, so nothing about it is ever logged either. Partial bytes do not
    -- extend the deadline, which makes this a slowloris bound as well.
    --
    -- Armed from the main state on purpose: xtimer keeps a raw pointer to
    -- whichever lua_State armed a timer, so arming from inside a request
    -- coroutine that then finishes fires into freed memory.
    if HANDSHAKE_MS > 0 then
        st.hs = xtimer.add(HANDSHAKE_MS, function()
            st.hs = nil
            if st.dead then return end
            st.dead = true
            cfg_log_warn('no request from %s within %dms (%d buffered byte(s)), closing',
                st.ip, HANDSHAKE_MS, #st.buf)
            conn:close('handshake timeout')
        end, 1)
    end
end

function handler.on_packet(conn, data)
    local st = conns[conn]
    if not st then return #data end
    -- Finished with this connection: it is closing as soon as the error it was
    -- already sent has drained. Buffering the rest of a rejected upload would be
    -- exactly the allocation the rejection exists to avoid.
    if st.dead then return #data end

    -- A request whose body is being streamed does not accumulate: the bytes are
    -- decoded and handed to its handler, and only what follows the body is
    -- buffered, for the next request.
    if st.body then
        body_feed(conn, st, data)
        -- Whatever followed the body is the next request, and it is buffered
        -- like any other — so it gets the same ceiling. Closed rather than
        -- answered with a 413: a response may already be committed on this
        -- connection, and there is no status left to send inside one.
        if #st.buf > MAX_REQUEST then
            st.dead = true
            cfg_log_warn('%s pipelined %d bytes past a streamed body, closing',
                st.ip, #st.buf)
            conn:close('pipelined too far')
            return #data
        end
    else
        st.pending[#st.pending + 1] = data
        st.pending_n = st.pending_n + #data

        -- Enforce the ceiling here, on the running total. The codec also checks
        -- it, but only once the bytes have been concatenated into one string —
        -- which is the allocation we are trying not to make for an over-sized
        -- request.
        if buffered(st) > MAX_REQUEST then
            codec.send_error(conn, 413, 'request body too large', resp_opts)
            st.dead = true
            conn:close_after_flush('request too large')
            return #data
        end

        pump(conn, st)
    end

    -- NOTHING IS PAUSED HERE, tempting as it is. Bytes for the next request
    -- pile up while a handler is busy, so they count against MAX_REQUEST and
    -- can earn a 413 that has nothing to do with the size of anything — git
    -- sends a small probe POST before a large push and starts streaming the
    -- real body the moment that probe is answered, while the handler is still
    -- syncing HEAD. Pausing the connection for the duration fixes that on Linux
    -- and breaks every request on Windows, where pause_read on an accepted TCP
    -- connection does not survive the resume. So the ceiling simply has to
    -- leave room for one request's worth of read-ahead, which gitloom.cfg says.
    --
    -- The return value is how many bytes were consumed. Anything less than
    -- #data and the channel redelivers the remainder on the next read.
    return #data
end

function handler.on_close(conn, _reason)
    local st = conns[conn]
    if st then
        st.dead = true
        clear_handshake(st)   -- the timer's closure holds conn; drop it or it leaks
        -- A handler parked on a streamed body is waiting for bytes that will
        -- never come. body_read sees st.dead and gives up; nothing else here
        -- would ever resume it.
        if st.body then body_wake(st.body) end
    end
    conns[conn] = nil
end

-- Start listening. Returns true, or nil plus a message.
--
-- listen_fd rather than listen even for plain HTTP: TLS needs the raw fd so it
-- can be wrapped, and running both paths through the same accept callback keeps
-- one code path instead of two. The attach happens on THIS thread, because the
-- request coroutines, the connection table and the scratch sweeper all live on
-- this Lua state.
function g_exports.http_listen()
    MAX_REQUEST  = cfg_int('MAX_REQUEST_SIZE_MB', 64) * 1024 * 1024
    HANDSHAKE_MS = cfg_int('HANDSHAKE_TIMEOUT_SEC', 30) * 1000
    BODY_QUEUE_HIGH = cfg_int('BODY_QUEUE_HIGH_KB', 1024) * 1024
    MAX_PUSH        = cfg_int('MAX_PUSH_SIZE_MB', 0) * 1024 * 1024
    BODY_TIMEOUT_MS = cfg_int('BODY_TIMEOUT_SEC', 600) * 1000

    -- Armed HERE, from the main state, and never from a request coroutine —
    -- see "The main-state ticker" above for what happens otherwise. It shares
    -- STREAM_DRAIN_MS with the outbound stream: both are polling for a drain
    -- the channel layer does not report, and there is no reason for two knobs.
    if not tick_timer then
        tick_timer = xtimer.add(cfg_int('STREAM_DRAIN_MS', 20), tick, -1)
    end
    resp_opts    = { server_name = 'gitloom' }
    -- decompress: git gzips request bodies above a few KiB, so without this a
    -- large fetch arrives as compressed bytes and upload-pack rejects it.
    -- No response compression is configured: git bodies are already deflated,
    -- and compressing would defeat http_response_file, which never builds a body string.
    parse_opts   = { max_request_size = MAX_REQUEST, decompress = true }

    local host  = cfg_get('LISTEN_HOST', '0.0.0.0')
    local port  = cfg_int('LISTEN_PORT', 8686)
    local https = cfg_bool('HTTPS', false)

    local tls = nil
    if https then
        local cert, keyf = cfg_get('TLS_CERT_FILE', ''), cfg_get('TLS_KEY_FILE', '')
        if cert == '' or keyf == '' then
            return nil, 'HTTPS=1 needs TLS_CERT_FILE and TLS_KEY_FILE'
        end
        local pw = cfg_get('TLS_KEY_PASSWORD', '')
        tls = { cert_file = cert, key_file = keyf,
                password = pw ~= '' and pw or nil, max_packet = READ_BURST }
    end

    local s, err = xnet.listen_fd(host, port, {
        on_accept = function(_, fd, ip, cport)
            local conn, aerr
            if tls then
                conn, aerr = xnet.attach_tls(fd, handler, ip, cport, tls)
            else
                conn, aerr = xnet.attach(fd, handler, ip, cport)
            end
            if not conn then
                -- One client's failed handshake is not the listener's problem.
                cfg_log_warn('attach failed from %s: %s', tostring(ip), tostring(aerr))
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            cfg_log_warn('listener closed: %s', tostring(reason))
        end,
    })
    if not s then
        return nil, string.format('listen on %s:%d failed: %s', host, port, tostring(err))
    end
    server = s
    is_https = https

    cfg_log_system('listening on %s://%s:%d (buffered request max %d MiB, ' ..
                   'streamed body max %s)',
        https and 'https' or 'http', host, port, cfg_int('MAX_REQUEST_SIZE_MB', 64),
        MAX_PUSH > 0 and (cfg_int('MAX_PUSH_SIZE_MB', 0) .. ' MiB') or 'unlimited')
    if not https then
        cfg_log_warn('HTTPS is off: git sends HTTP Basic credentials in clear text on ' ..
                 'every request, so set HTTPS=1 (or front this with TLS) before ' ..
                 'exposing it beyond localhost')
    end
    return true
end

function g_exports.http_close()
    if server then server:close('shutdown'); server = nil end
    if tick_timer then tick_timer:del(); tick_timer = nil end
end
