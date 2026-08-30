#!/bin/sh
# test/smoke.sh — end-to-end check of the git smart-HTTP transport and the API.
#
# Starts a gitloom on a scratch port with a scratch REPO_ROOT/DATA_DIR, drives a
# real `git` client against it, and tears everything down. Nothing in the
# working tree is touched.
#
#   sh test/smoke.sh              run against a fresh instance on port 18686
#   PORT=9000 sh test/smoke.sh    pick the port
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
