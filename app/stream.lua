-- app/stream.lua — chunked HTTP responses, for bodies whose length is unknown
-- when the first byte has to go out.
--
-- Exports: stream_begin, stream_write, stream_finish, stream_abort,
--          stream_is_committed, stream_reset,
--          stream_response, stream_response_is_streamed
--
-- Every other response in gitloom is built completely and then handed to the
-- codec, which sets Content-Length. That is impossible for a fetch: the
-- packfile's size is not known until `git upload-pack` has finished producing
-- it, so waiting for the length means waiting for the whole operation. On a
-- large repository the client sits at "Receiving objects: 0%" for the entire
-- run and only then sees bytes move.
--
-- Chunked transfer encoding removes the requirement. Each write is preceded by
-- its own length in hex, and a zero-length chunk ends the body — so the
-- response can start before anything knows how big it will be.
--
-- HOW A HANDLER USES IT
--   stream_begin(ctx.conn, 200, { ['Content-Type'] = '...' })
--   stream_write(ctx.conn, chunk)          -- as many times as needed
--   stream_finish(ctx.conn)
--   return stream_response()                 -- tells the serve loop to send nothing
--
-- The handler runs on a coroutine, so it may yield between writes and be
-- resumed by an event callback. That is exactly what the git streaming path
-- does: the child's stdout arrives through the event loop and each arrival
-- becomes one chunk.

local codec = dofile('scripts/core/share/xhttp_codec.lua')

-- A marker, not a response. The serve loop checks for it and skips
-- send_response, because the handler has already written everything.
local STREAMED = { streamed = true }

function g_exports.stream_response() return STREAMED end

function g_exports.stream_response_is_streamed(resp)
    return type(resp) == 'table' and resp.streamed == true
end

-- ---------------------------------------------------------------------------
-- Which connections have a response committed to them
--
-- Once stream_begin has run, a status line is on the wire and there is no
-- second response to be had: everything written to that connection from then
-- on is framed as part of THIS body. The serve loop has to know, because its
-- error path would otherwise answer a mid-stream failure with a 500 whose
-- status line and headers land INSIDE the packfile — the client then reports a
-- corrupt transfer instead of a failed one, and the 500 is never seen.
--
-- Returning stream_response() is not enough on its own: it only says what the
-- handler MEANT to do, and a handler that raises after its first chunk never
-- returns anything at all.
--
-- Weak keys: a closed connection must not be kept alive by this table.
-- ---------------------------------------------------------------------------

local committed = setmetatable({}, { __mode = 'k' })

function g_exports.stream_is_committed(conn)
    return conn ~= nil and committed[conn] == true
end

-- Forget the commitment on this connection. The serve loop calls it when a
-- request STARTS, not when a stream ends: a failure after stream_finish must
-- still be answered by closing rather than by a second response, while the next
-- request on a keep-alive connection has to start uncommitted.
function g_exports.stream_reset(conn)
    if conn ~= nil then committed[conn] = nil end
end

-- Status line plus headers, with Transfer-Encoding: chunked forced on.
--
-- Content-Length is deliberately impossible to set here: the two are mutually
-- exclusive in HTTP/1.1, and a response carrying both is a request-smuggling
-- primitive rather than merely invalid. Any caller-supplied one is dropped.
function g_exports.stream_begin(conn, status, headers)
    local out = {
        string.format('HTTP/1.1 %d %s\r\n',
            status or 200, codec.STATUS_TEXT[status or 200] or 'OK'),
    }
    for k, v in pairs(headers or {}) do
        local key = codec.clean_header(k)
        if key:lower() ~= 'content-length' and key:lower() ~= 'transfer-encoding' then
            out[#out + 1] = key .. ': ' .. codec.clean_header(v) .. '\r\n'
        end
    end
    out[#out + 1] = 'Transfer-Encoding: chunked\r\n'
    out[#out + 1] = 'Server: gitloom\r\n'
    out[#out + 1] = '\r\n'
    -- Marked BEFORE the send: a header block that only half reached the socket
    -- has still committed the connection, and the recovery is the same.
    committed[conn] = true
    conn:send_raw(table.concat(out))
    return true
end

-- One chunk. A zero-length write is skipped rather than sent, because a
-- zero-length chunk is the END of the body — emitting one mid-stream would
-- truncate the response at that point and the client would report a short
-- packfile rather than an error.
--
-- EVERY send_raw IS CHECKED. A chunk is three writes — length, payload, CRLF —
-- and send_raw fails once the channel's send buffer reaches its cap. Ignoring
-- that produced exactly the failure it sounds like: on a repository big enough
-- to fill the buffer, one of the three writes vanished and the client aborted
-- with "Malformed encoding found in chunked-encoding", while small repositories
-- passed every test. A partial frame is unrecoverable, so this reports the
-- failure and lets the caller abort the connection.
--
-- Returns true, or false plus the reason.
function g_exports.stream_write(conn, data)
    if not data or #data == 0 then return true end

    local ok, err = conn:send_raw(string.format('%x\r\n', #data))
    if not ok then return false, tostring(err or 'send failed') end
    ok, err = conn:send_raw(data)
    if not ok then return false, tostring(err or 'send failed') end
    ok, err = conn:send_raw('\r\n')
    if not ok then return false, tostring(err or 'send failed') end
    return true
end

-- The terminating chunk. It is QUEUED, like every other write — the body is not
-- on the wire when this returns, only in the connection's send buffer, which on
-- a large clone still holds up to STREAM_PAUSE_HIGH_KB. Whoever ends the
-- connection afterwards must let that drain (close_after_flush), because
-- close() discards it and the client sees a truncated packfile.
-- Checked like every other write: if the terminator cannot even be queued the
-- client never learns the body ended, so reporting success here would turn a
-- visible failure into a clone that hangs. Returns true, or false plus why.
function g_exports.stream_finish(conn)
    local ok, err = conn:send_raw('0\r\n\r\n')
    if not ok then return false, tostring(err or 'send failed') end
    return true
end

-- Give up mid-body.
--
-- There is no way to signal an error once the headers have gone out with a 200
-- on them — the status is already committed. Closing without the terminating
-- chunk is the only honest option: the client sees a truncated chunked stream
-- and reports a failed transfer, which is true. Finishing cleanly instead would
-- hand it a short packfile that looks complete.
function g_exports.stream_abort(conn, reason)
    cfg_log_warn('aborting a streamed response: %s', tostring(reason or 'unknown'))
    conn:close('stream aborted')
end
