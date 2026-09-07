-- app/protect.lua — what a push is not allowed to do.
--
-- Exports: protect_setup, protect_hooks_dir, protect_refs_for
--
-- The policy lives here; the enforcement lives in `hooks/update`, which git
-- runs once per ref while receive-pack holds the new objects. The comment at
-- the top of that file explains why it has to be a hook rather than a check
-- gitloom makes before spawning git — in one line, because deciding whether an
-- update is a fast-forward needs objects that have not been unpacked yet.
--
-- What this module owns is the answer to two questions: where the hook
-- directory is, and which refs a given repository guards. It reaches the hook
-- as an environment variable on the receive-pack child, which is the only
-- channel there is — the hook is a separate process that knows nothing but its
-- three arguments and its environment.

local xutils = require('xutils')

local hooks_abs = nil     -- resolved once by protect_setup

-- gitloom's own install directory, as an ABSOLUTE path.
--
-- It has to be absolute because git runs a hook with the REPOSITORY as its
-- working directory, so a relative core.hooksPath would be looked for inside
-- the repository and quietly found to be missing — and a protection feature
-- that silently does nothing is worse than one that is off.
--
-- Lua has no getcwd, so the runtime grew one: `xutils.cwd()`, in xnet2lua's
-- xlua/lua_xutils.c.
--
-- This was a shell probe first — `pwd`, or `cd` on Windows, through the process
-- pool, which is what xproc_worker.lua does for its own redirect paths. Two
-- things were wrong with it. It spawns a process for a value the OS hands over
-- for free. And on Windows its correctness depended on something nobody should
-- have to reason about: this process's own ANSI calls speak UTF-8 because of the
-- manifest in xnet.rc, but a CHILD writes its output in the console code page it
-- inherits, which is the system OEM page unless something changed it. Measured
-- on the development machine, ACP and OEMCP are both 936 while an interactive
-- shell had already switched its console to 65001 — so the probe round-tripped a
-- CJK install path there and would not have under the service. An answer that
-- depends on who started you is worse than one that is simply wrong.
--
-- A C call has neither problem, and needs no coroutine.
local function process_cwd()
    local out, err = xutils.cwd()
    if not out or out == '' then
        return nil, 'could not read the working directory: ' .. tostring(err or 'empty')
    end
    return util_str_trim(out)
end

-- Called from boot_async. Resolves the hook directory and refuses to continue
-- when protection is on and the hook is not there.
--
-- Refusing to boot rather than warning: the failure this guards against is an
-- instance that reports itself healthy while every protected branch is open to
-- a force-push. An operator who wants to run without it can say so —
-- PROTECT_DEFAULT_BRANCH=off — and that is a decision rather than an accident.
--
-- Returns true, or nil plus a message.
function g_exports.protect_setup()
    local dir = cfg_get('HOOKS_DIR', 'hooks')

    if not util_path_is_abs(dir) then
        local cwd, cerr = process_cwd()
        if not cwd then return nil, cerr end
        dir = util_path_join(cwd, dir)
    end

    local script = util_path_join(dir, 'update')
    if not util_file_exists(script) then
        return nil, 'no hook at ' .. script
    end

    hooks_abs = dir
    return true
end

-- Where receive-pack should look for hooks, or nil when nothing is protected
-- and git should be left with its own default.
function g_exports.protect_hooks_dir()
    if not cfg_bool('PROTECT_DEFAULT_BRANCH', true) then return nil end
    return hooks_abs
end

-- The refs `rec` guards, space-separated, or nil for none.
--
-- Per repository rather than per instance even though the rule is currently one
-- setting: the default branch is a property of the record, so `main` here and
-- `trunk` next door are already handled, and a stored list of protected
-- patterns would replace this function rather than the shape around it.
function g_exports.protect_refs_for(rec)
    if not hooks_abs then return nil end
    if not cfg_bool('PROTECT_DEFAULT_BRANCH', true) then return nil end

    local branch = rec and rec.default_branch
    if type(branch) ~= 'string' or branch == '' then return nil end
    -- A ref name with a space in it cannot be expressed in a space-separated
    -- list, and git forbids one anyway; refusing here keeps the hook's
    -- word-boundary match honest rather than trusting that it never happens.
    if branch:find('%s') then return nil end

    return 'refs/heads/' .. branch
end
