-- Loaded under pcall by test/unit_impl.lua. It registers one export and then
-- fails, so the loader has to leave nothing behind: a surviving half of a
-- module makes the next attempt report 'duplicate export' instead of this.
function g_exports.module_partial_export_first()
    return true
end

error('deliberate failure half-way through the module')
