-- Loaded under pcall by test/unit_impl.lua. module_ns_sub_* belongs to
-- test/module_ns_sub.lua even though it also satisfies this file's shorter
-- module_ns_ prefix, which is the real case of auth.lua vs auth_ratelimit.lua.
function g_exports.module_ns_sub_stolen()
    return true
end
