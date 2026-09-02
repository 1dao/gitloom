-- app/web.lua -- the small same-origin repository browser.
--
-- The browser is intentionally a static SPA. It talks to the JSON API already
-- exposed by api.lua, so there is no second auth/session implementation and no
-- server-side template tree to maintain. Static routes are registered one by
-- one instead of turning an arbitrary URL into a filesystem path: the browser
-- surface is three known files, and this makes traversal impossible by
-- construction.
--
-- The two assets are addressed by a digest of their own bytes -- /app.js?v=...
-- -- so they can be cached for a year while an upgrade still takes effect on
-- the next page load: index.html is never cached and carries the digest of the
-- assets it expects. Without that the two are cached independently, and a
-- client can run five-minute-old JavaScript against freshly deployed HTML.
--
-- Exports: web_install, __web_serve

local xutils = require('xutils')

local INDEX = 'index.html'

local FILES = {
    { route = '/',        name = INDEX,     type = 'text/html; charset=utf-8' },
    { route = '/app.css', name = 'app.css', type = 'text/css; charset=utf-8' },
    { route = '/app.js',  name = 'app.js',  type = 'application/javascript; charset=utf-8' },
}

local STATIC_ROOT   = 'web'
local ASSET_VERSION = 'dev'

local SECURITY = {
    ['X-Content-Type-Options'] = 'nosniff',
    ['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; " ..
        "style-src 'self'; img-src 'self' data:; connect-src 'self'; " ..
        "base-uri 'none'; frame-ancestors 'none'",
}

local function headers_with(extra)
    local h = {}
    for k, v in pairs(SECURITY) do h[k] = v end
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

-- A digest of the asset bytes rather than a version number: it changes when and
-- only when the browser changes, so a release that touches nothing here leaves
-- every cached copy valid.
local function asset_version(root)
    local parts = {}
    for _, file in ipairs(FILES) do
        if file.name ~= INDEX then
            parts[#parts + 1] = util_file_read(util_path_join(root, file.name)) or ''
        end
    end
    return xutils.sha256_hex(table.concat(parts, '\0')):sub(1, 12)
end

local function serve(root, version, file, query)
    local path = util_path_join(root, file.name)

    -- index.html is rendered rather than streamed: it is the one file that has
    -- to carry the asset digest, and at a few KiB the string costs nothing.
    if file.name == INDEX then
        local html = util_file_read(path)
        if not html then
            return http_response_error(503, 'web assets are not installed')
        end
        return {
            status = 200,
            body = (html:gsub('__ASSET_VERSION__', version)),
            headers = headers_with({
                ['Content-Type']  = file.type,
                ['Cache-Control'] = 'no-cache',
            }),
        }
    end

    if not util_file_exists(path) then
        return http_response_error(503, 'web assets are not installed')
    end
    -- Only the stamped URL is immutable. A bare /app.js -- what a test or a
    -- curl asks for -- must not be cached for a year under a name that will
    -- mean something else after the next change.
    local stamped = tostring((query or {}).v or '') == version
    return http_response_file(path, file.type, headers_with({
        ['Cache-Control'] = stamped
            and 'public, max-age=31536000, immutable' or 'no-cache',
    }))
end

function g_exports.web_install()
    STATIC_ROOT = cfg_get('WEB_ROOT', 'web')

    -- Checked at boot rather than on the first request: a wrong WEB_ROOT is a
    -- deployment mistake, and learning about it from a visitor's 503 is
    -- learning about it late.
    local missing = {}
    for _, file in ipairs(FILES) do
        if not util_file_exists(util_path_join(STATIC_ROOT, file.name)) then
            missing[#missing + 1] = file.name
        end
    end
    ASSET_VERSION = asset_version(STATIC_ROOT)

    for _, file in ipairs(FILES) do
        http_get(file.route, function(req)
            return serve(STATIC_ROOT, ASSET_VERSION, file, req.query)
        end)
    end

    if #missing > 0 then
        cfg_log_warn('repository browser: %s missing under %s; the browser will answer 503',
            table.concat(missing, ', '), STATIC_ROOT)
    else
        cfg_log_info('repository browser installed from %s (assets %s)',
            STATIC_ROOT, ASSET_VERSION)
    end
end

-- Test hook: build one route's response against an arbitrary root, so the
-- missing-assets path can be exercised without moving the real web/ aside.
function g_exports.__web_serve(root, route, query)
    for _, file in ipairs(FILES) do
        if file.route == route then
            return serve(root, asset_version(root), file, query)
        end
    end
    return nil
end
