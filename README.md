# gitloom

A git hosting service written in Lua on the **xnet2lua** runtime —
<https://github.com/1dao/xnet2lua> — a small C networking core with an embedded
Lua layer. gitloom is the application; xnet2lua is the event loop, thread pool,
TLS, HTTP codec and crypto underneath it.

The runtime binaries for Windows (`bin/xnet.exe`) and Linux (`bin/xnet`) are
committed, so a clone runs with no toolchain. If `bin/` is empty in your
checkout, build them from the upstream repository — see [Upstream](#upstream).

Like gitea — which shells out to `git` in 232 places and requires git ≥ 2.25 —
gitloom does not reimplement git. It drives the real binary and owns the parts
around it: the smart-HTTP transport, the repository model, accounts and access
control, and an API. Packfile negotiation, delta resolution and ref locking stay
where they already work.

**Status: Phase 0.** Clone, fetch and push over HTTP(S) work end to end, with
accounts, access tokens, public/private repositories and a JSON management API.
There is no web UI, no issues and no pull requests yet — see
[docs/ROADMAP.md](docs/ROADMAP.md).

## Quick start

```bash
./start.bat ADMIN_PASSWORD=pick-something-real
```

On Linux use `./start.sh` instead — same arguments.

```bash
curl -u admin:pick-something-real -H 'Content-Type: application/json' \
     -d '{"name":"demo"}' http://127.0.0.1:8686/api/v1/repos
```

```bash
git clone http://127.0.0.1:8686/admin/demo.git
```

Push needs credentials in the URL, a credential helper, or a token:

```bash
git push http://admin:pick-something-real@127.0.0.1:8686/admin/demo.git main
```

Run the end-to-end check — it starts its own instance on a scratch port and
touches nothing in the working tree:

```bash
sh test/smoke.sh
```

## Layout

```
gitloom/
  main.lua               boot: load modules, start the pool, listen
  gitloom.cfg            every knob, with the reasoning next to it
  gitloom.local.cfg      your overrides (gitignored; loaded FIRST, so it wins)
  app/                   the application, one concern per file
    boot.lua             the module convention + the strict-globals guard
    cfg.lua              cfg*/log*
    util.lua             str_*/path_*/file_*/dir_*
    proc.lua             the process pool and the scratch directory
    pkt.lua              git's pkt-line framing
    repo.lua             repository naming, on-disk layout, the index
    git.lua              every invocation of the git binary
    auth.lua             accounts, HTTP Basic, access decisions
    auth_ratelimit.lua   credential-failure backoff
    http.lua             routing, the serve loop, responses
    smart.lua            the git smart-HTTP transport
    api.lua              the JSON management API
  worker/                scripts that run on their own thread and Lua state
    kdf.lua              password hashing, kept off the event loop
  scripts/core/          modules copied from xnet2lua (share/ and server/)
  repos/                 <owner>/<name>.git plus index.json
  data/                  users.json
  tmp/                   request/response staging
  test/smoke.sh
```

## Module convention

gitloom does **not** use `local M = {} … return M`. Each `app/` module installs
its public functions onto `_G` under a per-module prefix, the way a C
translation unit exports a few `modname_verb()` symbols and keeps the rest
`static`:

```lua
-- app/repo.lua
local function normalise(name) … end     -- static: file-local
function repo_dir(owner, name) … end     -- exported
```

Call sites read as `repo_dir(...)`, `git_advertise(...)`, `pkt_line(...)` with
no import block and no aliasing, and there is exactly one instance of every
module regardless of load order.

The cost of a flat namespace is that a mistyped name is a silent `nil` rather
than a load error. `strict_enable()` buys that back: once every module has
loaded, `_G` is locked, and reading an undefined global raises with the
offending name. Creating one afterwards goes through `global(name, value)`. It
is on by default (`STRICT_GLOBALS=1`). The full rules are in
[app/boot.lua](app/boot.lua).

`main.lua`'s load order is the dependency order — a module may call anything
loaded before it at run time, never at load time.

## How a clone works

```
git client ──HTTP──▶ main thread ──RPC──▶ worker thread ──▶ git upload-pack
                     (coroutine                             (blocking)
                      per request)
```

1. `GET /<owner>/<repo>.git/info/refs?service=git-upload-pack` →
   `git upload-pack --stateless-rpc --advertise-refs .`, prefixed with the
   `# service=…` pkt-line the HTTP transport requires.
2. `POST /<owner>/<repo>.git/git-upload-pack` → the request body is staged to a
   file, `git upload-pack --stateless-rpc .` runs with stdin and stdout
   redirected, and the output file is streamed back with `send_file_response`,
   which never materialises the packfile in a Lua string.

The staging exists because this runtime has no bidirectional subprocess: Lua's
`io.popen` is one-shot and unidirectional, so a pipe in both directions is not
available. What that costs and what would replace it is documented at the top of
[app/git.lua](app/git.lua).

Every `git` invocation blocks a worker thread for its duration, so `GIT_WORKERS`
is the number of concurrent clones and pushes that can make progress at once.
The main thread never blocks: a request coroutine yields on the RPC and the
event loop keeps serving.

## Known limits (Phase 0)

| Limit | Detail |
|---|---|
| Push size | The POST body is accumulated in memory and concatenated once before parsing. `MAX_REQUEST_SIZE_MB` (default 64) is a hard ceiling, enforced on the running total as bytes arrive; a larger push is rejected with 413 without ever allocating it. |
| Clone start-up latency | No response streaming: `git` must finish before the first byte moves. A 20 MiB clone measured ~5.6 s on Windows; the bytes themselves are fast, the wait is the disk round trip. |
| Concurrency | Bounded by `GIT_WORKERS`. A large clone occupies one worker for its whole duration, and a client that disconnects does not stop the `git` it started — `GIT_TIMEOUT_SEC` (default 600) is what bounds that. |
| HTTP only | No SSH transport. git speaks HTTP Basic and re-sends the credential on **every** request, so set `HTTPS=1` or front gitloom with TLS before exposing it. |
| Dumb protocol | Not served. `/info/refs` without `?service=` answers 403 rather than 404, so the failure names itself. |
| Storage | Accounts and the repository index are JSON files, not a database. Fine for one process; it is the thing to replace first when that stops being true. |
| Names | Owner and repository names are `[A-Za-z0-9_][A-Za-z0-9._-]*`. That is a security boundary, not a style rule — see the comment in [app/repo.lua](app/repo.lua). |

## Platforms

Developed and tested on Windows. The Linux paths are written and reviewed but
**not yet run on a Linux host** — treat the first deployment as the test.

What was checked in the runtime underneath, and is fine:

- Sockets are marked `FD_CLOEXEC` on listen, connect and accept
  (`xsock.c`), so a listening or client fd is not inherited by the `git`
  children and cannot hold the port open after a restart.
- No `SIGCHLD` handler is installed, so `system()` reaps its children normally.
  `SIGPIPE` is set to `SIG_IGN` in daemon mode and that disposition survives
  `exec`; harmless here, because commands are run with file redirection and
  never in a pipeline.

Before the first Linux run:

1. `chmod +x bin/xnet start.sh test/smoke.sh` — only needed if the exec bit did
   not survive the clone. `test/smoke.sh` chooses the binary by `uname`, not by
   which file is executable, so `bin/xnet.exe` sitting next to it is harmless.
2. `sh test/smoke.sh`. All 27 cases are portable; the credential-helper
   overrides in it are Windows-motivated but harmless elsewhere.
3. `GIT_TIMEOUT_SEC` needs coreutils `timeout` on PATH (`gtimeout` on macOS).
   Without it the setting cannot be enforced and gitloom logs one warning
   rather than failing commands.

## Upstream

The runtime is developed separately at <https://github.com/1dao/xnet2lua>.
`scripts/core/{share,server}/` here is a **copied subset** of that tree, not a
submodule — `xhttp_codec`, `xrouter`, `xfs`, `xmisc`, `xproc`, `xproc_worker`,
`xmysql`, `xmysql_worker`. Editing one of those files in either repository
diverges the two silently, so a fix in one has to be copied to the other and
both test suites re-run (`sh test/smoke.sh` here, `bin/xnet tests/lua/xproc_test.lua`
there).

`bin/xnet` and `bin/xnet.exe` are builds of that runtime, committed here so a
clone runs with no toolchain. Replace them wholesale when the runtime moves.

`.gitattributes` pins the whole tree to LF. That is load-bearing, not
housekeeping: a CRLF shebang makes Linux report `bad interpreter: No such file
or directory`, which names the shell rather than the line ending and reads as a
missing `/bin/sh`.

## API

| | |
|---|---|
| `GET /api/v1/version` | |
| `GET /api/v1/repos` | repositories visible to the caller |
| `POST /api/v1/repos` | `{name, description?, private?, owner?, default_branch?}` |
| `GET /api/v1/repos/:owner/:name` | detail, including refs and `empty` |
| `DELETE /api/v1/repos/:owner/:name` | |
| `GET /api/v1/users` | administrator only |
| `POST /api/v1/users` | administrator only |
| `POST /api/v1/user/tokens` | issue an access token; shown once |

Authentication is HTTP Basic, with either a password or an access token as the
password field.
