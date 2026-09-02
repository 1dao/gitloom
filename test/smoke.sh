#!/bin/sh
# test/smoke.sh — end-to-end check of the git smart-HTTP transport and the API.
#
# Starts a gitloom on a scratch port with a scratch REPO_ROOT/DATA_DIR, drives a
# real `git` client against it, and tears everything down. Nothing in the
# working tree is touched.
#
#   sh test/smoke.sh                  run against a fresh instance on port 18686
#   PORT=9000 sh test/smoke.sh        pick the port
#   GIT_STREAM=off sh test/smoke.sh   force the file-staging transport
#   BIG_MB=0 sh test/smoke.sh         skip the large-clone case (see below)
#
# Exit code 0 = every case passed.

set -u
cd "$(dirname "$0")/.." || exit 1

PORT="${PORT:-18686}"
BASE="http://127.0.0.1:$PORT"
ADMIN_PW="smoke-test-password"
WORK="$(mktemp -d 2>/dev/null || echo "./tmp/smoke.$$")"
ROOT="$WORK/repos"
DATA="$WORK/data"
SCRATCH="$WORK/tmp"
LOG="$WORK/gitloom.log"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s :: %s\n' "$1" "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got=$2 want=$3"; fi; }

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    # A failed run is worth reading; a clean one is not.
    if [ "$fail" -ne 0 ]; then printf '\n--- server log (%s) ---\n' "$LOG"; tail -40 "$LOG"; fi
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOT" "$DATA" "$SCRATCH"

# Pick the runtime by PLATFORM, not by which file happens to be executable.
# Both binaries are committed, so an exec-bit probe would hand Linux the PE
# binary the moment someone types the natural `chmod +x bin/*`.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) XNET=bin/xnet.exe ;;
    *)                             XNET=bin/xnet     ;;
esac
[ -f "$XNET" ] || { echo "no runtime at $XNET — it ships in bin/, see README"; exit 2; }
[ -x "$XNET" ] || { echo "$XNET is not executable — run: chmod +x $XNET"; exit 2; }

"$XNET" main.lua \
    LISTEN_PORT="$PORT" REPO_ROOT="$ROOT" DATA_DIR="$DATA" TMP_DIR="$SCRATCH" \
    USERS_FILE="$DATA/users.json" ADMIN_USER=admin ADMIN_PASSWORD="$ADMIN_PW" \
    GIT_STREAM="${GIT_STREAM:-auto}" \
    TRUSTED_PROXIES=127.0.0.1 \
    > "$LOG" 2>&1 &
PID=$!

# Poll rather than sleep a fixed amount: the boot does a git --version through
# the worker pool, and how long that takes varies a lot between machines.
i=0
while [ $i -lt 100 ]; do
    curl -sf "$BASE/api/v1/version" >/dev/null 2>&1 && break
    kill -0 "$PID" 2>/dev/null || { echo "server exited during boot"; tail -30 "$LOG"; exit 2; }
    i=$((i+1)); sleep 0.2
done
[ $i -lt 100 ] || { echo "server did not answer within 20s"; tail -30 "$LOG"; exit 2; }

# Every credential path must fail fast. GIT_TERMINAL_PROMPT stops the console
# prompt, but on Windows a configured credential helper (Git Credential Manager)
# opens a GUI dialog instead and the test hangs forever with no output. Clearing
# credential.helper with an empty value resets the whole inherited list, so no
# helper runs at all; GCM_INTERACTIVE covers a helper configured somewhere this
# override cannot reach.
export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never
GIT="git -c credential.helper= -c credential.interactive=false -c protocol.version=2"

# ── API ─────────────────────────────────────────────────────────────────────
curl -s "$BASE/api/v1/version" | grep -q '"name":"gitloom"' \
    && ok 'version endpoint' || bad 'version endpoint' "$(curl -s "$BASE/api/v1/version")"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d '{"name":"nope"}' "$BASE/api/v1/repos")
check 'create without credentials is 401' "$code" '401'

code=$(curl -s -o /dev/null -w '%{http_code}' -u admin:wrong-password -X POST \
    -H 'Content-Type: application/json' -d '{"name":"nope"}' "$BASE/api/v1/repos")
check 'create with a bad password is 401' "$code" '401'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST \
    -H 'Content-Type: application/json' -d '{"name":"demo","description":"smoke"}' \
    "$BASE/api/v1/repos")
check 'create repository is 201' "$code" '201'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST \
    -H 'Content-Type: application/json' -d '{"name":"demo"}' "$BASE/api/v1/repos")
check 'duplicate name is rejected' "$code" '400'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST \
    -H 'Content-Type: application/json' -d '{"name":"../escape"}' "$BASE/api/v1/repos")
check 'path traversal in a name is rejected' "$code" '400'

curl -s "$BASE/api/v1/repos" | grep -q '"count":1' \
    && ok 'listing shows the repository' || bad 'listing shows the repository' "$(curl -s "$BASE/api/v1/repos")"

curl -s "$BASE/api/v1/repos/admin/demo" | grep -q '"empty":true' \
    && ok 'new repository reports empty' || bad 'new repository reports empty' "$(curl -s "$BASE/api/v1/repos/admin/demo")"

# ── Transport ───────────────────────────────────────────────────────────────
ANON="$BASE/admin/demo.git"
AUTH="http://admin:$ADMIN_PW@127.0.0.1:$PORT/admin/demo.git"

$GIT clone -q "$ANON" "$WORK/w1" 2>"$WORK/e1" \
    && ok 'anonymous clone of an empty repository' \
    || bad 'anonymous clone of an empty repository' "$(cat "$WORK/e1")"

(
    cd "$WORK/w1" || exit 1
    printf 'hello gitloom\n' > README.md
    mkdir -p src && printf 'print("hi")\n' > src/app.lua
    # 64 KiB of every byte value: proves the packfile survives the file staging
    # on both sides, which is the whole risk of the redirect-through-disk design.
    "$(command -v python3 || command -v python)" -c \
        "import sys;sys.stdout.buffer.write(bytes(range(256))*256)" > binary.dat 2>/dev/null \
        || head -c 65536 /dev/urandom > binary.dat
    git add -A
    git -c user.email=smoke@test -c user.name=smoke commit -qm 'initial commit'
) || { bad 'build a commit' 'setup failed'; }

( cd "$WORK/w1" && $GIT push -q "$ANON" HEAD:refs/heads/main 2>"$WORK/e2" )
if [ $? -ne 0 ]; then ok 'anonymous push is refused'
else bad 'anonymous push is refused' 'push succeeded without credentials'; fi

( cd "$WORK/w1" && $GIT push -q "$AUTH" HEAD:refs/heads/main 2>"$WORK/e3" ) \
    && ok 'authenticated push' || bad 'authenticated push' "$(cat "$WORK/e3")"

$GIT clone -q "$ANON" "$WORK/w2" 2>"$WORK/e4" \
    && ok 'clone after push' || bad 'clone after push' "$(cat "$WORK/e4")"

if cmp -s "$WORK/w1/binary.dat" "$WORK/w2/binary.dat"; then
    ok 'binary blob survives the round trip'
else
    bad 'binary blob survives the round trip' 'files differ'
fi
[ -f "$WORK/w2/src/app.lua" ] && ok 'subdirectory restored' || bad 'subdirectory restored' 'missing src/app.lua'

# Incremental fetch: a second commit must arrive without a full re-clone.
(
    cd "$WORK/w1" && printf 'second line\n' >> README.md && git add -A &&
    git -c user.email=smoke@test -c user.name=smoke commit -qm 'second' &&
    $GIT push -q "$AUTH" HEAD:refs/heads/main
) >/dev/null 2>&1
( cd "$WORK/w2" && $GIT pull -q "$ANON" main >/dev/null 2>&1 &&
  grep -q 'second line' README.md ) \
    && ok 'incremental fetch' || bad 'incremental fetch' 'second commit did not arrive'

curl -s "$BASE/api/v1/repos/admin/demo" | grep -q 'refs/heads/main' \
    && ok 'refs appear in the API' || bad 'refs appear in the API' "$(curl -s "$BASE/api/v1/repos/admin/demo")"

# ── Private repositories ────────────────────────────────────────────────────
curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"name":"secret","private":true}' "$BASE/api/v1/repos" >/dev/null

$GIT clone -q "$BASE/admin/secret.git" "$WORK/w3" 2>/dev/null
if [ $? -ne 0 ]; then ok 'private repository is not anonymously clonable'
else bad 'private repository is not anonymously clonable' 'clone succeeded'; fi

$GIT clone -q "http://admin:$ADMIN_PW@127.0.0.1:$PORT/admin/secret.git" "$WORK/w4" 2>"$WORK/e5" \
    && ok 'owner can clone a private repository' \
    || bad 'owner can clone a private repository' "$(cat "$WORK/e5")"

# A non-owner must not even learn that it exists.
curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"username":"bob","password":"bob-password-1"}' "$BASE/api/v1/users" >/dev/null
code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 \
    "$BASE/api/v1/repos/admin/secret")
check 'private repository is 404 to another account' "$code" '404'

# ── Access tokens ───────────────────────────────────────────────────────────
TOKEN=$(curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"label":"smoke"}' "$BASE/api/v1/user/tokens" |
    sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')
if [ -n "$TOKEN" ]; then
    ok 'token issued'
    $GIT clone -q "http://admin:$TOKEN@127.0.0.1:$PORT/admin/secret.git" "$WORK/w5" 2>"$WORK/e6" \
        && ok 'token authenticates a clone' \
        || bad 'token authenticates a clone' "$(cat "$WORK/e6")"
else
    bad 'token issued' 'no token in the response'
fi

# ── Protocol edge cases ─────────────────────────────────────────────────────
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/admin/demo.git/info/refs")
check 'dumb protocol is refused' "$code" '403'

code=$(curl -s -o /dev/null -w '%{http_code}' \
    "$BASE/admin/nosuch.git/info/refs?service=git-upload-pack")
check 'unknown repository is 401 to anonymous' "$code" '401'

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: text/plain' -d 'x' "$BASE/admin/demo.git/git-upload-pack")
check 'wrong content type is 415' "$code" '415'

# == Browsing =================================================================
# The demo repository already has two commits, a subdirectory and a binary blob
# from the transport section above.

DEMO="$BASE/api/v1/repos/admin/demo"

curl -s "$DEMO/branches" | grep -q '"name":"main"' \
    && ok 'branches lists main' || bad 'branches lists main' "$(curl -s "$DEMO/branches")"

# HEAD is corrected after a push whose branch is not the recorded default, so a
# clone checks out a worktree instead of landing on a dangling ref.
curl -s "$DEMO" | grep -q '"default_branch":"main"' \
    && ok 'default branch tracks what was pushed' || bad 'default branch tracks what was pushed' "$(curl -s "$DEMO")"

curl -s "$DEMO/tree/main" | grep -q '"name":"src"' \
    && ok 'tree lists the root' || bad 'tree lists the root' "$(curl -s "$DEMO/tree/main")"
curl -s "$DEMO/tree/main/src" | grep -q '"name":"app.lua"' \
    && ok 'tree lists a subdirectory' || bad 'tree lists a subdirectory' "$(curl -s "$DEMO/tree/main/src")"

# Directories sort before files, which git does not do for us.
first=$(curl -s "$DEMO/tree/main" | sed -n 's/.*"entries":\[{[^}]*"type":"\([a-z]*\)".*/\1/p')
check 'tree sorts directories first' "$first" 'tree'

curl -s "$DEMO/raw/main/README.md" | grep -q 'hello gitloom' \
    && ok 'raw serves file contents' || bad 'raw serves file contents' "$(curl -s "$DEMO/raw/main/README.md" | head -c 60)"

# A blob is streamed byte-for-byte, same as the packfile path.
curl -s "$DEMO/raw/main/binary.dat" -o "$WORK/raw.dat"
cmp -s "$WORK/raw.dat" "$WORK/w1/binary.dat" \
    && ok 'raw blob is byte-identical' || bad 'raw blob is byte-identical' 'files differ'

# An unknown extension must not be renderable by the browser.
curl -s -D- -o /dev/null "$DEMO/raw/main/binary.dat" | grep -qi 'content-type: application/octet-stream' \
    && ok 'unknown type is octet-stream' || bad 'unknown type is octet-stream' 'wrong content type'
curl -s -D- -o /dev/null "$DEMO/raw/main/binary.dat" | grep -qi 'x-content-type-options: nosniff' \
    && ok 'raw sends nosniff' || bad 'raw sends nosniff' 'header missing'

curl -s "$DEMO/commits?ref=main&limit=1" | grep -q '"count":1' \
    && ok 'commits honours limit' || bad 'commits honours limit' "$(curl -s "$DEMO/commits?ref=main&limit=1")"

# The initial commit must list its files. diff-tree compares against the first
# parent, and a root commit has none, so this is zero without --root.
root=$(curl -s "$DEMO/commits?ref=main&limit=50" | grep -o '"oid":"[0-9a-f]*"' | tail -1 | cut -d'"' -f4)
curl -s "$DEMO/commits/$root" | grep -q '"files":\[{' \
    && ok 'root commit lists its files' || bad 'root commit lists its files' "$(curl -s "$DEMO/commits/$root" | grep -o '"files":[^]]*.')"

# The diff endpoint returns patch content for the same resolved commit. The
# initial commit is important here: it exercises the --root path rather than a
# normal parent-to-child diff.
curl -s "$DEMO/commits/$root/diff" | grep -q '"diff":".*hello gitloom' \
    && ok 'commit diff returns patch content' || bad 'commit diff returns patch content' "$(curl -s "$DEMO/commits/$root/diff" | head -c 240)"

# A path filter is decoded before it reaches git, and a traversal attempt is
# rejected just like the tree/raw browsing endpoints.
curl -s "$DEMO/commits/$root/diff?path=README.md" | grep -q '"path":"README.md"' \
    && ok 'commit diff honours a path filter' || bad 'commit diff honours a path filter' "$(curl -s "$DEMO/commits/$root/diff?path=README.md")"
code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$DEMO/commits/$root/diff?path=%2e%2e%2fgitloom.cfg")
check 'commit diff rejects a traversal path' "$code" '400'

# An empty list stays an array, like refs.
curl -s "$DEMO/tags" | grep -q '"tags":\[\]' \
    && ok 'empty tag list is []' || bad 'empty tag list is []' "$(curl -s "$DEMO/tags")"

# -- injection --------------------------------------------------------------
# A ref beginning with '-' is read by git as an option; --output= would write a
# file. Every one of these must be refused, and none may have a side effect.
rm -f "$WORK/pwned"
for r in '--output=%2Ftmp%2Fpwned' '-a' '--upload-pack=touch' 'HEAD%40%7B1%7D' '%2e%2e'; do
    code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$DEMO/tree/$r")
    check "ref injection refused: $r" "$code" '404'
done
[ -e "$WORK/pwned" ] && bad 'ref injection had no side effect' 'a file was created' \
                     || ok 'ref injection had no side effect'

# --path-as-is, or curl collapses the dot segments before they reach us and the
# test proves nothing about the server.
for pth in '..%2f..%2fgitloom.cfg' '%2e%2e/%2e%2e/etc/passwd' '.git/config' '-rf'; do
    code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$DEMO/raw/main/$pth")
    check "path traversal refused: $pth" "$code" '400'
done

# Browsing obeys the same visibility rule as the transport.
for ep in branches tags commits tree/main; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/repos/admin/secret/$ep")
    check "private repo hidden from browsing: $ep" "$code" '404'
done
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" "$BASE/api/v1/repos/admin/secret/branches")
check 'owner can browse a private repository' "$code" '200'

# == Regressions ==============================================================
# One case per finding from the 2026-08-30 review. Each of these passed silently
# before the fix, so they are the cheapest guard against a reintroduction.

# Bad credentials must not be quietly downgraded to an anonymous request.
code=$(curl -s -o /dev/null -w '%{http_code}' -u admin:definitely-wrong "$BASE/api/v1/repos")
check 'bad credentials on a public listing are 401' "$code" '401'
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/repos")
check 'no credentials on a public listing are 200' "$code" '200'

# Refusing a DELETE must not confirm that a private repository exists: the
# answer has to match what GET gives the same caller.
get=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 "$BASE/api/v1/repos/admin/secret")
del=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 -X DELETE "$BASE/api/v1/repos/admin/secret")
check 'DELETE does not leak private repository existence' "$del" "$get"

# An empty ref list is an array, not an object, or the field changes JSON type
# depending on whether the repository has commits.
curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json'     -d '{"name":"emptyrepo"}' "$BASE/api/v1/repos" >/dev/null
curl -s "$BASE/api/v1/repos/admin/emptyrepo" | grep -q '"refs":\[\]'     && ok 'empty refs serialise as []'     || bad 'empty refs serialise as []' "$(curl -s "$BASE/api/v1/repos/admin/emptyrepo" | grep -o '"refs":[^,]*')"

# Windows device names and trailing dots are rejected by validation, not by git
# failing three calls later with the server's absolute path in the message.
for n in CON NUL COM1 AUX LPT1 con; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST         -H 'Content-Type: application/json' -d "{\"name\":\"$n\"}" "$BASE/api/v1/repos")
    check "reserved device name $n is rejected" "$code" '400'
done
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST     -H 'Content-Type: application/json' -d '{"name":"trailingdot."}' "$BASE/api/v1/repos")
check 'a trailing dot is rejected' "$code" '400'

# Index keys are case-folded, so a name differing only in case collides.
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST     -H 'Content-Type: application/json' -d '{"name":"EmptyRepo"}' "$BASE/api/v1/repos")
check 'a case-variant name collides' "$code" '400'

# No error may carry the server's filesystem layout back to a client.
body=$(curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json'     -d '{"name":"emptyrepo"}' "$BASE/api/v1/repos")
echo "$body" | grep -qiE '[a-z]:[/\]|/home/|/root/|/users/'     && bad 'errors do not disclose server paths' "$body"     || ok 'errors do not disclose server paths'

# Repeated bad credentials must be locked out rather than costing a KDF run each.
locked=no
i=0
while [ $i -lt 25 ]; do
    c=$(curl -s -o /dev/null -w '%{http_code}' -u "lockme:wrong-$i" "$BASE/api/v1/users")
    [ "$c" = "429" ] && { locked=yes; break; }
    i=$((i+1))
done
check 'repeated credential failures are locked out' "$locked" 'yes'
# The lockout is per-account and per-address, and must not take the admin's
# own working credential down with it on a different account... the address is
# shared here, so simply assert the lockout response carries Retry-After.
curl -s -D- -o /dev/null -u "lockme:wrong-again" "$BASE/api/v1/users" | grep -qi '^retry-after:'     && ok 'lockout sends Retry-After' || bad 'lockout sends Retry-After' 'header missing'

# git children must not inherit the operator's git configuration.
grep -q 'GIT_CONFIG_NOSYSTEM' "$LOG" 2>/dev/null || true
[ -d "$DATA/githome" ] && ok 'isolated git HOME was created'     || bad 'isolated git HOME was created' "no $DATA/githome"

# == Large clone ==============================================================
# The case 70 small tests missed.
#
# Every repository above is a few KiB, and at that size the response never fills
# the connection's send buffer. Streaming a 60 MiB clone did: send_raw started
# refusing writes, a chunk lost one of its three parts, and the client aborted
# with "Malformed encoding found in chunked-encoding" — while the whole suite
# stayed green. Anything at or above the 10 MiB default cap reproduces it, so
# this uses enough to clear the cap with room to spare.
#
# BIG_MB=0 skips it. The data is incompressible on purpose: compressible filler
# packs down below the threshold and proves nothing.
BIG_MB="${BIG_MB:-24}"
if [ "$BIG_MB" -gt 0 ]; then
    curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
        -d '{"name":"large"}' "$BASE/api/v1/repos" >/dev/null

    ( cd "$WORK" && git init -q big && cd big &&
      i=0
      while [ "$i" -lt "$BIG_MB" ]; do
          head -c 1048576 /dev/urandom > "blob$i.bin"
          i=$((i+1))
      done
      git add -A
      git -c user.email=smoke@test -c user.name=smoke commit -qm 'large' ) >/dev/null 2>&1

    ( cd "$WORK/big" && $GIT push -q \
        "http://admin:$ADMIN_PW@127.0.0.1:$PORT/admin/large.git" HEAD:refs/heads/main ) \
        && ok "push ${BIG_MB} MiB" || bad "push ${BIG_MB} MiB" 'push failed'

    if $GIT clone -q "$BASE/admin/large.git" "$WORK/bigclone" 2>"$WORK/ebig"; then
        ok "clone ${BIG_MB} MiB"
        # Byte-identical, not merely present: a truncated chunk stream can still
        # produce a repository that looks plausible.
        if cmp -s "$WORK/big/blob0.bin" "$WORK/bigclone/blob0.bin"; then
            ok 'large clone is byte-identical'
        else
            bad 'large clone is byte-identical' 'content differs'
        fi
        n=$(ls "$WORK/bigclone" | grep -c '^blob' || echo 0)
        check 'large clone has every file' "$n" "$BIG_MB"
        ( cd "$WORK/bigclone" && git fsck --no-progress >/dev/null 2>&1 ) \
            && ok 'large clone passes git fsck' || bad 'large clone passes git fsck' 'fsck failed'

        # Connection: close must not truncate the body.
        #
        # Every response leaves the handler QUEUED, not sent — a file response
        # is handed to the C layer, which drains it over many event-loop turns.
        # Closing the connection the moment the handler returned discarded
        # whatever had not reached the socket, so a request that asked for the
        # connection to be closed got a short body and no error. 1 MiB is
        # comfortably more than one buffer's worth; a few KiB proves nothing,
        # which is why the rest of this suite never caught it.
        curl -s -H 'Connection: close' -o "$WORK/blob0.raw" \
            "$BASE/api/v1/repos/admin/large/raw/main/blob0.bin"
        cmp -s "$WORK/big/blob0.bin" "$WORK/blob0.raw" \
            && ok 'Connection: close delivers the whole body' \
            || bad 'Connection: close delivers the whole body' \
                   "got $(wc -c < "$WORK/blob0.raw" 2>/dev/null) of 1048576 bytes"
    else
        bad "clone ${BIG_MB} MiB" "$(cat "$WORK/ebig" | tail -2)"
    fi
fi

# == Fingerprinting and proxy trust ==========================================

# Version numbers are the first thing an automated scanner reads, so anonymous
# callers get liveness without a build number.
body=$(curl -s "$BASE/api/v1/version")
echo "$body" | grep -q '"name":"gitloom"' \
    && ok 'anonymous version says who it is' || bad 'anonymous version says who it is' "$body"
echo "$body" | grep -q '"version"' \
    && bad 'anonymous version hides the build' "$body" \
    || ok 'anonymous version hides the build'
echo "$body" | grep -q '"git"' \
    && bad 'anonymous version hides the git build' "$body" \
    || ok 'anonymous version hides the git build'

body=$(curl -s -u "admin:$ADMIN_PW" "$BASE/api/v1/version")
echo "$body" | grep -q '"version"' \
    && ok 'authenticated version reports the build' \
    || bad 'authenticated version reports the build' "$body"

# Wrong credentials stay a 401 here too: silently downgrading them would tell a
# monitoring probe with a stale password that all is well.
#
# Sent as its own forwarded address. The lockout case above already exhausted
# 127.0.0.1's budget, and without a distinct address this would get the 429 that
# earlier test earned rather than the 401 this one is about.
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 198.51.100.20'     -u admin:wrong-one "$BASE/api/v1/version")
check 'version rejects bad credentials' "$code" '401'

# X-Forwarded-For, honoured because TRUSTED_PROXIES names 127.0.0.1.
#
# The observable behaviour is the credential lockout, which counts per source
# address. Failing repeatedly as ONE forwarded address must not lock out a
# DIFFERENT one — if the header were ignored, both would share 127.0.0.1's
# counter and the second address would be locked out too. Each attempt uses a
# distinct username so the per-username counter cannot be what trips.
i=0
while [ $i -lt 14 ]; do
    curl -s -o /dev/null -H 'X-Forwarded-For: 198.51.100.7' \
        -u "prox$i:wrong-password" "$BASE/api/v1/users"
    i=$((i+1))
done
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 198.51.100.7' \
    -u "proxlast:wrong-password" "$BASE/api/v1/users")
check 'a forwarded address gets locked out' "$code" '429'

code=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 198.51.100.8' \
    -u "otherprox:wrong-password" "$BASE/api/v1/users")
check 'a different forwarded address is unaffected' "$code" '401'

# The rightmost entry is the one the trusted proxy appended; anything to its
# left was supplied by the caller. A client that forges a header must not be
# able to pick which address its failures land on.
code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-Forwarded-For: 198.51.100.9, 198.51.100.7' \
    -u "spoofer:wrong-password" "$BASE/api/v1/users")
check 'a forged left-hand entry does not escape the lockout' "$code" '429'

# == Delete ==================================================================
code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 -X DELETE \
    "$BASE/api/v1/repos/admin/demo")
check 'delete by a stranger is refused' "$code" '403'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X DELETE \
    "$BASE/api/v1/repos/admin/demo")
check 'owner can delete' "$code" '200'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" \
    "$BASE/api/v1/repos/admin/demo")
check 'deleted repository is gone' "$code" '404'

printf '\n[smoke] %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
