-- Intentionally violates the module_function export convention. unit.lua
-- loads this file under pcall to verify that boot.lua rejects it.
function g_exports.wrong_prefix()
end
