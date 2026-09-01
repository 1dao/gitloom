-- app/http.lua — the HTTP server: routing, the serve loop, and responses.
--
-- Exports: http_get, http_post, http_put, http_delete, http_route,
--          http_fallback, http_listen, http_dispatch,
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

local function serve_one(conn, st)
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
    st.buf = st.buf:sub(next_pos)
    st.need = nil          -- the next request has to be measured on its own
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
        pump(conn, st)     -- drain anything that arrived while we were working
    end)

    local resumed, e = coroutine.resume(co)
    if not resumed then
        cfg_log_error('request coroutine crashed: %s', tostring(e))
        st.busy = false
    end
    return true
end

pump = function(conn, st)
    if not st or st.dead or st.busy then return end
    while not st.busy and not st.dead and buffered(st) > 0 do
        if not serve_one(conn, st) then break end
    end
end

local handler = {}

function handler.on_connect(conn, ip, _port)
    conn:set_framing({ type = 'raw', max_packet = MAX_REQUEST })
    local st = { buf = '', pending = {}, pending_n = 0, need = nil,
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

    st.pending[#st.pending + 1] = data
    st.pending_n = st.pending_n + #data

    -- Enforce the ceiling here, on the running total. The codec also checks it,
    -- but only once the bytes have been concatenated into one string — which is
    -- the allocation we are trying not to make for an over-sized request.
    if buffered(st) > MAX_REQUEST then
        codec.send_error(conn, 413, 'request body too large', resp_opts)
        st.dead = true
        conn:close_after_flush('request too large')
        return #data
    end

    pump(conn, st)
    -- The return value is how many bytes were consumed. Anything less than
    -- #data and the channel redelivers the remainder on the next read.
    return #data
end

function handler.on_close(conn, _reason)
    local st = conns[conn]
    if st then
        st.dead = true
        clear_handshake(st)   -- the timer's closure holds conn; drop it or it leaks
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
                password = pw ~= '' and pw or nil, max_packet = MAX_REQUEST }
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

    cfg_log_system('listening on %s://%s:%d (max request %d MiB)',
        https and 'https' or 'http', host, port, cfg_int('MAX_REQUEST_SIZE_MB', 64))
    if not https then
        cfg_log_warn('HTTPS is off: git sends HTTP Basic credentials in clear text on ' ..
                 'every request, so set HTTPS=1 (or front this with TLS) before ' ..
                 'exposing it beyond localhost')
    end
    return true
end

function g_exports.http_close()
    if server then server:close('shutdown'); server = nil end
end
