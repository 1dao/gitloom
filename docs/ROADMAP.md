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

The things Phase 0 works around rather than solves.

- **`xproc` as a C binding.** Pollable stdin/stdout/stderr pipes, `kill`, exit
  status. Removes the disk staging, the push-size ceiling and the clone
  start-up latency in one change — `app/git.lua` is written so nothing above
  it moves.
- **Streaming request bodies.** The codec buffers whole requests today; a push
  larger than `MAX_REQUEST_SIZE_MB` is refused. Stream to a file (or to a pipe,
  once the binding exists) instead.
- **Chunked response writer.** `send_file_response` covers the packfile case;
  sideband progress during a push does not.
- **Storage.** A minimal DAO plus a migration runner over the existing
  `xmysql` worker. Accounts and the repository index are JSON files today.

Estimate: 2–3 weeks, ~1.5k lines of C, ~1.5k of Lua.

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

**Still to do: the front end.** A single-page app over exactly these endpoints —
file tree, blob view with highlighting, commit list, diff view. No server-side
templates, which is what lets us skip gitea's 571 `.tmpl` files entirely.
There is no diff-content endpoint yet either; `commits/:ref` returns the file
list and status letters, not hunks.

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
