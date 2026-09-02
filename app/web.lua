-- app/web.lua -- the small same-origin repository browser.
--
-- The browser is intentionally a static SPA. It talks to the JSON API already
-- exposed by api.lua, so there is no second auth/session implementation and no
-- server-side template tree to maintain. Static routes are registered one by
-- one instead of turning an arbitrary URL into a filesystem path: the browser
-- surface is three known files, and this makes traversal impossible by
-- construction.
--
-- Exports: web_install

local STATIC_ROOT = nil

local FILES = {
    { route = '/',       name = 'index.html', type = 'text/html; charset=utf-8' },
    { route = '/app.css', name = 'app.css',     type = 'text/css; charset=utf-8' },
    { route = '/app.js',  name = 'app.js',      type = 'application/javascript; charset=utf-8' },
}

local function static_response(file)
    local path = util_path_join(STATIC_ROOT, file.name)
    if not util_file_exists(path) then
        return http_response_error(503, 'web assets are not installed')
    end
    return http_response_file(path, file.type, {
        ['Cache-Control'] = file.name == 'index.html'
            and 'no-cache' or 'public, max-age=300',
        ['X-Content-Type-Options'] = 'nosniff',
        ['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; " ..
            "style-src 'self'; img-src 'self' data:; connect-src 'self'; " ..
            "base-uri 'none'; frame-ancestors 'none'",
    })
end

function g_exports.web_install()
    STATIC_ROOT = cfg_get('WEB_ROOT', 'web')
    for _, file in ipairs(FILES) do
        local route, entry = file.route, file
        http_get(route, function()
            return static_response(entry)
        end)
    end
    cfg_log_info('repository browser installed from %s', STATIC_ROOT)
end
