-- Git LFS Basic transfers. Objects live inside their owning bare repository:
-- no global hash lookup can disclose another repository's private content, and
-- repository rename/delete/backup carry the objects along with the Git data.
-- SHA-256 runs in the process pool through OpenSSL, never by loading a large
-- file into a Lua string. Only verified files are renamed into the object tree.
local xutils = require('xutils')
local MEDIA = 'application/vnd.git-lfs+json'

local function enabled() return cfg_bool('LFS_ENABLED', true) end
local function ceiling() return math.max(1, cfg_int('LFS_MAX_OBJECT_MB', 1024)) * 1048576 end
local function valid_oid(oid)
    return type(oid) == 'string' and #oid == 64 and oid:match('^[0-9a-f]+$') ~= nil
end
local function valid_size(size)
    return type(size) == 'number' and size >= 0 and size <= 9007199254740991
        and size == math.floor(size)
end
local function response(status, value)
    local r = http_response_json(status, value)
    r.headers['Content-Type'] = MEDIA
    r.headers['Cache-Control'] = 'no-store'
    return r
end
local function failure(status, message) return response(status, { message = message }) end
local function json_body(req)
    local ctype = (req.headers['content-type'] or ''):lower():match('^%s*([^; ]+)')
    if ctype ~= MEDIA then return nil, failure(415, 'expected ' .. MEDIA) end
    if #(req.body or '') > 1048576 then return nil, failure(413, 'batch body too large') end
    local ok, value = pcall(xutils.json_unpack, req.body or '')
    if not ok or type(value) ~= 'table' then return nil, failure(400, 'invalid JSON') end
    return value
end
local function object_path(dir, oid)
    return util_path_join(dir, 'lfs', 'objects', oid:sub(1, 2), oid:sub(3, 4), oid)
end
local function digest(path)
    local r = proc_exec({ argv = { cfg_get('LFS_OPENSSL_BIN', 'openssl'),
        'dgst', '-sha256', path }, capture_stdout = true, capture_stderr = true,
        max_capture = 4096, timeout_ms = cfg_int('LFS_HASH_TIMEOUT_SEC', 300) * 1000 })
    if not r or not r.ok then return nil end
    return util_str_trim(r.stdout or ''):match('([0-9a-f]+)$')
end

local function base_url(req, ctx, prefix)
    -- An explicit URL also supports a reverse proxy mounted under a subpath.
    local base = cfg_get('LFS_PUBLIC_URL', ''):gsub('/+$', '')
    if base == '' then
        local host = req.headers['host'] or ''
        if host == '' or host:find('[^%w%.:%[%]%-]') then return nil end
        base = (ctx.https and 'https://' or 'http://') .. host
    end
    return base .. prefix .. '/info/lfs/objects/'
end

local function batch(req, ctx, prefix)
    local data, err = json_body(req)
    if not data then return err end
    if data.operation ~= 'upload' and data.operation ~= 'download' then
        return failure(400, 'operation must be upload or download')
    end
    local rec, dir = smart_authorise(req, prefix, data.operation == 'upload')
    if not rec then return dir end
    if data.hash_algo ~= nil and data.hash_algo ~= 'sha256' then
        return failure(409, 'only sha256 is supported')
    end
    if data.transfers ~= nil then
        local basic = false
        if type(data.transfers) ~= 'table' then return failure(400, 'invalid transfers') end
        for _, transfer in ipairs(data.transfers) do if transfer == 'basic' then basic = true end end
        if not basic then return failure(422, 'only basic transfers are supported') end
    end
    if type(data.objects) ~= 'table' or #data.objects > 100 then
        return failure(400, 'objects must be an array of at most 100 entries')
    end
    for key in pairs(data.objects) do
        if type(key) ~= 'number' or key < 1 or key > #data.objects or key ~= math.floor(key) then
            return failure(400, 'objects must be an array')
        end
    end
    local base = base_url(req, ctx, prefix)
    if not base then return failure(400, 'invalid Host header') end
    local objects = {}
    for _, obj in ipairs(data.objects) do
        if type(obj) ~= 'table' or not valid_oid(obj.oid) or not valid_size(obj.size) then
            return failure(422, 'objects require a lowercase SHA-256 oid and integer size')
        end
        local item = { oid = obj.oid, size = obj.size }
        local size = util_file_size(object_path(dir, obj.oid))
        if obj.size > ceiling() then
            item.error = { code = 413, message = 'object exceeds LFS_MAX_OBJECT_MB' }
        elseif size ~= nil and size ~= obj.size then
            item.error = { code = 422, message = 'object size mismatch' }
        elseif data.operation == 'download' then
            if size == nil then item.error = { code = 404, message = 'object not found' }
            else item.actions = { download = { href = base .. obj.oid } } end
        elseif size == nil then
            item.actions = {
                upload = { href = base .. obj.oid .. '?size=' .. string.format('%.0f', obj.size) },
                verify = { href = base .. obj.oid .. '/verify' },
            }
        end
        objects[#objects + 1] = item
    end
    return response(200, { transfer = 'basic', hash_algo = 'sha256', objects = util_json_array(objects) })
end

local function upload(req, prefix, dir, oid)
    local text = req.query and req.query.size
    local size = type(text) == 'string' and text:match('^%d+$') and tonumber(text) or nil
    if not valid_size(size) then return failure(422, 'upload size is required') end
    if size > ceiling() then return failure(413, 'object exceeds LFS_MAX_OBJECT_MB') end
    local encoding = (req.headers['content-encoding'] or 'identity'):lower()
    if encoding ~= 'identity' then return failure(415, 'encoded uploads are unsupported') end
    if req.content_length and req.content_length ~= size then return failure(422, 'size mismatch') end
    local tmpdir = util_path_join(dir, 'lfs', 'tmp')
    if not util_dir_make(tmpdir) then return failure(500, 'cannot create upload directory') end
    local tmp = util_path_join(tmpdir, util_rand_hex(16))
    local f = io.open(tmp, 'wb')
    if not f then return failure(500, 'cannot stage upload') end
    local total = 0
    local function write(piece)
        total = total + #piece
        if total > size then return nil, 'size mismatch' end
        return f:write(piece)
    end
    -- Always close and remove staging files, including coroutine/IO failures.
    local ok, why = pcall(function()
        if req.body_stream then
            while true do
                local piece, err = req.body_stream.read()
                if not piece then if err then error(err, 0) end; break end
                local wrote, werr = write(piece)
                if not wrote then error(werr, 0) end
            end
        else
            local wrote, werr = write(req.body or '')
            if not wrote then error(werr, 0) end
        end
    end)
    local closed = f:close()
    if not ok or total ~= size or not closed then
        util_file_remove(tmp)
        return failure(422, 'incomplete upload or size mismatch')
    end
    local hok, hash = pcall(digest, tmp)
    if not hok or not hash then
        util_file_remove(tmp)
        return failure(500, 'object hash verification failed')
    end
    if hash ~= oid then util_file_remove(tmp); return failure(422, 'SHA-256 mismatch') end
    -- Authentication and repository identity may change while receiving/hashing.
    local rec, current_dir = smart_authorise(req, prefix, true)
    if not rec or current_dir ~= dir then
        util_file_remove(tmp)
        return rec and failure(409, 'repository moved during upload') or current_dir
    end
    local target = object_path(dir, oid)
    if util_file_size(target) == size then util_file_remove(tmp); return response(200, {}) end
    if not util_dir_make(util_path_join(dir, 'lfs', 'objects', oid:sub(1, 2), oid:sub(3, 4))) then
        util_file_remove(tmp); return failure(500, 'cannot create object directory')
    end
    local moved = os.rename(tmp, target)
    if not moved then util_file_remove(tmp); return failure(500, 'cannot store object') end
    return response(200, {})
end

local function dispatch(req, ctx)
    local prefix, rest = (req.path or ''):match('^(.-)/info/lfs/(.*)$')
    if not prefix then return nil end
    if not enabled() then return failure(404, 'LFS is disabled') end
    if rest == 'objects/batch' then
        if req.method ~= 'POST' then return failure(405, 'POST required') end
        return batch(req, ctx, prefix)
    end
    local oid, verify = rest:match('^objects/([^/]+)(.*)$')
    if not valid_oid(oid) or (verify ~= '' and verify ~= '/verify') then
        return failure(404, 'LFS endpoint not found')
    end
    local writing = req.method == 'PUT' or verify == '/verify'
    local rec, dir = smart_authorise(req, prefix, writing)
    if not rec then return dir end
    if verify == '/verify' then
        if req.method ~= 'POST' then return failure(405, 'POST required') end
        local data, err = json_body(req)
        if not data then return err end
        if data.oid ~= oid or not valid_size(data.size) then return failure(422, 'invalid object') end
        if util_file_size(object_path(dir, oid)) ~= data.size then return failure(404, 'object not found') end
        return response(200, {})
    end
    if req.method == 'PUT' then return upload(req, prefix, dir, oid) end
    if req.method ~= 'GET' and req.method ~= 'HEAD' then return failure(405, 'GET or PUT required') end
    local path = object_path(dir, oid)
    if util_file_size(path) == nil then return failure(404, 'object not found') end
    return http_response_file(path, 'application/octet-stream', {
        ['Cache-Control'] = 'private, no-store', ['X-Content-Type-Options'] = 'nosniff',
        ['Content-Disposition'] = 'attachment', ['Content-Security-Policy'] = "sandbox; default-src 'none'",
    })
end

function g_exports.lfs_install()
    http_fallback(dispatch)
    http_body_stream(function(head)
        if not enabled() or util_is_windows or head.method ~= 'PUT' then return false end
        if not (head.path or ''):match('/info/lfs/objects/[0-9a-f]+$') then return false end
        return true, ceiling()
    end)
end

function g_exports.lfs_setup()
    if not enabled() then return true end
    local tmp = proc_tmp_path('lfs-probe')
    if not util_file_write(tmp, 'abc') then return nil, 'cannot stage hash probe' end
    local ok, hash = pcall(digest, tmp)
    util_file_remove(tmp)
    if not ok or hash ~= xutils.sha256_hex('abc') then
        return nil, 'OpenSSL SHA-256 unavailable; set LFS_OPENSSL_BIN or LFS_ENABLED=0'
    end
    -- Only incomplete files, never stored objects, are removed on restart.
    for _, rec in ipairs(repo_list()) do
        local dir = util_path_join(repo_dir_of(rec), 'lfs', 'tmp')
        for _, entry in ipairs(xutils.list_dir(dir) or {}) do
            if not entry.dir then util_file_remove(util_path_join(dir, entry.name)) end
        end
    end
    return true
end

g_exports.__lfs_valid_oid = valid_oid
g_exports.__lfs_valid_size = valid_size
