# gitloom roadmap

Sizing anchor, measured against `../gitea` (non-test Go):

| | |
|---|---|
| `routers/` | 102,635 lines |
| `modules/` | 89,093 |
| `services/` | 74,331 |
| `models/` | 51,662 (118 tables) |
| `cmd/` | 6,777 |
| **Go total** | **~324,500** |
| Templates | 571 `.tmpl` |
| Front end | 48,305 lines TS/CSS |
| Routes | 753 web + 421 API registrations |
| Locales | 29 |

The number that matters most is not in that table: **232 `NewCommand(` calls**.
gitea requires an external `git` ≥ 2.25 and shells out for everything hard.
gitloom does the same, which removes the only genuinely difficult part.

Reproducing gitea is 24–36 person-months and is not the plan. The plan is a
self-hostable git service that a team can actually use.

---

## Phase 0 — transport ✅ done

Clone / fetch / push over HTTP(S), a repository model on disk, accounts with
HTTP Basic and access tokens, public/private repositories, a JSON management
API, and an end-to-end test (`test/smoke.sh`, 27 cases).

Reusable infrastructure landed in xnet2lua first, per the house rule:
`scripts/core/server/xproc.lua` + `xproc_worker.lua`, a pool of blocking
process-runner threads with argv quoting, stdin/stdout file redirection,
process-relative path resolution and an opt-in kill watchdog. Covered by
`tests/lua/xproc_test.lua` (16 cases), including a byte-for-byte binary round
trip through both redirects.

## Post-Phase-0 review (2026-08-30)

A review raised twelve findings; eleven reproduced, one (`#11`, Windows naming)
only partly. All are fixed, each with a regression case — `test/smoke.sh` went
from 27 to 43. Summary of what changed:

- Both JSON stores now write atomically. The previous delete-then-rename had a
  window in which the account file or the repository index did not exist at all.
- `repo_create` rolls the directory back and fails when the index will not
  persist; `repo_delete` no longer swallows the save result.
- Password hashing moved to its own thread (`worker/kdf.lua`), with negative
  caching and per-address/per-username failure lockout
  (`app/auth_ratelimit.lua`). PBKDF2 on the event loop made ~20 bad logins per
  second enough to stall every clone.
- Request bodies accumulate as chunks and are concatenated once. The old
  per-packet concatenation was quadratic — a 64 MiB push copied gigabytes.
- `GIT_TIMEOUT_SEC` defaults to 600 instead of 0, so an abandoned fetch cannot
  hold a worker indefinitely.
- git children run with an isolated `HOME` and `GIT_CONFIG_NOSYSTEM`, so the
  operator's dotfiles cannot change what upload-pack and receive-pack do.
- `/api/v1/version` serves a value cached at boot instead of spawning git.
- Wrong credentials are a 401 rather than a silent downgrade to the anonymous
  view; a refused DELETE answers 404 like GET rather than confirming existence.
- Names reject Windows device names and trailing dots, and index keys are
  case-folded so a collision means the same thing on every filesystem.
- Error bodies no longer carry absolute server paths.
- An empty ref list serialises as `[]`, not `{}`.

Still open, and genuinely Phase 1: the request body is staged to disk with a
synchronous write on the event loop. The fix is the `xproc` C binding below,
which removes the staging entirely.

## Phase 1 — capability floor

**Response streaming: done and verified on Linux** (2026-08-31).

The enabling insight was that almost nothing new was needed. `xnet.attach(fd,
handler)` already adopts an arbitrary fd into an `xChannel` — nonblocking,
poll-registered, framed, with a buffered out-queue. `xproc` hands back
**socketpair** endpoints rather than pipes, so they go through that path
unchanged: no new attach entry point, no channel flag, no I/O code of its own.

In ../xnet2lua (opt-in, `WITH_XPROC=1`; the default build omits it entirely):
- `xproc.c` / `xproc.h` — spawn, wait, kill. No I/O at all.
- `xlua/lua_xproc.c` — `xproc.spawn/wait/kill/supported`.
- Read-side flow control bound to Lua: `conn:pause_read()`, `resume_read()`,
  `is_read_paused()`, `stats()`, `set_max_send()`. xchannel documented these as
  being for proxy and tunnel use; they were simply never reachable from Lua, and
  copying one channel into another is unsafe without them.
- `tests/lua/xproc_pipe_test.lua` — 20 checks. Skips cleanly when xproc is not
  compiled in, which the default build is.

Here:
- `app/stream.lua` — chunked responses.
- `git_service_stream` in `app/git.lua`, chosen by `git_stream_enabled()`.
- Windows keeps file staging: `xproc_supported()` is false there.

**What the first Linux run found.** Everything passed at small sizes and a
60 MiB clone failed with `curl 56 Malformed encoding found in chunked-encoding`.
Two real defects, both invisible below ~10 MiB:

1. `stream_write` issues three writes per chunk — length, payload, CRLF — and
   ignored their return value. `send_raw` refuses writes once the channel's
   send buffer hits its 10 MiB cap, so one part of a chunk silently vanished
   and the frame was corrupt.
2. Nothing throttled the copy. git outruns any real client, so the buffer was
   always going to reach the cap on a large repository.

Fixed by checking every write, and by pausing the child's channel above
`STREAM_PAUSE_HIGH_KB` and resuming below `STREAM_PAUSE_LOW_KB`. The child then
blocks on its own stdout, which is the backpressure a pipeline should have.

Verified on Arch/WSL, gcc 16.2.1, git 2.55:
- `xproc_pipe_test.lua` 20/20, and skips with exit 0 on a default build
- `test/unit.lua` 59/59, `test/smoke.sh` **75/75** under both transports
- 64 MiB clone: 429 ms streaming vs 599 ms staged, byte-identical, `git fsck`
  clean; still correct with the high-water mark forced down to 64 KiB
- With backpressure disabled the 64 MiB clone fails again, so the new
  large-clone case in `test/smoke.sh` genuinely catches a regression

**Request streaming: done and verified on Linux** (2026-09-02).

A smart-HTTP POST is now dispatched as soon as its HEADERS are complete, with
`req.body_stream` in place of `req.body`; its handler pulls pieces off the socket
and writes them to `git`'s stdin as they arrive. `MAX_REQUEST_SIZE_MB` is no
longer the push ceiling. The only bound left is `MAX_PUSH_SIZE_MB`, which
defaults to none.

- `app/http.lua` — an incremental chunked decoder, a per-connection body queue
  with pause/resume flow control, and the parked-coroutine reader.
  `parse_request_head`, synced from xnet2lua earlier and unused since, is what
  makes routing before the body possible.
- `app/git.lua` — `stream_rpc` pumps that reader into the child's stdin behind
  its own water marks; `git_service` gained an incremental drain to the staging
  file, which is the path a streamed body takes when every streaming slot is
  busy.
- `app/smart.lua` — decides which requests get it: the two smart-HTTP POSTs,
  not content-encoded, and only where the streaming transport runs.

git makes this tractable by never doing the awkward combination. It gzips a
request body only when it has already buffered the whole thing itself
(`http.postBuffer`, 1 MiB by default) and switches to chunked transfer encoding
exactly when it has not — so the bodies that need streaming are never the
compressed ones, and the runtime's one-shot inflate is never in the way.

**What the first Linux run found.** Three defects, none of them visible on
Windows and two not visible at small sizes either:

1. **A timer armed inside a request coroutine segfaults the process** as soon as
   its callback resumes that coroutine. `xtimer` records the `lua_State` that
   armed it, so the callback runs as a `lua_pcall` on a coroutine suspended
   mid-yield, and `lua_resume` on it from there is undefined. main.lua had
   written this down for the scratch sweeper; the streaming transport had got
   away with it only because none of its timers resumed anything. Replaced by
   one ticker armed from the main state — `http_wait_until` and `http_after`,
   which is also where the child-kill deadline now lives.
2. **`max_packet` was wired to `MAX_REQUEST_SIZE_MB`.** It bounds the channel's
   inbound buffer, not the request: the loop consumes every byte it is handed,
   so a larger request still arrives, in pieces. What it actually did was close
   the connection with `packet_too_large` — no status, no log line — so lowering
   `MAX_REQUEST_SIZE_MB` broke pushes instead of answering 413.
3. **Read-ahead counts against the ceiling.** git sends a small probe POST
   before a large push and starts streaming the real body the moment it is
   answered, while the handler is still syncing HEAD. Those bytes buffer behind
   the busy handler and earned a 413 about a size nobody had. Pausing the
   connection for the duration fixes it on Linux and breaks every request on
   Windows (below), so it is documented instead: the ceiling has to leave a few
   MiB of headroom.

**A runtime defect, worked around rather than fixed.** On Windows,
`conn:pause_read()` on an accepted connection does not survive the resume — the
client is reset, and every request whose handler yields dies. Holding a body
back is precisely what a streamed one must do, so streaming a body is tied to
`GIT_STREAM`, which is off on Windows anyway: one switch, both directions. Worth
fixing upstream; the poll backend destroys the fd's entry when its last event is
removed, which epoll survives and WSAPoll does not.

Verified on Arch/WSL (git 2.55) and on Windows:
- `test/unit.lua` 167 on Linux and 168 on Windows, `test/smoke.sh` **113/113**
  on Linux streaming and 102/102 on Windows and under `GIT_STREAM=off`
- a 24 MiB push through a 4 MiB `MAX_REQUEST_SIZE_MB`, byte-identical on clone
  and `git fsck` clean, with both water marks forced to a sixteenth of their
  defaults so the pause and the ticker wait are crossed many times over
- `MAX_PUSH_SIZE_MB=1` refuses that push and leaves the instance serving
- a client killed mid-upload releases its slot and its child; the next push works
- two concurrent pushes against `GIT_STREAM_MAX=1` — one streamed, one staged
  through the incremental drain — both byte-identical

Two test-suite faults surfaced on the way and are fixed: the credential-lockout
case locked out 127.0.0.1, so every case after it passed only while the positive
auth cache stayed warm and adding cases anywhere above them broke cases nowhere
near them; and `test/unit.lua`'s backslash-path case asserted Windows semantics
on every platform, so Linux had been one red case for some time.

**Post-review fixes** (2026-09-03). Four findings, all reproduced:

- **A streamed body that FAILED did not end the connection.** The cleanup forced
  `Connection: close` for a body the handler had left undrained, but not for one
  that errored — over `MAX_PUSH_SIZE_MB`, or misframed. `body_feed` stops
  decoding at that point and puts everything after it into the buffer for the
  next request, so a kept-alive connection reads the rest of a packfile as
  pipelined HTTP. A ceiling meant to refuse a push instead produced a stream of
  400s on a connection that was still being written to. Now anything but a clean
  end closes.
- **The chunked decoder accepted framing nothing else would.** It looked for a
  bare LF and took the first hex run in the line, so `4\n` and `4garbage\r\n`
  both parsed. Anything in front of this server that reads the size line
  strictly then disagrees about where the request ends, which is the whole of
  request smuggling. Now CRLF only, and a size line that is 1\*HEXDIG plus an
  optional `;ext`.
- **Nothing bounded a streamed body.** `HANDSHAKE_TIMEOUT_SEC` stops covering a
  connection the moment its request parses, and `GIT_TIMEOUT_SEC` lives inside
  `stream_rpc` — so the file-staging fallback taken when every streaming slot is
  busy would wait on a silent client for the life of the process. New:
  `BODY_TIMEOUT_SEC`, on the same ticker.
- **The docs described a transport that had moved.** README's request walkthrough
  and gitloom.cfg's scratch-file section both still said every fetch and push
  stages through files. Both now say which path does what.

`test/smoke.sh` grew to 113 with `MAX_PUSH_SIZE_MB` (refused, nothing written,
instance survives), the `Connection: close` on an unfinished streamed body, and
a stalled upload driven through a fifo — the last verified to fail with the
deadline removed. The ceiling and decoder-error branches leave through the same
line as the undrained one and are not asserted separately: no HTTP client will
keep uploading past the response that would prove it.

Still open in this phase:
- **Sideband progress** during a push.
- **io_uring.** Now installed on the dev box and untested here; it replaces the
  channel read path, which is exactly what streaming depends on.
- **Storage.** A minimal DAO plus a migration runner over the existing
  `xmysql` worker.

## Phase 2 — repository browsing

**API layer: done** (2026-08-30). `app/browse.lua` wraps the plumbing —
`rev-parse`, `ls-tree -z -l`, `cat-file`, `log`, `diff-tree -z --root`,
`for-each-ref` — behind branches / tags / commits / tree / raw endpoints. The
router grew `*wildcard` segments, since a file path has no fixed segment count.
Covered by 27 new smoke cases, including ref-injection and path-traversal
attempts driven with `curl --path-as-is` (without it curl collapses the dot
segments itself and the test proves nothing about the server).

Two things surfaced while building it and are fixed here rather than deferred:
`HEAD` is now corrected after a push whose branch is not the repository's
recorded default — otherwise a `git init -b master` client left a repository
that cloned to an empty worktree and answered 404 on every browsing endpoint —
and `diff-tree` gained `--root`, without which the initial commit of every
repository reported that it changed nothing.

**Browser slice: done (2026-09-02).** `app/web.lua` serves a same-origin,
dependency-free SPA from `web/`. It covers the repository list, branch
selection, tree navigation, raw blob viewing, commit history and bounded diff
viewing. The diff content endpoint is `GET .../commits/:ref/diff?path=` and is
capped by `MAX_DIFF_MB`.

Three things the browser forced, all of them fixed here rather than left as
front-end workarounds:

- **Tokens gained an expiry and a revoke.** A page cannot hold a password: any
  script that runs on the origin can read what the page stored, and a password
  is neither bounded nor revocable. So `auth_token_create` takes a TTL,
  `auth_token_revoke` self-revokes the presented credential (and drops it from
  the positive verification cache, which would otherwise keep answering for
  AUTH_CACHE_SEC), and the browser exchanges the password for a twelve-hour
  token at login and revokes it at logout. Omitting `ttl_seconds` still means a
  token that never expires — the CI case, and every token already issued.
- **HEAD is routed.** It fell through to a 404 because only GET was in the
  table, which is what a reverse proxy and an uptime monitor send at `/` first.
  The codec already drops the body and keeps the Content-Length, so routing was
  the whole of it.
- **Assets are addressed by a digest of their own bytes.** index.html is never
  cached and names `/app.js?v=<digest>`, which is; otherwise the two are cached
  independently and a client runs stale JavaScript against fresh HTML.

Still to do in the front end: syntax highlighting, richer commit metadata,
pagination and an administrative repository-creation flow. These are polish
items; the first browse loop is usable now.

Estimate for the remainder: 3–5 weeks.

## Phase 3 — collaboration

Organisations and teams, then issues (comments, labels, milestones), then pull
requests. PRs are the heavy part: merge-base computation, conflict detection,
three merge strategies, and a review state machine.

Estimate: 6–10 weeks.

## Phase 4 — the rest of the surface

Webhooks, an admin panel, SSH transport (system `sshd` plus an
`authorized_keys` `command=` shim, the way gitea does it — a Lua SSH-2 server is
not on the table), and search.

## Deliberately out of scope

LFS, package registries, CI/Actions, mirroring, GitHub import, and i18n. Each is
a large subsystem in gitea and none is needed for a working git host. Revisit
individually, never as a batch.

---

## Open decisions

1. **Storage.** Stay on JSON files for longer, or move to MySQL at Phase 1? The
   answer is MySQL as soon as more than one process needs to serve the same
   repositories.
2. **Front end.** Single-page app against the JSON API (assumed above), or
   server-rendered? The SPA assumption is what keeps Phase 2 at 4–6 weeks.
3. **Multi-process.** One process with `GIT_WORKERS` threads, or several
   processes behind a load balancer? The second needs shared storage and a
   shared session/index authority — i.e. it needs decision 1 resolved first.
