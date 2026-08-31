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

```bash
bin/xnet.exe test/unit.lua
```

## Layout

```
gitloom/
  main.lua               boot: load modules, start the pool, listen
  gitloom.cfg            every knob, with the reasoning next to it
  gitloom.local.cfg      your overrides (gitignored; loaded FIRST, so it wins)
  app/                   the application, one concern per file
    boot.lua             isolated module loader + g_exports registry
    cfg.lua              cfg_*
    util.lua             util_*
    proc.lua             the process pool and the scratch directory
    pkt.lua              git's pkt-line framing
    repo.lua             repository naming, on-disk layout, the index
    git.lua              every invocation of the git binary
    auth.lua             accounts, HTTP Basic, access decisions
    auth_ratelimit.lua   credential-failure backoff
    http.lua             routing, the serve loop, responses
    stream.lua           chunked responses, for bodies of unknown length
    browse.lua           reading repository contents (trees, blobs, log)
    smart.lua            the git smart-HTTP transport
    api.lua              the JSON management API
  worker/                scripts that run on their own thread and Lua state
    kdf.lua              password hashing, kept off the event loop
  scripts/core/          modules copied from xnet2lua (share/ and server/)
  repos/                 <owner>/<name>.git plus index.json
  data/                  users.json
  tmp/                   request/response staging
  test/smoke.sh          end-to-end, against a real git client
  test/unit.lua          pure-Lua checks that need no server
```

## Module convention

gitloom exposes one application-owned global, `g_exports`. Every `app/` file is
loaded into a separate environment, so its ordinary top-level names remain
private to that file. Only assignments through `g_exports` form the public API,
similar to a C translation unit with an explicit export table:

```lua
-- app/repo.lua
local function normalise(name) … end               -- lexical/file-private
cache = {}                                         -- environment/file-private
function g_exports.repo_dir(owner, name) … end     -- exported
```

Every application file, including the callable part of `main.lua`, resolves API
names through `g_exports`, so call sites stay direct: `repo_dir(...)`,
`git_advertise(...)`, and `pkt_line(...)`. Those short names are environment
lookups, not root globals. The export registry is a proxy: a second module
cannot silently replace an existing API, and the loader rejects loading the
same app file twice.

Export names are checked while the file loads and must follow
`module_function`, where `module` is the lowercase filename without `.lua`.
The function description may contain more underscores. For example,
`app/stream.lua` may export `stream_is_committed` and
`stream_response_is_streamed`; `app/auth_ratelimit.lua` may export
`auth_ratelimit_record_failure`. A mismatched prefix is a load error.

The loader supports Lua 5.1 with `loadfile` + `setfenv`, and Lua 5.2+ with
`loadfile(..., env)`. An unresolved name in a module raises with that module's
path. `STRICT_GLOBALS=1` additionally locks the root `_G` after startup; module
isolation and duplicate-export checks remain active even when that development
guard is disabled. The full rules are in [app/boot.lua](app/boot.lua).

Calling an earlier export by its short name still reads from `g_exports`; no
individual API function is copied onto the root `_G`. Only the declaration site
uses the registry explicitly: `function g_exports.module_function(...)`.

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

Every staged `git` invocation blocks a worker thread for its duration, so
`GIT_WORKERS` is the number of concurrent clones and pushes that can make
progress at once. The streaming path does not use the pool — it spawns its child
directly — so it carries its own cap, `GIT_STREAM_MAX`, and falls back to
staging once that is reached. The main thread never blocks either way: a request
coroutine yields on the RPC (or on the child's stdout) and the event loop keeps
serving.

## Known limits (Phase 0)

| Limit | Detail |
|---|---|
| Push size | The POST body is accumulated in memory and concatenated once before parsing. `MAX_REQUEST_SIZE_MB` (default 64) is a hard ceiling, enforced on the running total as bytes arrive; a larger push is rejected with 413 without ever allocating it. |
| Clone start-up latency | Windows only. There the response waits for `git` to finish, because Content-Length is unknowable before then — a 20 MiB clone measured ~5.6 s. On Linux the streaming path sends each chunk as git produces it (`GIT_STREAM=auto`). |
| Concurrency | Bounded, by two counters. A staged clone or push occupies one of `GIT_WORKERS` pool threads for its whole duration; a streamed one takes one of `GIT_STREAM_MAX` slots (default `GIT_WORKERS`) and falls back to staging when they are all busy — so an instance runs at most `GIT_STREAM_MAX + GIT_WORKERS` git processes. A client that disconnects does not stop the `git` it started; `GIT_TIMEOUT_SEC` (default 600) is what bounds that. |
| HTTP only | No SSH transport. git speaks HTTP Basic and re-sends the credential on **every** request, so set `HTTPS=1` or front gitloom with TLS before exposing it. |
| Dumb protocol | Not served. `/info/refs` without `?service=` answers 403 rather than 404, so the failure names itself. |
| Storage | Accounts and the repository index are JSON files, not a database. Fine for one process; it is the thing to replace first when that stops being true. |
| Names | Owner and repository names are `[A-Za-z0-9_][A-Za-z0-9._-]*`. That is a security boundary, not a style rule — see the comment in [app/repo.lua](app/repo.lua). |

## Platforms

Linux is the deployment target and is where the streaming transport runs;
Windows is supported for development and falls back to file staging.

Verified on both: Arch Linux (gcc 16.2.1, git 2.55) and Windows (MinGW, git
2.52). `test/smoke.sh` passes 75/75 on each.

What was checked in the runtime underneath, and is fine:

- Sockets are marked `FD_CLOEXEC` on listen, connect and accept
  (`xsock.c`), so a listening or client fd is not inherited by the `git`
  children and cannot hold the port open after a restart.
- No `SIGCHLD` handler is installed, so `system()` reaps its children normally.
  `SIGPIPE` is set to `SIG_IGN` in daemon mode and that disposition survives
  `exec`; harmless here, because commands are run with file redirection and
  never in a pipeline.

On Linux:

1. `chmod +x bin/xnet start.sh test/smoke.sh` — only needed if the exec bit did
   not survive the clone. `test/smoke.sh` chooses the binary by `uname`, not by
   which file is executable, so `bin/xnet.exe` sitting next to it is harmless.
2. The streaming transport needs a runtime built with `WITH_XPROC=1`. A stock
   build has no `xproc` module, and gitloom then stages through files and says
   so at boot rather than failing.
3. `GIT_TIMEOUT_SEC` needs coreutils `timeout` on PATH (`gtimeout` on macOS).
   Without it the setting cannot be enforced and gitloom logs one warning
   rather than failing commands.

Which transport is in use is logged once at startup:

```
smart-HTTP transport: streaming (pipes via xproc)
smart-HTTP transport: file staging (this runtime has no xproc module)
```

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

Browsing a repository's contents:

| | |
|---|---|
| `GET /api/v1/repos/:owner/:name/branches` | |
| `GET /api/v1/repos/:owner/:name/tags` | |
| `GET .../commits` | `?ref=` `&limit=` `&skip=` `&path=` |
| `GET .../commits/:ref` | one commit, with the files it touched |
| `GET .../tree/:ref` and `.../tree/:ref/<path>` | directory listing, directories first |
| `GET .../raw/:ref/<path>` | file contents |

Authentication is HTTP Basic, with either a password or an access token as the
password field. Browsing obeys the same visibility rule as the transport: a
private repository is 404 to anyone who may not read it.

`:ref` is a branch, tag, or object id. A branch containing a slash has to be
percent-encoded (`feature%2Fwork`), because it occupies one URL segment.
Omitting `?ref=` uses the repository's default branch.

### Handling refs and paths

Both reach a `git` command line, so both are treated as hostile. A ref is
resolved to an object id by `rev-parse` **once**, and only the hex id travels
any further — a ref beginning with `-` is otherwise read by git as an option,
which is the shape behind several real CVEs in git-hosting front ends. Paths
are percent-decoded first and validated second (`%2e%2e` is `..`), and every
command that takes one is given `--` before it. The reasoning is written out at
the top of [app/browse.lua](app/browse.lua).

Raw file responses never carry a renderable content type unless the extension is
on a short allowlist, and always carry `nosniff` and a sandbox CSP. A repository
can contain an `.html` or `.svg` file, and serving that inline would make the
gitloom origin attacker-controlled script — GitHub uses a separate domain for
raw content for the same reason; gitloom has one origin, so it refuses instead.
