-- Loaded only by test/unit.lua. These deliberately omit `local`: under the
-- app loader they belong to this file's private environment, never to `_G`.
private_value = 41

function private_increment()
    private_value = private_value + 1
    return private_value
end

function g_exports.module_scope_private_api()
    return private_increment()
end

-- A name that did not exist while this file was loading is a typo, not new file
-- state. The loader seals the environment once the chunk returns, so this must
-- raise rather than quietly create it.
function g_exports.module_scope_late_global()
    late_name = 1
end
