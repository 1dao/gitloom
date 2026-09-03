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

**Status: Phase 2 (browser slice).** Clone, fetch and push over HTTP(S) work end
to end, with accounts, access tokens, public/private repositories, a JSON
management API and a same-origin repository browser. The browser covers the
repository list, branches, tree, raw files, commit history and bounded diffs.
Issues and pull requests are not implemented yet — see
[docs/ROADMAP.md](docs/ROADMAP.md).

## Quick start

```bash
./start.bat ADMIN_PASSWORD=pick-something-real
```

On Linux use `./start.sh` instead — same arguments.

Open <http://127.0.0.1:8686/> for the repository browser. Logging in exchanges
the password for an access token that expires after twelve hours; only the
token is kept, only in the current browser tab, and logging out revokes it. The
password itself is never stored.

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
    db.lua               the MySQL connection, and every SQL literal
    migrate.lua          the schema, and the runner that applies it
    store.lua            accounts and repositories: JSON files or MySQL
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
    web.lua              static files for the repository browser
  web/                   same-origin browser (index.html, app.css, app.js)
  worker/                scripts that run on their own thread and Lua state
    kdf.lua              password hashing, kept off the event loop
  scripts/core/          modules copied from xnet2lua (share/ and server/)
  repos/                 <owner>/<name>.git plus index.json (DB_DRIVER=none)
  data/                  users.json (DB_DRIVER=none)
  tmp/                   request/response staging
  test/smoke.sh          end-to-end, against a real git client
  test/unit.lua          pure-Lua checks that need no server
  test/dbreset.lua       empties the test database, for the MySQL run
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
2. `POST /<owner>/<repo>.git/git-upload-pack` → `git upload-pack
   --stateless-rpc .`, run one of two ways.

**Streaming** (Linux, `GIT_STREAM=auto`, a runtime with `xproc`). The child is
spawned on socketpairs the event loop adopts as ordinary channels. The request
is dispatched as soon as its headers are in and its body goes to the child's
stdin as it arrives; the child's stdout goes back out as chunked HTTP as it is
produced. Nothing touches the disk and nothing is held whole in memory, in
either direction — so neither the push nor the clone has a size ceiling, and the
client sees bytes as soon as git emits them.

**File staging** (Windows, `GIT_STREAM=off`, or every streaming slot busy). The
body is written to a scratch file, git runs with stdin and stdout redirected,
and the output file is streamed back with `send_file_response`, which never
materialises the packfile in a Lua string. Content-Length cannot be known before
git finishes, so the client waits for the whole operation before the first byte
moves, and a buffered body is bounded by `MAX_REQUEST_SIZE_MB`.

The staging path exists because plain Lua has no bidirectional subprocess:
`io.popen` is one-shot and unidirectional, so a pipe in both directions is not
available without the C binding that the streaming path uses. What that costs is
documented at the top of [app/git.lua](app/git.lua).

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
| Push size | Unbounded on Linux. A smart-HTTP POST is dispatched as soon as its headers arrive and its body goes to `git` in pieces, so `MAX_REQUEST_SIZE_MB` does not apply to it; `MAX_PUSH_SIZE_MB` (default 0, no limit) is there if disk is what needs bounding. Everything else is still buffered whole and refused with 413 above `MAX_REQUEST_SIZE_MB` (default 64), enforced on the running total so an over-size body is never allocated — leave it a few MiB of headroom for read-ahead, as `gitloom.cfg` explains. Streaming a body means pausing the connection when the handler falls behind, which the runtime only does correctly on POSIX, so Windows buffers pushes too and there the ceiling still is the push limit. |
| Clone start-up latency | Windows only. There the response waits for `git` to finish, because Content-Length is unknowable before then — a 20 MiB clone measured ~5.6 s. On Linux the streaming path sends each chunk as git produces it (`GIT_STREAM=auto`). |
| Concurrency | Bounded, by two counters. A staged clone or push occupies one of `GIT_WORKERS` pool threads for its whole duration; a streamed one takes one of `GIT_STREAM_MAX` slots (default `GIT_WORKERS`) and falls back to staging when they are all busy — so an instance runs at most `GIT_STREAM_MAX + GIT_WORKERS` git processes. A client that disconnects does not stop the `git` it started; `GIT_TIMEOUT_SEC` (default 600) is what bounds that. |
| HTTP only | No SSH transport. git speaks HTTP Basic and re-sends the credential on **every** request, so set `HTTPS=1` or front gitloom with TLS before exposing it. |
| Dumb protocol | Not served. `/info/refs` without `?service=` answers 403 rather than 404, so the failure names itself. |
| Storage | `DB_DRIVER=none` (the default) keeps accounts and the repository index in JSON files; `DB_DRIVER=mysql` keeps the same data in two tables. The repositories themselves are always on disk — MySQL replaces the index, not the git objects. |
| One process | Still one process, whichever store. Each instance reads the whole index and account list into memory at boot and serves from that copy, so a second instance would not see the first one's writes. MySQL removes the reason that was unavoidable; it does not by itself make two instances correct. |
| Names | Owner and repository names are `[A-Za-z0-9_][A-Za-z0-9._-]*`. That is a security boundary, not a style rule — see the comment in [app/repo.lua](app/repo.lua). |

## Platforms

Linux is the deployment target and is where the streaming transport runs;
Windows is supported for development and falls back to file staging.

Verified on both: Arch Linux (gcc 16.2.1, git 2.55) and Windows (MinGW, git
2.52). `test/smoke.sh` passes 117/117 on Linux, and 106/106 on Windows and under
`GIT_STREAM=off` — the eleven it does not run there are the streamed-body cases,
which need the transport that platform does not have. `test/unit.lua` is 199 on
Windows, 198 on Linux (one case is about Windows path spelling). Adding
`DB_DRIVER=mysql` runs the same suite against MySQL instead of JSON files.

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
| `POST /api/v1/user/tokens` | `{label?, ttl_seconds?}`; the token is shown once |
| `DELETE /api/v1/user/tokens` | revoke the token this request presents |

Browsing a repository's contents:

| | |
|---|---|
| `GET /api/v1/repos/:owner/:name/branches` | |
| `GET /api/v1/repos/:owner/:name/tags` | |
| `GET .../commits` | `?ref=` `&limit=` `&skip=` `&path=` |
| `GET .../commits/:ref` | one commit, with the files it touched |
| `GET .../commits/:ref/diff` | `?path=`, bounded unified diff |
| `GET .../tree/:ref` and `.../tree/:ref/<path>` | directory listing, directories first |
| `GET .../raw/:ref/<path>` | file contents |

Authentication is HTTP Basic, with either a password or an access token as the
password field. A token without `ttl_seconds` never expires, which is what a CI
job wants; the browser asks for one that does, so that the credential it has to
keep in the page is bounded and revocable. Browsing obeys the same visibility rule as the transport: a
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
