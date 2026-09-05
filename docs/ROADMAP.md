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

**Storage: done and verified against MySQL 8.4** (2026-09-03).

`DB_DRIVER` chooses where accounts and the repository listing live. The default
is unchanged — JSON files, one process, nothing to install. `mysql` puts the
same data in two tables through the `xmysql` worker that was already there.

- `app/db.lua` — the connection, and the only place a SQL literal is built.
  xmysql takes finished SQL and nothing underneath it escapes anything, so
  `db_quote` does not escape either: it ENCODES, as `_utf8mb4 X'...'`. A hex
  literal has no quote to close early and no backslash whose meaning depends on
  the server's `sql_mode`, so `x' OR '1'='1` comes back out as fourteen
  characters. The introducer is what keeps it a utf8mb4 comparison rather than a
  binary one — EXPLAIN reports `type=const` on the primary key with it, so the
  encoding costs no index.
- `app/migrate.lua` — the schema as numbered migrations, applied once and
  recorded in `gl_schema_migrations`. Two rules for a new one, both consequences
  of how it runs: statements must be idempotent, and a first boot of two
  processes against one empty database is not coordinated. `GET_LOCK` is the
  obvious answer and does not work here — the pool hands each query to whichever
  connection is free, so the release would arrive on a different one.
- `app/store.lua` — the DAO. Its contract is what keeps repo.lua and auth.lua
  free of any of this: `store_*_load()` returns THE map the caller then owns and
  mutates, and `store_*_put(rec)` persists one record already in it. That split
  lets the file backend keep doing the only thing a file can do — rewrite the lot
  — while the SQL backend writes the single row that changed.

Both identities survive the move intact. Accounts stay case-SENSITIVE and
repositories case-INSENSITIVE, which is not a detail: the tables are
`utf8mb4_bin` so a comparison means what Lua's `==` means, and `gl_repos` carries
`owner_key`/`name_key` alongside `owner`/`name` so the folded key that made
`Demo` and `demo` one directory is the primary key rather than a convention.

Boot changed shape. Every store call is a query and therefore yields, so the
loads moved out of `__init` and into `boot_async` — and the listener moved
behind them, onto a main-state timer that fires once boot has finished. Nothing
is accepted now until git has been checked and the stores have answered, which
also closes a window that was there under JSON.

Verified against a real MySQL 8.4.9, on both platforms and both stores:

| | JSON | MySQL |
|---|---|---|
| `test/unit.lua` (Windows / Linux) | 199 / 198 | — |
| `test/smoke.sh` Windows | 166/166 | 166/166 |
| `test/smoke.sh` Linux | 177/177 | 177/177 |

`test/dbreset.lua` empties the database first, because the counts the suite
asserts only mean something from empty. gitloom itself never creates a database:
xmysql names one in its handshake, and a pooled `USE` would only move whichever
connection ran it — so that is a deployment step, and the config says so.

**A review of it found four things, all fixed.** Three were mine and one was
older. The mysql pool is a THREAD, and xthread hands the caller a ThreadData
userdata owned by the calling lua_State whose `__gc` nulls that struct — started
inside the boot coroutine, as it first was, the worker would be reclaimed out
from under itself the moment that coroutine was collected. It is created from
`__init` now, like every other thread here, for the same reason timers are. A
raise in `boot_async` after its first yield reached nobody, which used to be
survivable and no longer is now that the listener is what boot switches on. The
file backend rewrote the account file from a map that could be nil, which would
have deleted every account rather than refusing.

The older one is the interesting one: **nothing bounded the free text**. A
description, an email and a token label were unbounded while the store was a
file that simply grew, and the token list had no cap at all — so an account
could accumulate credentials until its own row was too large to write, taking
REVOKING them down with it. Columns are finite, so what was quiet growth became
a 500 out of the database, and the two backends disagreed about what was legal.
All four are refused at the boundary now, with a 400 that says which, and
`AUTH_MAX_TOKENS` is the cap.

**What this does NOT do is make two processes correct.** Each instance still
reads the whole index and account list into memory at boot and serves from that
copy, so a second one would not see the first one's writes. MySQL removes the
reason that was unavoidable; the cache invalidation it now needs is a separate
piece of work, and open decision 3 is still open.

**Sideband progress during a push: nothing to relay** (measured 2026-09-03).

The premise was wrong. The advertisement carries `side-band-64k` and matches
what git itself advertises byte for byte; the client negotiates it and, with
`--progress`, does not send `quiet`; the response is sideband-framed and band
1 carries the report-status. There is simply no band 2, because
`git receive-pack --stateless-rpc` does not produce one — run standalone on a
captured request body, outside gitloom entirely, it emits band 1 and nothing
on stderr, for a 13-object 12 MiB push (unpack-objects) and for a 300-object
push (index-pack) alike. Progress in git is gated on the child's stderr being
a terminal, and under stateless RPC it is a pipe into the sideband muxer.
What remains is a different feature: band-2 messages GITLOOM writes itself,
which is how gitea says "this branch is protected" or offers a link to open a
pull request. That belongs with the checks that would produce such a message,
so it is listed in Phase 3 rather than here.

Still open in this phase:
- **io_uring.** Now installed on the dev box and untested here; it replaces the
  channel read path, which is exactly what streaming depends on.

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

**Creating and deleting a repository from the browser: done** (2026-09-03).

Reframed by a decision to make single-user use work first, which knocks out
collaborators, orgs, issues and PRs — none of which a solo user has anybody to
use with. What is left is that the browser read well and could not write at all:
in 24k of JavaScript its only two write requests were login and logout, so every
new repository still began with a `curl -u … -d '{"name":…}'` in a terminal. The
most repeated action was the one action the page could not do.

`POST` and `DELETE /api/v1/repos` already existed, so this is `web/` only: a `+`
beside the refresh button, two dialogs on the pattern the login dialog already
set, and the new repository selected as soon as it is made.

Three things it turned up, all fixed here:

- **The cancel button submitted the form.** A `<form method="dialog">` fires its
  submit event for EVERY submit button in it, and the login handler
  preventDefaults unconditionally — so filling in a password and then clicking
  取消 logged you in instead of backing out. The `required` attributes were all
  that usually hid it. There is one `isCancel` guard now and both dialogs use it.
- **A form cannot render a status.** `failure` deliberately shows the status
  rather than the server's English, which is right for a panel and useless for a
  form: "name taken", "name not allowed" and "description too long" are all 400,
  and 请求无效 tells the user nothing about which. The handful a create or delete
  can produce are translated; everything else still falls back to the status.
- **A new repository has no branch**, so `tree/main` and `commits?ref=main` both
  404. The tree panel already said "这个分支还没有可浏览的文件"; the commit panel
  said 没有找到内容 — about a repository the user is looking straight at, and the
  first thing they now see after creating one.

Deletion asks for the repository name to be typed. `repo_delete` is a recursive
delete of the git objects with nothing behind it, so a misplaced click has to
cost more than a click.

Verified by driving a real browser: create → the repository appears, is selected,
shows its clone URL and private pill → push to it from git → browse the tree it
grew → delete it, confirmed gone from both the index and the disk. The browser
now also pages commit history, explains exactly how to make the first push into
an empty repository, and lets its owner edit the description and visibility.
The API's `PATCH /api/v1/repos/:owner/:name` persists both fields in the same
JSON/MySQL-backed index used by create and delete. Smoke covers the pagination
lookahead and visibility boundary, and static checks keep each new panel's
markup and handler shipped together.

Still to do in the front end: syntax highlighting. The CSP is
`default-src 'self'`, so a highlighter has to be vendored into `web/`.

Estimate for the remainder: 1–2 weeks.

**Collaborator access: done (2026-09-04).** Owners and administrators can now
list, grant, update and remove read/write access for existing accounts through
the API. The browser exposes the same flow from a selected repository: the
owner can add an account, change its permission or remove it, while the
existing `auth_can_read` / `auth_can_write` checks enforce visibility and push
access on every request. Smoke coverage exercises the full lifecycle,
including cloning as a reader and pushing after promotion to write access.

This deliberately stops short of an admin panel or account provisioning in the
browser. Accounts are still created through the administrator-only users API;
the admin panel remains a Phase 4 item.

**A basic issue tracker: done (2026-09-04).** `app/issue.lua` keeps numbered
issues per repository with a title, body, state and comments; the API adds list,
create, read, update and comment, and the browser gets a panel for them. Reading
follows the repository — anonymous on a public one, `auth_can_read` on a private
one — and updating is the author, a write collaborator, or an administrator.

**A review of it found six things, all fixed.** One was fatal and the rest were
the same shape as each other:

- **MySQL would not start at all.** `gl_issues` was created without `owner` and
  `name`, but the DAO selects and inserts both — so `issue_index_load` failed
  with `Unknown column 'owner'`, and boot_async turns that into `xthread.stop(1)`.
  Not "issues are broken": the whole MySQL backend, which the previous commit had
  just made a supported deployment, refused to boot. The columns are back, for
  the reason `gl_repos` has them — the key is the case-folded identity and these
  keep the casing.
- **Every limit was in the wrong unit for its column.** `comments` allowed
  1000 x 8 KiB = 8 MB into a `TEXT` that holds 65,535 bytes — a factor of 125,
  and the same failure as the token cap before it: past the limit the row cannot
  be written AT ALL, so the issue could no longer be closed or edited either.
  `body` allowed exactly one byte more than `TEXT`. And `title` counted bytes
  against a `VARCHAR(200)` that counts characters, so an English title got the
  whole column and a Chinese one stopped at 66. Now: `comments` is `MEDIUMTEXT`,
  the body limit is 65,535 bytes, and the title is measured in characters.
- **`test/dbreset.lua` hung for ever when the database was unreachable**, so the
  suite that would have caught the first item hung instead of failing. It gives
  up after `DBRESET_TIMEOUT_SEC` now.
- **`store_issue_delete` had no caller** in either backend, and no endpoint
  deletes a single issue. Removed rather than left as a shape for something that
  does not exist.

Verified against MySQL 8.4: the schema applies, an issue survives a restart with
its Chinese title, comment count and state intact, and nothing is written to the
JSON files. With the two columns removed again the instance fails to boot with
that exact error, so the fix is what makes it work rather than something that
happened to be true.

**If you already ran the broken migration**, editing it in place does not help:
the runner records `id = 2` and never repeats it. Drop `gl_issues` and its
ledger row, or drop the database. `test/dbreset.lua` already does that for the
test databases.

One thing left, deliberately: `issue_list` answers `{}` when the store cannot be
read, which reports "no issues" for "could not ask". `repo_list` and
`auth_user_list` do the same, so changing one of the three alone would be worse
than the inconsistency. All three are only reachable if the initial load failed,
and boot refuses to continue in that case.

## Running it, rather than demonstrating it (2026-09-05)

A pass over what a single operator hits that no feature covers. Most of it was
already solved next door: `../xpauth` has been deployed for real, and the house
rule about not rewriting what xnet2lua or xpauth already has applies to
operations as much as to code.

**The README was wrong about the binary, in the direction that breaks a move to
a new machine.** It promised "binaries are committed, so a clone runs with no
toolchain" and `git ls-files bin/` was empty the whole time; `.gitignore` even
carried a paragraph explaining why `bin/` was deliberately tracked, un-ignoring
it for binaries that were never added. xpauth does not commit its runtime
either — it copies it from xnet2lua per platform and says so. Both files now say
that, which is the thing that is true.

**A forgotten password was unrecoverable, and worse for one operator than for a
team.** `auth_bootstrap` only creates the administrator when NO account exists,
so changing `ADMIN_PASSWORD` and restarting does nothing once there is one, and
PBKDF2 means no replacement can be written into the store by hand. With no
second administrator to ask, the only way back in was deleting the account
store.

Fixed by taking xpauth's recovery-code model whole, including the parts that are
not obvious until it has been in front of users:

- `XXXX-XXXX-XXXX-XXXX` from an alphabet with no `0/O/1/I/L`, because it is read
  off a screen and typed back in months later. `normalize_code` accepts it lower
  case, with the dashes missing, or both.
- Hashed like a password. Here that needs no second salt column the way xpauth
  needs one: `pwhash` is a self-contained `pbkdf2$iter$salt$hex`, so a password
  change rewrites that string and cannot touch `recovery`. The property xpauth
  had to engineer comes for free from the format.
- Spending a code returns a REPLACEMENT, so using one never leaves the account
  with no way back in — and the old one cannot be replayed, because the stored
  hash it would have to match is gone.
- `POST /api/v1/user/password` and `/password/reset`. The reset takes no
  credentials, by definition, so it sits behind the same failure lockout a login
  uses; only a rejection is counted as a guess, never a malformed body or a
  store failure, so a database outage cannot lock out everyone who tried during
  it.

**One place gitloom does better than the model it copied.** xpauth records that
its password change cannot cut off live sessions — they authenticate by token,
and a token does not know the password behind it changed — and lists restarting
the service as the only remedy. gitloom already had token revocation for logout,
so a change and a reset both revoke every token the account holds, and the
verification cache is dropped so the old password stops working immediately
rather than at the end of `AUTH_CACHE_SEC`.

The administrator's code goes to the boot LOG, which is the only channel an
account the service created for itself out of a config file has. A secret in a
log file is a real cost and the smaller one; the line says to move it and delete
it, and `deploy/README.md` repeats that where it talks about backups.

Migration 3 adds the column, and adding it needed the runner to grow one thing:
a step may now be a FUNCTION as well as a SQL string, because `CREATE TABLE` has
`IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN` does not — that spelling is
MariaDB's. `add_column` asks `information_schema` instead of keying off MySQL's
error 1060, since keying a migration off an error string is how a server upgrade
breaks one.

**Deployment, backups and logs**, which is where a personal instance actually
lives:

- `deploy/gitloom.service`, adapted from xpauth's including the comments it
  earned — `LimitCORE=infinity` or a SIGSEGV leaves no core, and `ReadWritePaths`
  for the four directories gitloom writes. `ProtectHome=true` is safe here only
  because git's HOME already points at `DATA_DIR/githome`.
- `deploy/README.md` on what to back up and, more importantly, why copying
  `repos/` while the service runs is not safe: git renames objects and packfiles
  into place under lockfiles, so a copy taken during a push can hold a ref that
  points at an object the copy never reached. Stop-copy-start, `clone --mirror`,
  or a filesystem snapshot — with the MySQL half alongside it.
- `LOG_MAX_FILE_MB` bounds one log file. Nothing bounds the NUMBER of them: the
  runtime rolls to the next number and never deletes, in xnet2lua and therefore
  in xpauth too. logrotate with `copytruncate`, because the runtime holds its
  file open and does not reopen on a signal.

Verified against MySQL 8.4 and JSON on both platforms — `test/unit.lua` 199/198,
`test/smoke.sh` 166 on Windows and 177 on Linux, both stores — with the whole
forgotten-password path driven end to end: bootstrap logs a code, a wrong one is
refused, a loosely typed one resets, the old password and every token issued
before it stop working, and the spent code cannot be replayed.

**Tags are browsable.** The ref selector lists branches and tags in two
groups; every endpoint behind it already took a `ref` and resolved it the way
git does, so this was a control that did not exist rather than a capability that
did not. Verified by tagging two commits, selecting the older tag and reading
the file back at that ref.

Still missing for a single operator: renaming a repository, and listing or
revoking tokens other than the current one.

## Phase 3 — collaboration

Organisations and teams, then issues (comments, labels, milestones), then pull
requests. Server-authored sideband messages land here too — the band-2
`remote:` lines that tell a pusher why a branch was refused, or where to open a
pull request. The transport for them already works; what is missing is anything
worth saying, which arrives with protected branches and review.

PRs are the heavy part: merge-base computation, conflict detection, three merge
strategies, and a review state machine.

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

1. ~~**Storage.** Stay on JSON files for longer, or move to MySQL at Phase 1?~~
   Settled 2026-09-03: both, chosen by `DB_DRIVER`, with files as the default.
   A single instance has no reason to want a database and every reason not to
   install one; the moment a second one exists it cannot share a JSON file. The
   backend is now a deployment choice rather than a rewrite.
2. **Front end.** Single-page app against the JSON API (assumed above), or
   server-rendered? The SPA assumption is what keeps Phase 2 at 4–6 weeks.
3. **Multi-process.** One process with `GIT_WORKERS` threads, or several
   processes behind a load balancer? The second needs shared storage and a
   shared session/index authority — i.e. it needs decision 1 resolved first.
