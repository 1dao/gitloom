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

Still open in this phase:
- **Streaming request bodies.** Request-header framing is now exposed by the
  copied `xhttp_codec` as `parse_request_head`, but the HTTP serve loop still
  needs to connect body chunks directly to the child's stdin. Until that full
  duplex path lands, `MAX_REQUEST_SIZE_MB` remains the push ceiling.
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
viewing. Credentials stay in the current browser tab and are sent as HTTP
Basic only when the user logs in. The diff content endpoint is
`GET .../commits/:ref/diff?path=` and is capped by `MAX_DIFF_MB`.

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
