-- A module whose name extends test/module_ns.lua's. Loaded first, so that
-- module_ns.lua cannot afterwards claim names inside this one's namespace.
function g_exports.module_ns_sub_ok()
    return true
end
