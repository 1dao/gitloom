-- app/pkt.lua — git's pkt-line framing.
--
-- Exports: pkt_line, pkt_flush, pkt_delim, pkt_encode, pkt_parse, pkt_service_header
--
-- pkt-line is the only framing in the git wire protocol: a 4-byte lowercase-hex
-- length that INCLUDES the four length bytes, then that many bytes of payload.
-- Three lengths are special and carry no payload:
--
--   0000  flush-pkt    end of a section / end of the stream
--   0001  delim-pkt    section separator (protocol v2 only)
--   0002  response-end (protocol v2 stateless sideband)
--
-- gitloom hands the body of a smart-HTTP request straight to `git` and does not
-- have to understand most of it. What it DOES have to produce itself is the
-- service header on GET /info/refs, which git's --advertise-refs output omits
-- because in the native protocol the daemon has already sent it.

local MAX_PAYLOAD = 65516   -- 65520 byte packet - 4 byte length prefix

-- One pkt-line carrying `payload`. Callers that need a trailing newline (git's
-- text lines all have one) must include it themselves — it counts toward the
-- length.
function pkt_line(payload)
    payload = tostring(payload or '')
    if #payload > MAX_PAYLOAD then
        error(string.format('pkt_line: payload too long (%d > %d)', #payload, MAX_PAYLOAD), 2)
    end
    return string.format('%04x', #payload + 4) .. payload
end

function pkt_flush() return '0000' end
function pkt_delim() return '0001' end

-- Encode a list of payloads, appending a flush-pkt.
function pkt_encode(lines)
    local out = {}
    for _, l in ipairs(lines or {}) do out[#out + 1] = pkt_line(l) end
    out[#out + 1] = pkt_flush()
    return table.concat(out)
end

-- Decode a pkt-line stream into { {kind, payload}, ... } where kind is
-- 'data' | 'flush' | 'delim' | 'response-end'. Returns nil plus a message on a
-- malformed stream.
--
-- Only used for inspection — logging what a client asked for, and reading the
-- ref updates out of a receive-pack request so a push can be reported. The
-- bytes themselves always reach git unmodified.
function pkt_parse(data)
    local out, pos, n = {}, 1, #data
    while pos <= n do
        if pos + 3 > n then return nil, 'truncated length prefix' end
        local hex = data:sub(pos, pos + 3)
        local len = tonumber(hex, 16)
        if not len then return nil, 'bad length prefix ' .. hex end
        if len == 0 then
            out[#out + 1] = { kind = 'flush' }
            pos = pos + 4
        elseif len == 1 then
            out[#out + 1] = { kind = 'delim' }
            pos = pos + 4
        elseif len == 2 then
            out[#out + 1] = { kind = 'response-end' }
            pos = pos + 4
        elseif len < 4 then
            return nil, 'invalid length ' .. len
        else
            local stop = pos + len - 1
            if stop > n then return nil, 'truncated payload' end
            out[#out + 1] = { kind = 'data', payload = data:sub(pos + 4, stop) }
            pos = stop + 1
        end
    end
    return out
end

-- The advertisement preamble a smart-HTTP client expects ahead of git's
-- --advertise-refs output:
--
--   001e# service=git-upload-pack\n
--   0000
--
-- Sent for EVERY protocol version, v2 included. git's --advertise-refs never
-- emits it (in the native protocol the daemon already has), and the HTTP
-- transport treats its absence as "not a smart server" and falls back to the
-- dumb protocol — which we do not serve, so the clone fails. Matches what
-- gitea's GetInfoRefs does unconditionally.
function pkt_service_header(service)
    return pkt_line('# service=' .. service .. '\n') .. pkt_flush()
end
