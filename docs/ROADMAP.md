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
| `test/unit.lua` (Windows / Linux) | 216 / 215 | — |
| `test/smoke.sh` Windows | 206/206 | 206/206 |
| `test/smoke.sh` Linux | 216/216 | 216/216 |

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

~~Still to do in the front end: syntax highlighting. The CSP is
`default-src 'self'`, so a highlighter has to be vendored into `web/`.~~
Settled 2026-09-05, and the premise was wrong: nothing was vendored.
`web/highlight.js` and `web/markdown.js` are ours, for the reason given below.

~~Estimate for the remainder: 1–2 weeks.~~ The last of it landed 2026-09-06.

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

**Two more, both the same shape as the tag one: the server was already right
and nothing reached it.**

`clone_url` took its scheme from whether OUR socket was TLS. Behind a proxy that
terminates TLS — which is one of the two things README tells an operator to do —
that socket is plain HTTP, so a page served over https handed out an `http://`
clone URL. Not cosmetic: git follows it and re-sends HTTP Basic credentials on
every request of every clone and push, which is the exact exposure the advice
exists to prevent. `X-Forwarded-For` was already honoured from `TRUSTED_PROXIES`;
`X-Forwarded-Proto` simply was not read. Now it is, under the same trust rule and
verified for all four cases — trusted with the header, trusted with a two-hop
chain, trusted without it, and an untrusted peer that cannot forge it. The other
half of that advice, in-process `HTTPS=1`, was never tested either and turns out
to be sound: a self-signed certificate serves the API and `git clone` over TLS.

The browser read every file with `response.text()` into a `<pre>`, so a PNG was
a screen of replacement characters and nothing could be downloaded at all —
while `h_raw` had been serving `image/png` correctly all along. It now fetches
bytes and branches on the response's Content-Type rather than on a second copy
of the extension list, which is what keeps it in step with `INLINE_TYPES`; that
list is a security decision, and two copies of it drift. Through `api()` and a
blob rather than pointing `<img src>` at the raw URL, because that URL needs an
Authorization header an `<img>` cannot send — a private repository's images
would 401. `img-src` gained `blob:` for it. Anything that decodes to NULs or a
body of replacement characters says so instead of showing the garbage.

Verified against a private repository: a 1×1 PNG decodes (`naturalWidth` 1) from
a `blob:` URL, a UTF-8 text file still reads, a 10 KB binary says it cannot be
shown, and all three offer a download named after the file. No console errors
and no policy violation.

A review of both found two things. `http_client_scheme` went in beside
`http_client_ip` — which has a whole trust-set fixture and nine cases, for the
reason its comment gives — with no test of its own; it takes `trusted` as a
parameter precisely so it can be tested, and now is, including the spoof. And
`closeRepoView` released everything about the repository view except the object
URL behind an open file, which is a document-lifetime reference to those bytes
that nothing else would ever drop — on the path a token expiring takes, which is
not a rare one.

### Rename, tokens, search — the last of the solo list

**Rename** moves a directory and re-keys the index, so it is its own operation
rather than another field `repo_update` writes, and PATCH runs it first and
alone. The order inside it is chosen for what a crash leaves behind: the
directory moves first, because that is the only step with no undo once the index
points at it, and a failure there has changed nothing at all; the index moves
second, and if that fails the directory is moved back; issues move last, because
a repository whose issues did not follow is still a repository, while an index
pointing at a directory that is not there is not one.

Two things that are not obvious until they break. A rename that only changes
case keeps the same index key, so the collision check has to skip the repository
being renamed — otherwise `demo` → `Demo` reports a clash with itself — and on a
case-insensitive filesystem the destination "already exists" because it IS the
source, so the directory has to go via a third name or the spelling never
changes on disk. And issues are keyed by repository rather than by an id of
their own: a rename that did not carry them would not lose them, it would strand
them under a name nothing looks up, which is worse, because the repository comes
back looking like it never had any. Both stores got one statement for it —
`UPDATE`, not delete-then-insert, since the rename moves a row across its own
primary key and two statements leave a moment with no row at all.

**Tokens** can now be listed and revoked individually. The id is deliberately
not derived from the stored digest: a prefix of it would have been stable and
free, and would also publish part of the verifier for a live credential in a
listing. Tokens issued before ids existed get one on first listing, which is the
only moment the account is already being read and written. Revoking the token in
flight is a logout and says so, and it drops the verification cache wholesale —
that cache is keyed by the secret, which is not stored, so the entry cannot be
found by id, and the alternative is a credential that keeps working for
`AUTH_CACHE_SEC` after it was revoked.

**Search** is `git grep` against a resolved object id, fixed-string. `-F` is not
a convenience: the pattern is typed by whoever is looking, and a regex engine
given hostile input is server CPU spent without limit by anyone with read
access. The ref is resolved to an oid first, like everything else in
`browse.lua` — rule 1 of that file is that caller-supplied ref text never
reaches a git command line, and `git grep <ref>` would have been exactly that.

The bug worth recording is in how it first failed. It shipped with
`--untracked=no`, which git rejects outright, and the error handler treated "no
output" as "no matches" — so every search reported finding nothing, in a
repository where the word was on line 1, and reported it as a perfectly normal
empty result. `git grep` exits 1 for "found nothing" and 2 or more for a real
failure; branching on the **exit code** rather than on whether any output came
back is the difference, and the smoke case now asserts a query that must find
something alongside the one that must not.

Two smaller things fell out of building the interface for these. `PATCH` with
only a name had to stop short-circuiting `repo_update`'s "no fields to update"
refusal, which briefly turned an empty `PATCH {}` from a 400 into a 200. And
`formatDate` was reading a Unix time in **seconds** as milliseconds, so every
issue in the browser was dated 21 January 1970 — visible since the issue tracker
shipped, and only noticed because a token listing put two more dates on screen.

### README rendering and syntax colouring, without vendoring anything

A repository page that does not show its README is most of a git front end
missing, and the obvious route to one is `marked` plus `DOMPurify` plus
`highlight.js`. The content security policy forbids a CDN, so that route means
committing three minified bundles.

We did not, and the reason is not size. This repository has no package manager,
no build step and no way to ship a patch on the day DOMPurify has a bypass — and
the runtime underneath vendors luajit, mbedtls and picoquic **as readable
source** precisely so that everything in the tree can be read. Three minified
blobs would be the only unreviewable thing here, and they would be the part
standing between a README and the reader's token.

So `web/markdown.js` and `web/highlight.js` are ours, and they are safe by
construction rather than by filtering: **neither ever builds an HTML string.**
Every element comes from `createElement` and every piece of text goes in through
`textContent`, so there is no markup for repository content to inject into and
no sanitiser with a list of tags to get wrong. That reduces the entire untrusted
surface to one function — `safeUrl` — which is the only place a README reaches
an attribute. It decodes entities *before* it tests the scheme and strips
control characters before that, because `&#106;avascript:` and `java<tab>script:`
are precisely how a check in the other order gets walked past.

The policy, stated once: raw HTML in Markdown is not rendered at all. GitHub
allows a subset; "which tags are safe" is the question with no stable answer, and
a git host for one operator does not need `<details>`. An external image is not
loaded either — `img-src` would block it anyway, and widening that policy would
let any README author log the address of every reader of a private instance — so
it becomes a link. A relative image is fetched through the API as a blob, the
same way the file view already handles a PNG, because the raw endpoint needs an
Authorization header that an `<img src>` cannot send.

Two smaller decisions worth their lines. A relative link becomes a route into
this browser rather than a server path, because `/admin/site/docs/x.md` belongs
to the git transport. And an in-page `#section` link gets **no href at all**,
only a scroll handler: this page keeps its own state in `location.hash`, so a
real fragment link would overwrite the route with a section name.

Colouring is four token classes — comment, string, number, keyword — driven by
one table per language, so a new language is data rather than code and an
unknown one renders as plain text. Ordering inside a language table is
load-bearing: Lua's `--[[` has to be tried before `--`, or every block comment
reads as a line comment and the rest of the file turns back into code.

`test/webjs.js` is what makes the safety claim worth anything. It stubs a DOM
that keeps receipts — every element created, every URL assigned — and asserts
against the record rather than against rendered markup, so an attempt to create
a `<script>` fails there even though nothing would have executed. Removing the
scheme test from `safeUrl` turns 10 of its 47 checks red, and the entity- and
tab-encoded payloads are among them. It also pins an invariant the highlighter
has to keep: the painted output's text must equal the input byte for byte.

Node runs it, and node is a development convenience rather than a dependency —
nothing in `bin/` or `app/` needs it — so `test/smoke.sh` skips it where it is
absent, which is why the Linux column is one check shorter rather than one check
luckier.

**What the review of it found**, all four fixed:

1. `safeUrl` stripped *all* whitespace, so `<my docs/a.md>` became `mydocs/a.md`
   — a link to a directory that exists turned into one that does not, silently.
   The rule now copies what a browser actually does: delete tab, newline and
   carriage return anywhere (that is what makes `java<tab>script:` a working
   address), trim leading and trailing spaces, and **leave an interior space
   alone**, because the browser does and a space cannot hold a scheme together.
2. A relative destination was not percent-decoded, so `[x](my%20docs/a.md)` —
   the ordinary way to write a link to a file with a space — was re-encoded into
   `my%2520docs`, a path no repository has. This hit the common case, not the
   exotic one.
3. Nothing capped Markdown rendering the way `MAX_BYTES` caps colouring, so a
   generated file that happened to end in `.md` would build DOM nodes until the
   tab stopped responding.
4. A missing `markdown.js` took the whole file view down with it, because
   `glMarkdown` was referenced as a bare name. Rendering is a feature of this
   page; reading a repository is the point of it.

The fifth finding was in the tests, and it is the one worth remembering. The
hostile-URL cases asserted on rendered `href`s — and **passed with the URL
normalisation removed entirely**. They could not fail, because the renderer's
fallback for anything it cannot classify is the relative branch, and the
application turns a relative path into a `#/owner/name/blob/...` route: an
obfuscated `java<tab>script:` does not become a dangerous link here, it becomes
a harmless one. That is a good property, and it meant the tests were measuring
it instead of what they claimed. `safeUrl` is now tested directly, sixteen cases
of it, and removing the normalisation turns five of them red.

It also corrected the file's own comment, which had claimed the decode-then-check
ordering was what stood between a README and a `javascript:` link. It is not —
the allowlisted-scheme-or-else-it-is-a-path structure is. What the ordering buys
is that the scheme test sees what the browser would see, so a dangerous address
is *recognised and refused* rather than quietly reclassified as a file name.
That distinction matters because the caller's `resolveLink` is then the thing
deciding, so its contract is now written down where it is implemented.

Verified in a browser against a live instance: a README with headings, setext
headings, nested and task lists, a table with per-column alignment, blockquotes,
two fenced blocks in different languages, a relative image and a relative link
renders correctly and in the page's own palette; the 1×1 PNG really decodes
(`naturalWidth` 1) through the blob path; the in-page jump scrolls without
touching the route; opening a `.md` file renders it with a source toggle, and
opening a `.lua` file colours it with the long comment as one comment. The
hostile half of the same README — `<script>`, `onerror`, `javascript:` in six
encodings, `data:text/html` — produced no dangerous element, no dangerous
attribute, and no console or policy error: it is all visible as text. And after
the fixes above, a README link written `[a doc](<我的 docs/读我 note%231.md>)`
opens that exact file, with the space and the `#` each encoded once on the way
into the address bar.

Neither parser is fast in the sense of being optimised, but neither is a way to
hang a tab: 10,000 unmatched brackets is 83 ms, 10,000 asterisks is 1 ms, a
50,000-line README is 44 ms, and 280 KB of JavaScript colours in 56 ms. The
regexes were checked for the nested-quantifier shape that backtracks
exponentially; the two that have it (`RULE`, `TABLE_RULE`) only ever see a
single line, and were measured rather than reasoned about.

### The address bar

The whole browser lived at one URL. A refresh went back to the repository list,
there was nothing to bookmark, and nothing to paste to anybody — which for a
single operator is most of what a web front end over a git repository is *for*.
So the state now lives in the address bar, and everything else that gets built
hangs off it, which is why it went first.

A hash, not a path. `/<owner>/<name>.git/...` is the git transport and
`/api/v1/...` is the API; serving `index.html` for arbitrary paths would shadow
both and turn every genuine 404 into the page. The grammar mirrors GitHub's:

    #/<owner>/<name>/tree/<ref>[/<dir>]
    #/<owner>/<name>/blob/<ref>/<file>
    #/<owner>/<name>/commits/<ref>
    #/<owner>/<name>/issues[/<number>]

`tree` and `blob` are separate because the URL cannot otherwise say which one a
path is, and guessing means a reload of a file link lands in a directory
listing. Each segment is `encodeURIComponent`d on the way out and decoded on the
way in, so a file called `我的 docs/读我 note#1.md` survives the round trip —
including the `#`, which is the character that would otherwise truncate the
address at the file name.

Restoring inverts who owns the address bar, and getting that backwards was the
bug. A click is what puts the browser somewhere new, so a click writes the URL
immediately, before the network. A restore must not: `selectRepo` writes the URL
before it fetches, and the file is fetched only once the branch list has landed
and corrected the ref — so the write encoded a state with no file in it yet, and
opening a link to a file replaced that link with the repository root before the
file had loaded. The same write dropped an issue number. A restore therefore
writes at the *end*, once the target has been applied, and with `replace()`:
what comes back may not be what was asked for — a deleted branch falls back to
the default, an issue number that does not exist stays null — and a correction
is not somewhere anyone should have to press Back through. A blob URL also has
to set the directory the file sits in, which is what the click path leaves on
screen and so what a link to it has to reproduce.

Verified in a browser against a live instance, not by reading the code: the hash
follows a click into a directory, a file, a tag, the commit log and an issue;
a reload restores each of them, listing included; Back and Forward walk the same
sequence in both directions and add no entries of their own. A bookmark that has
outlived its target degrades rather than blanks — a missing repository says
`找不到仓库 <name>` and returns to the list, a missing branch is corrected in
place to the default, a missing file keeps its URL and reports itself in the
panel, a missing issue number falls back to the list. No console errors.

One thing this cost an hour: the page had cached `app.js` under the asset digest
stamped at boot, so the first fix appeared to do nothing. The digest is computed
once at startup by design, which is right for deployment and a trap in
development — a server restart is part of testing a change to `web/`.

### The file listing's other half

A file listing answers two questions and the name only answers one. The second
— who last touched this, and when — is a column beside it now, and it costs one
history walk rather than one per entry.

`browse_last_commits` runs a single `git log --format=… --name-only -z`. Walking
newest first, the FIRST time a name appears is by definition the last commit
that changed it, so one process answers for a whole directory. A `git log -1 --
<entry>` per entry would be exact, and would turn a directory of forty files
into forty forks through a pool that is also serving every other request.

Two things it deliberately does not do, both visible as a blank cell rather than
a wrong one: the walk stops after 400 commits, so a file nobody has touched in
that long comes back unattributed instead of making the listing wait for a full
traversal; and `--name-only` prints nothing for a merge commit, so a change that
only ever landed through one is not attributed either. `-z` is not a nicety —
an unquoted name may contain anything but a NUL, newlines included, so nothing
else can be trusted to end one — and the format uses `%x01` and `%x02` rather
than the literal control bytes the other formats in that file carry, since git
substitutes those itself and neither byte then has to survive a trip out through
a command line.

`GET .../lastcommits/:ref/*path` is its own endpoint rather than more of the
tree response, because it costs a history walk and a listing does not. The
browser paints the names as soon as the tree lands and fills this in when it
arrives, so a slow or failed walk leaves a column blank instead of a directory
unreadable — which is the entire reason it is a second request.

In the browser the cells are held in a map REPLACED wholesale by every listing
rather than emptied, so a response still in flight can tell by identity that its
rows are gone. Both tests are needed: the view ticket catches a directory that
has been left, and the identity check catches a listing reloaded in place under
the same ticket. The map has no prototype, because a directory can hold a file
called `__proto__`. A breadcrumb replaced the "up one level" button, which could
only ever undo the last step; and `relativeTime` rounds DOWN at every step,
because "1 天前" for something 23 hours old reads as a day of staleness that has
not happened yet — the exact time is on the `title` of every one of them.

**One real bug in the CSS, and it had been there the whole time.** Every row in
the file listing and the commit list is a `<button>`, and a button that is not
told otherwise keeps the platform's own chrome: a grey face, a 1.6px outset
border, and — under `display: flex` — a shrink-to-fit width. That is what made
those rows a staircase of grey boxes rather than a list. `.repo-item` had reset
all three since the sidebar existed; these two never did.

**And one the deploy model makes inevitable.** Assets are content-digested and
served immutable, but the page itself is `no-cache` — so a tab left open across
a deploy runs the CURRENT script against OLD markup, and every element that
deploy added is null. Three had just arrived (`issue-count-badge`,
`path-crumbs`, `tree-latest`), and any one of them would have taken the file
listing down with it. They are guarded now, and the `tree-latest` reset goes
through `renderTreeLatest` rather than touching the node: a control that has not
shipped to that tab should cost its own feature, not the listing it happens to
be rendered next to.

`test/smoke.sh` asserts the column against the two commits the suite already
makes — `initial commit` touched README.md, src/app.lua and binary.dat, and
`second` touched only README.md — so the two answers have to differ, and a walk
that simply attributed the tip commit to everything would pass a weaker
assertion. Plus a directory attributed by what happened inside it (`src` itself
never appears in a commit, only `src/app.lua` does), the directory's own newest
commit, scoping to a subdirectory and excluding its siblings, an unknown ref, a
traversing path, and the private-repository visibility loop, which gained the
new route. Nine cases: 206 to 215 on Windows.

### Two pages, where there was one rail

The browser was a single page with a permanent left rail — a repository list
holding 286px whether or not anybody was choosing from it, and a "select a
repository" empty state taking most of the rest. It is two pages now: the
landing page is an account overview, and a repository is a page of its own, the
way GitHub and gitea both arrange it. The list only earns screen space while
somebody is choosing from it.

Nothing on the server changed. This is `web/` and one line of the smoke suite.

The overview is a profile column and a grid of cards. Cards rather than rows,
because a description is what tells you which repository you want and a row
truncates it to nothing; each card carries `owner/name` in full, since one
instance can hold the same name under two accounts and the card is the only
place that disambiguates them. Signed out it still says something true — this is
the instance, and what is listed is what anybody may read — rather than going
blank until somebody logs in. The search box moved into the listing's own
header, where the thing it filters is.

On the repository page the About column — description, default branch,
visibility, clone URL — is Code-only, the way GitHub has it: on Issues or the
commit log it would be describing something you are not looking at. Hiding it is
not enough, because the grid has to give the column back or the log and the
issue list stay squeezed into two thirds of the page. The owner in the
breadcrumb is the way back to the listing now that there is no rail to click.

`repoIcon()` builds its SVG per call rather than cloning one node: an SVG in the
DOM is a node like any other, and two cards cannot hold the same one. Both pages
collapse the same way at 980px — the side column stops being a column and
becomes a block above what it describes (the profile) or below it (About) — and
at 620px the code toolbar wraps, rather than squeezing the breadcrumb until the
directory you are standing in is unreadable.

### Provisioning an account, without leaving the browser

Collaborators shipped on 2026-09-04 and the panel that grants access has always
needed an account that already exists. There was no way to make one.
`GET` and `POST /api/v1/users` were there from the start and had no control
anywhere in `web/`, so adding the second person to a two-person instance meant a
terminal and a curl — the same shape as the repository create button before it,
one level up: the action every other multi-account feature depends on was the
one the page could not do.

**The bit the page could not know.** `syncWriteActions` carried a comment saying
so — the browser knew the signed-in username and had no administrator
capability, so it showed owner-only controls and left an administrator to the
API. The obvious fix is to put the flag in the login response and keep it beside
the token, and it is wrong: the page would be repeating a claim nobody checked,
and it would go on being true in that tab after the account lost the bit,
drawing controls whose every request then 403s with no explanation.

So `GET /api/v1/user` answers who the caller is — username, admin, email,
created_at, and nothing that is or verifies a credential. `loadSelf` asks it on
load and after a login, and `clearCredentials` drops the answer. One request per
load, and only when there is a credential to ask with; an anonymous visitor
still makes none. It also turns out to be where a stored token that has expired
is found, since `api()` already routes a 401 into the "session expired" path —
previously that discovery happened on whichever panel loaded first.

With the flag real, the owner-only controls include the administrator, which is
what the server has always enforced: `rec.owner ~= user.username and not
user.admin` guards update and delete alike, so hiding them from an administrator
never protected anything.

**The recovery code is why this needs a panel rather than a link to the docs.**
`POST /api/v1/users` returns one with the account, and the server keeps only its
hash — so that response is the single copy that will ever exist, and an
administrator who closes the tab has taken the new account's only way back from
a forgotten password with them. It gets its own block, warning-coloured rather
than accent-coloured because it is the one thing on that screen that cannot be
fetched again, and it stays on screen while the listing reloads underneath it —
which is why it is not part of the list. Reopening the panel clears it: shown
once means shown once, and a code left over from an earlier account would read
as this one's.

The form clears itself the moment the request succeeds. An administrator types
an initial password for somebody else here, and it is the one field on the page
that must not still be in the DOM when the next person looks at that screen.

**What it deliberately does not do is delete.** An account owns repositories and
has signed its name to issues, and where those go is a decision, not a button —
gitea refuses to delete an account that still holds repositories, which is one
answer among several. Listing and creating is the whole of it, and the panel
says so rather than leaving the gap to be discovered.

Five smoke cases for the endpoint — no credentials is 401, an administrator is
told so, an ordinary account is told so, a token answers the same question as
the password behind it, and the response carries no token list, `pwhash` or
recovery material — plus three static checks pairing the panel's markup with its
handler, the way each panel before it is covered. 215 to 223 on Windows.

Verified in a browser against a live instance: signed out there is no account
control and no `/api/v1/user` request at all; an administrator gets the button
and `已登录 · 管理员`; the panel lists `admin` with its badges, creates `nina`,
shows the recovery code and keeps it while the listing refreshes beneath it;
the form comes back empty, password included; a second `nina` is refused with
`这个用户名已经有人用了` rather than a bare 400; signing in as `nina` there is no
account button and no `管理员`; and a reload restores the administrator's
controls from the server rather than from anything the tab had stored. The only
console error in the whole run was the deliberate duplicate.

### Comparing two revisions

The reading half of a pull request, built before the writing half because it is
useful on its own — what has this branch got that the trunk has not — and
because it settles the semantics the rest of a pull request is built on while
nothing depends on them yet.

**Three dots, not two, and that is the whole design.** A comparison starts where
the two histories last agreed — the merge base — and not at the tip of base.
Diffing the two tips reports everything that landed on base while the branch was
away and attributes all of it to the branch. In the smoke repository `main` gains
a line in README.md after `side` branches off, and a two-dot `git diff main side`
answers:

    M  README.md
    D  c.txt
    A  side.txt

Two of those three are somebody else's work described backwards. The compare
endpoint returns `side.txt` alone, and the case asserting README.md's ABSENCE is
the only one in the block that a two-dot implementation would fail — every other
check there passes either way, which is worth knowing about a test that looks
like five.

**The merge base is computed by us, in its own step.** `git diff base...head`
would do it in one, and two things are lost that way. The merge base is worth
reporting on its own — it is the answer to "what is this branch measured
against" — and when two histories share no ancestor at all the three-dot form is
not an empty answer but a fatal error:

    $ git diff --name-status main...lonely
    fatal: main...lonely: no merge base

That is a real state — an orphan branch pushed into an existing repository — so
`browse_merge_base` returns nil for it, the comparison falls back to the tip of
base, and the response carries `unrelated: true`. Named rather than left to be
inferred from a null merge base, because the answer below it is a different
comparison from the one that was asked for and the caller should not have to
work that out. The browser leads its summary with it for the same reason.

`ahead`/`behind` come from `rev-list --left-right --count base...head`, whose
symmetric difference is defined with or without a common ancestor and so needs
no fallback of its own. The commit list is `browse_log` with a new `exclude`
option — `^<oid>`, the thing that turns a walk over one history into the commits
one revision has and another does not — so it inherits the paging and the cap
that were already there.

`GET .../compare/:base/:head` puts the two ends in their own URL segments rather
than following GitHub's `base...head`. A branch name may contain a slash and
already has to arrive percent-encoded inside one segment; a separator inside
that segment would be a second thing to escape and a second thing to get wrong.

Both ends go through `resolve_ref` like every other browsing endpoint, so
neither reaches a command line as the text the client sent. These two oids are
nonetheless the only values in `browse.lua` that get CONCATENATED into a
revision expression rather than passed as their own argv entry, and
`--end-of-options` does not protect the inside of a range — so the hex shape is
checked again at the point of use.

**Two things came out of the refactor rather than the feature.** The
`--name-status -z` parser, whose stride depends on the status letter (a rename
carries two paths), was about to exist twice; it is `parse_name_status` now, used
by the per-commit file list and the compare alike. And `browse_diff`'s cap was
inline, so a comparison — a far easier way to ask for an enormous patch than any
single commit — would have been the one path that forgot `MAX_DIFF_MB`. Both go
through `capture_patch`, which means both answer 413 the same way.

**In the browser** it is a fourth tab: two ref selects, a summary, the changed
files, and the commits. The patch is not fetched with the comparison, because a
long-lived branch is a large one and the file list beside it costs nothing —
a file row loads that file's patch, a commit row loads that commit's, and one
button loads the whole thing. When the whole thing is over `MAX_DIFF_MB` the
panel says so and points at the per-file rows, which is a normal outcome here
rather than a fault.

`#/<owner>/<name>/compare/<base>/<head>` is in the address bar, written on every
selector change. A comparison nobody can paste to anybody is most of the point
of one missing.

**What building it found, in code that had nothing to do with it.**
`.commit-subject` is a `<span>` inside a grid ITEM — the item is blockified, its
children are not — so as an inline box every property in its rule was inert: no
margin below it, no ellipsis, no `nowrap`, and no line break, which ran the
subject straight into the author's name. Every commit in the log has read
`base three after branchingt · 6f30246` since the commit log shipped, and it was
only noticed because the comparison renders the same rows and they were being
looked at closely. One `display: block`.

The other is a hazard rather than a bug. `addEventListener` on a null node
throws at PARSE time and takes every listener registered after it down with it,
so a tab left open across the deploy that adds a panel loses the whole page
rather than one feature — the same failure `44035f2` fixed for reads, still open
for listeners. The compare view's own listeners go through an `on()` helper that
checks; the ones that predate it do not, and retrofitting them is its own change.

**And one in the suite itself, which is the one worth remembering.** The compare
cases branch `side` off the root commit, so they had to ask where the root
commit was — and the answer the suite already had was wrong. `root` was the LAST
`"oid":` in the commit-listing response, and that response carries an `oid` of
its own beside the array (the resolved ref), so which commit came out depended
on Lua's key order, which is not promised. It had been landing on the tip. Both
cases that used it passed anyway: README.md is one line long, so the tip's patch
carries `hello gitloom` as context exactly as the root's does, and "the initial
commit must list its files" is true of any commit that touched one. A fixture
that is wrong half the time and two assertions that cannot tell the difference
are the same bug twice. It comes from `git rev-list --max-parents=0` now, and
the patch case asks for `src/app.lua`, which only the initial commit adds.

Verified against a live instance, in a browser: `#/admin/cmp/compare/main/feature`
restores from the address bar with both selects set; the summary reads 领先 2 ·
落后 1 · 2 个文件; the file list holds `a.txt` and `f1.txt` and NOT the file main
gained after the branch left; clicking a file opens that file's patch, coloured;
switching the head to an orphan branch leads with 这两条历史没有共同祖先 and falls
back rather than erroring; comparing `main` with itself says so instead of
showing an empty table; the hash follows every change and Back walks the three
comparisons in order. No console errors.

## Phase 3 — collaboration

Organisations and teams, then issues (comments, labels, milestones), then pull
requests. Server-authored sideband messages land here too — the band-2
`remote:` lines that tell a pusher why a branch was refused, or where to open a
pull request. The transport for them already works; what is missing is anything
worth saying, which arrives with protected branches and review.

PRs are the heavy part. Their READING half is done and shipped as the compare
view above — merge base, ahead/behind, the commits and the files one branch
would add — so what is left is the writing half: conflict detection, three merge
strategies, and a review state machine. A pull request on top of this is a
record with a state, two refs and a discussion; the question "what would this
merge" is already answered.

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
