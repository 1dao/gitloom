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
#   TLS_MB=0 sh test/smoke.sh         skip the TLS transfers (see below)
#
#   DB_DRIVER=mysql DB_USER=... DB_PASSWORD=... DB_NAME=... sh test/smoke.sh
#       run the main instance against MySQL instead of JSON files. The database
#       is dropped and recreated first, so every case starts from empty — which
#       is what the counts below assert. The extra instances further down stay
#       on files: what they test is the streaming transport, not the store, and
#       one database shared between three instances is not isolation.
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
# Counts neither way: a check that did not run is not a check that passed, and
# claiming it did is how a tool going missing turns into a green suite.
skip() { printf 'SKIP %s\n' "$1"; }

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    [ -n "${PID2:-}" ] && kill "$PID2" 2>/dev/null
    [ -n "${PID_REG:-}" ] && kill "$PID_REG" 2>/dev/null
    [ -n "${PID_TLS:-}" ] && kill "$PID_TLS" 2>/dev/null
    # A failed run is worth reading; a clean one is not.
    if [ "$fail" -ne 0 ]; then
        printf '\n--- server log (%s) ---\n' "$LOG"; tail -40 "$LOG"
        [ -f "${LOG2:-}" ] && { printf '\n--- second instance (%s) ---\n' "$LOG2"; tail -20 "$LOG2"; }
        [ -f "${LOG3:-}" ] && { printf '\n--- capped instance (%s) ---\n' "$LOG3"; tail -20 "$LOG3"; }
        [ -f "${LOG_TLS:-}" ] && { printf '\n--- TLS instance (%s) ---\n' "$LOG_TLS"; tail -20 "$LOG_TLS"; }
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOT" "$DATA" "$SCRATCH"

# The store under test. Empty means JSON files, which is the default everywhere.
DB_ARGS=""
if [ "${DB_DRIVER:-}" = "mysql" ]; then
    DB_ARGS="DB_DRIVER=mysql DB_HOST=${DB_HOST:-127.0.0.1} DB_PORT=${DB_PORT:-3306}"
    DB_ARGS="$DB_ARGS DB_USER=${DB_USER:-} DB_PASSWORD=${DB_PASSWORD:-}"
    DB_ARGS="$DB_ARGS DB_NAME=${DB_NAME:-gitloom_test}"
fi

# Pick the runtime by PLATFORM, not by which file happens to be executable.
# Both binaries are committed, so an exec-bit probe would hand Linux the PE
# binary the moment someone types the natural `chmod +x bin/*`.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) XNET=bin/xnet.exe ;;
    *)                             XNET=bin/xnet     ;;
esac
[ -f "$XNET" ] || { echo "no runtime at $XNET — it ships in bin/, see README"; exit 2; }
[ -x "$XNET" ] || { echo "$XNET is not executable — run: chmod +x $XNET"; exit 2; }

# A database gitloom is pointed at has to exist, and for these counts to mean
# anything it has to be empty. gitloom never creates one: xmysql names the
# database in its handshake, and a pooled USE would only move one connection.
if [ -n "$DB_ARGS" ]; then
    # shellcheck disable=SC2086
    "$XNET" test/dbreset.lua $DB_ARGS || { echo "could not reset the test database"; exit 2; }
fi

"$XNET" main.lua \
    LISTEN_PORT="$PORT" REPO_ROOT="$ROOT" DATA_DIR="$DATA" TMP_DIR="$SCRATCH" \
    USERS_FILE="$DATA/users.json" ADMIN_USER=admin ADMIN_PASSWORD="$ADMIN_PW" \
    GIT_STREAM="${GIT_STREAM:-auto}" \
    AUTH_ALLOW_REGISTRATION=0 \
    TRUSTED_PROXIES=127.0.0.1 \
    $DB_ARGS \
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

# ── The repository browser ──────────────────────────────────────────────────
# The root is the browser entry point, not the old plain-text landing page.
# Asserted on structure and headers rather than on any of the page's wording,
# which is copy and will change without the server being wrong.
code=$(curl -s -o "$WORK/web.index" -D "$WORK/web.headers" -w '%{http_code}' "$BASE/")
check 'browser entry point is served' "$code" '200'
grep -q 'id="repo-grid"' "$WORK/web.index" \
    && ok 'browser entry point is the page' || bad 'browser entry point is the page' "$(head -c 160 "$WORK/web.index")"
grep -qi '^content-security-policy:' "$WORK/web.headers" \
    && ok 'browser sends a content security policy' || bad 'browser sends a content security policy' 'header missing'
curl -s "$BASE/app.js" | grep -q 'loadRepos' \
    && ok 'browser JavaScript is served' || bad 'browser JavaScript is served' 'asset missing'

# The write controls are markup in one file and behaviour in another, and the
# page is only correct when both shipped. Asserted on the ids rather than on
# any wording, which is copy and will change without the page being wrong.
grep -q 'id="create-dialog"' "$WORK/web.index" \
    && ok 'browser offers repository creation' || bad 'browser offers repository creation' 'dialog missing'
grep -q 'id="delete-dialog"' "$WORK/web.index" \
    && ok 'browser offers repository deletion' || bad 'browser offers repository deletion' 'dialog missing'
grep -q 'id="edit-dialog"' "$WORK/web.index" \
    && ok 'browser offers repository editing' || bad 'browser offers repository editing' 'dialog missing'
grep -q 'id="access-dialog"' "$WORK/web.index" \
    && ok 'browser offers collaborator management' || bad 'browser offers collaborator management' 'dialog missing'
grep -q 'id="issues-view"' "$WORK/web.index" && grep -q 'id="issue-dialog"' "$WORK/web.index" \
    && ok 'browser offers issue tracking' || bad 'browser offers issue tracking' 'panel missing'
grep -q 'id="first-push"' "$WORK/web.index" && grep -q 'id="commit-pagination"' "$WORK/web.index" \
    && ok 'browser offers empty-repository guidance and commit pagination' \
    || bad 'browser offers empty-repository guidance and commit pagination' 'panel missing'
curl -s "$BASE/app.js" | grep -q 'createRepo' \
    && ok 'browser JavaScript can create' || bad 'browser JavaScript can create' 'handler missing'

# Tags were browsable through the API and unreachable in the page: the ref
# selector only ever listed branches, so a release somebody had tagged and
# pushed was invisible. Asserted on the grouping the selector now builds.
curl -s "$BASE/app.js" | grep -q "refGroup" \
    && ok 'browser can select a tag' || bad 'browser can select a tag' 'ref grouping missing'

# The page read every file with response.text() and put the result in a <pre>,
# so a PNG -- which most repositories have -- was a screen of replacement
# characters, and there was no way to download one either. The server had been
# serving image/png correctly the whole time.
curl -s "$BASE/app.js" | grep -q 'createObjectURL' \
    && ok 'browser renders an image as an image' || bad 'browser renders an image as an image' 'blob path missing'
grep -q 'id="download-file"' "$WORK/web.index" \
    && ok 'browser offers a file download' || bad 'browser offers a file download' 'control missing'
# blob: is what an <img> fed from an authenticated fetch needs; without it the
# image is blocked and a private repository shows nothing at all.
grep -qi 'img-src[^;]*blob:' "$WORK/web.headers" \
    && ok 'the policy allows a blob image' || bad 'the policy allows a blob image' "$(grep -i content-security "$WORK/web.headers")"
curl -s "$BASE/app.js" | grep -q "method: 'PATCH'" \
    && ok 'browser JavaScript can edit repository metadata' || bad 'browser JavaScript can edit repository metadata' 'handler missing'
curl -s "$BASE/app.js" | grep -q 'loadCommits(view, skip)' \
    && ok 'browser JavaScript can page commit history' || bad 'browser JavaScript can page commit history' 'handler missing'
curl -s "$BASE/app.js" | grep -q 'loadCollaborators' \
    && ok 'browser JavaScript can manage collaborators' || bad 'browser JavaScript can manage collaborators' 'handler missing'
curl -s "$BASE/app.js" | grep -q 'createIssueComment' \
    && ok 'browser JavaScript can discuss issues' || bad 'browser JavaScript can discuss issues' 'handler missing'

# The whole browser lived at one URL: a refresh went back to the repository
# list, and there was nothing to bookmark or paste to anyone. The address bar
# now carries the state, and these three are what that rests on.
curl -s "$BASE/app.js" | grep -q 'function routeApply' \
    && ok 'browser restores state from the address bar' || bad 'browser restores state from the address bar' 'router missing'
# tree vs blob: the URL cannot otherwise say which one a path is, and guessing
# means a reload of a file link lands in a directory listing instead.
curl -s "$BASE/app.js" | grep -q "state.file ? '/blob/' : '/tree/'" \
    && ok 'a file URL and a directory URL are distinguishable' || bad 'a file URL and a directory URL are distinguishable' 'grammar missing'
# The restore must not write the address bar on its way in. It did, and because
# the file is fetched after the branch list lands, the write encoded a state
# that had no file in it yet -- so opening a link to a file rewrote that link
# to the repository root before the file had loaded.
curl -s "$BASE/app.js" | grep -q 'if (!restoring) routeWrite();' \
    && ok 'restoring does not overwrite the link being restored' || bad 'restoring does not overwrite the link being restored' 'ordering guard missing'

# Opening a file used to leave the listing where it was and stack the file under
# it, so reading one meant scrolling past the directory it came from and there
# was no way across to a neighbour. The code view splits once you step off the
# root: the tree on the left, whatever was clicked on the right. Markup in one
# file and behaviour in the other, so the page is only right when both shipped.
grep -q 'id="code-sidebar"' "$WORK/web.index" && grep -q 'id="side-tree"' "$WORK/web.index" \
    && ok 'browser ships the file tree panel' || bad 'browser ships the file tree panel' 'panel missing'
# Lazily, one directory at a time: every listing forks an ls-tree on the server,
# so walking a repository up front would be a process per directory to draw rows
# nobody asked to see.
curl -s "$BASE/app.js" | grep -q 'function sideLoad' \
    && ok 'the file tree loads a directory at a time' || bad 'the file tree loads a directory at a time' 'lazy load missing'

# A repository page that does not show its README is most of a git front end
# missing. Both parsers are served as their own routes -- see web.lua for why --
# so the page is only whole if all three arrive.
for asset in markdown.js highlight.js; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/$asset")
    [ "$code" = "200" ] && ok "$asset is served" || bad "$asset is served" "HTTP $code"
done
grep -q 'id="readme-panel"' "$WORK/web.index" \
    && ok 'the page has somewhere to render a README' || bad 'the page has somewhere to render a README' 'panel missing'
grep -q 'markdown.js?v=' "$WORK/web.index" && grep -q 'highlight.js?v=' "$WORK/web.index" \
    && ok 'both parsers are stamped with the asset digest' || bad 'both parsers are stamped with the asset digest' 'unstamped'
# The claim these two make is that they never build an HTML string, so a README
# cannot become markup. innerHTML anywhere in either of them voids it.
curl -s "$BASE/markdown.js" "$BASE/highlight.js" | grep -q 'innerHTML\|outerHTML\|insertAdjacentHTML\|document.write' \
    && bad 'neither parser builds markup from repository content' 'innerHTML found' \
    || ok 'neither parser builds markup from repository content'

grep -q 'id="edit-name"' "$WORK/web.index" && grep -q 'id="tokens-dialog"' "$WORK/web.index" \
    && grep -q 'id="search-form"' "$WORK/web.index" \
    && ok 'the browser has controls for rename, tokens and search' || bad 'the browser has controls for rename, tokens and search' 'a control is missing'
# Provisioning an account was API-only, which left collaborators -- a feature
# that needs a second account to mean anything -- reachable only after a curl.
grep -q 'id="users-dialog"' "$WORK/web.index" && grep -q 'id="manage-users"' "$WORK/web.index" \
    && ok 'the browser has an accounts panel' || bad 'the browser has an accounts panel' 'panel missing'
# The panel is administrator-only and the bit is the SERVER's answer. A page
# that stored it beside its token would be repeating a claim nobody checked.
curl -s "$BASE/app.js" | grep -q "json('/api/v1/user')" \
    && ok 'the administrator bit is asked for, not assumed' || bad 'the administrator bit is asked for, not assumed' 'loadSelf missing'
# The initial password for a new account is typed into this page. It must not
# still be sitting in the form when the next person looks at that screen.
curl -s "$BASE/app.js" | grep -q "\$('user-form').reset()" \
    && ok 'the account form is cleared after it is sent' || bad 'the account form is cleared after it is sent' 'reset missing'
# The compare view, and the route that makes one shareable. A comparison nobody
# can paste to anybody is most of the point of it missing.
grep -q 'id="compare-view"' "$WORK/web.index" && grep -q 'id="compare-base"' "$WORK/web.index" \
    && grep -q 'id="compare-head"' "$WORK/web.index" \
    && ok 'the browser has a compare panel' || bad 'the browser has a compare panel' 'panel missing'
curl -s "$BASE/app.js" | grep -q "kind === 'compare'" \
    && ok 'a comparison has its own address' || bad 'a comparison has its own address' 'route missing'
# The API answers in English because git clients read it too, so a form-level
# answer needs its own translation or the dialog shows English mid-sentence.
curl -s "$BASE/app.js" | grep -q 'a repository with that name already exists' \
    && ok 'a rename collision is explained in the interface language' || bad 'a rename collision is explained in the interface language' 'untranslated'
# An issue and a token are stamped in Unix SECONDS; new Date(n) reads
# milliseconds, so every one of them was dated January 1970 in the listing.
curl -s "$BASE/app.js" | grep -q "typeof value === 'number' ? new Date(value \* 1000)" \
    && ok 'a server timestamp is read as seconds, not milliseconds' || bad 'a server timestamp is read as seconds, not milliseconds' 'conversion missing'

# A link destination is a URL, so `[x](my%20docs/a.md)` -- the ordinary way to
# write a link to a file with a space -- names `my docs/a.md`. Encoding it again
# without decoding first produces `my%2520docs`, a path no repository has.
curl -s "$BASE/app.js" | grep -q 'decodeURIComponent(clean)' \
    && ok 'a percent-encoded link destination is decoded once' || bad 'a percent-encoded link destination is decoded once' 'decode missing'
# A README this size is a generated file, and rendering it would build a DOM
# node per construct until the tab stopped responding.
curl -s "$BASE/app.js" | grep -q 'MAX_RENDER_BYTES' \
    && ok 'an oversized Markdown file is shown as source' || bad 'an oversized Markdown file is shown as source' 'guard missing'

# The parsers' own tests. Node is a development convenience, not a dependency of
# gitloom -- nothing in bin/ or app/ needs it -- so this skips where it is absent
# rather than failing, the way the xproc pipe test does.
if command -v node >/dev/null 2>&1; then
    if node "$(dirname "$0")/webjs.js" > "$WORK/webjs.out" 2>&1; then
        ok "browser parsers pass their own tests ($(sed -n 's/^\[webjs\] \([0-9]*\) passed.*/\1/p' "$WORK/webjs.out") checks)"
    else
        bad 'browser parsers pass their own tests' "$(head -c 600 "$WORK/webjs.out")"
    fi
    if node "$(dirname "$0")/webauth.js" > "$WORK/webauth.out" 2>&1; then
        ok 'browser registration workflow passes its own tests'
    else
        bad 'browser registration workflow passes its own tests' "$(head -c 600 "$WORK/webauth.out")"
    fi
else
    skip 'browser parsers pass their own tests (node not installed)'
    skip 'browser registration workflow (node not installed)'
fi
curl -s "$BASE/app.js" | grep -q 'state.repo.owner === state.username' \
    && ok 'browser only offers owner deletion' || bad 'browser only offers owner deletion' 'owner guard missing'
curl -s "$BASE/app.js" | grep -q '/api/v1/user/register' \
    && ok 'browser offers public registration' || bad 'browser offers public registration' 'registration endpoint missing'
if grep -q 'id="auth-register"' "$WORK/web.index" && ! grep -q 'id="register-toggle"' "$WORK/web.index"; then
    ok 'browser reaches registration from under the login form'
else
    bad 'browser reaches registration from under the login form' 'the entry is missing, or the top bar grew a second account button'
fi
curl -s "$BASE/app.js" | grep -q 'requestToken && state.token === requestToken' \
    && ok 'browser guards stale authentication responses' || bad 'browser guards stale authentication responses' 'request credential guard missing'
if grep -q 'id="auth-close"[^>]*type="button"' "$WORK/web.index" &&
   grep -q 'id="create-close"[^>]*type="button"' "$WORK/web.index" &&
   grep -q 'id="delete-close"[^>]*type="button"' "$WORK/web.index" &&
   ! grep -q 'value="cancel" type="submit"' "$WORK/web.index"; then
    ok 'browser keeps dialog cancel controls out of implicit submit'
else
    bad 'browser keeps dialog cancel controls out of implicit submit' 'cancel control is still a submit button'
fi

# A monitor or a reverse proxy sends HEAD at the entry point before anything
# else; it used to be a 404, because only GET was ever routed.
code=$(curl -s -o /dev/null -w '%{http_code}' -I "$BASE/")
check 'HEAD on the entry point' "$code" '200'

# index.html carries the digest of the assets it expects, and only that stamped
# URL is cacheable -- otherwise an upgrade leaves clients on stale JavaScript.
grep -q '__ASSET_VERSION__' "$WORK/web.index" \
    && bad 'asset digest is substituted' 'placeholder left in the page' \
    || ok 'asset digest is substituted'
ASSET_V=$(sed -n 's|.*/app\.js?v=\([0-9a-f][0-9a-f]*\).*|\1|p' "$WORK/web.index" | head -1)
if [ -n "$ASSET_V" ]; then
    curl -s -o /dev/null -D "$WORK/asset.headers" "$BASE/app.js?v=$ASSET_V"
    grep -qi '^cache-control: public, max-age=31536000, immutable' "$WORK/asset.headers" \
        && ok 'a stamped asset is cacheable' \
        || bad 'a stamped asset is cacheable' "$(grep -i '^cache-control' "$WORK/asset.headers")"
    curl -s -o /dev/null -D "$WORK/asset.bare" "$BASE/app.js"
    grep -qi '^cache-control: no-cache' "$WORK/asset.bare" \
        && ok 'an unstamped asset is not cacheable' \
        || bad 'an unstamped asset is not cacheable' "$(grep -i '^cache-control' "$WORK/asset.bare")"
else
    bad 'asset digest is substituted' 'no digest in the page'
fi

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

code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
    -H 'Content-Type: application/json' -d '{"description":"updated smoke"}' \
    "$BASE/api/v1/repos/admin/demo")
check 'update without credentials is 401' "$code" '401'

body=$(curl -s -u "admin:$ADMIN_PW" -X PATCH -H 'Content-Type: application/json' \
    -d '{"description":"updated smoke"}' "$BASE/api/v1/repos/admin/demo")
echo "$body" | grep -q '"description":"updated smoke"' \
    && ok 'owner can update repository description' || bad 'owner can update repository description' "$body"

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PATCH \
    -H 'Content-Type: application/json' -d '{}' "$BASE/api/v1/repos/admin/demo")
check 'empty repository update is rejected' "$code" '400'

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
    git -c user.email=smoke@test -c user.name=smoke commit -qm 'second' -m 'why the second commit happened' &&
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

# ── Collaborator access ─────────────────────────────────────────────────────
# Access is granted to an existing account by the owner, then exercised through
# both the browser-facing API and real smart-HTTP clone/push requests. A reader
# can fetch a private repository but cannot push until promoted to write.
code=$(curl -s -o /dev/null -w '%{http_code}' \
    "$BASE/api/v1/repos/admin/secret/collaborators")
check 'collaborator list without credentials is 401' "$code" '401'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PUT \
    -H 'Content-Type: application/json' -d '{"permission":"read"}' \
    "$BASE/api/v1/repos/admin/secret/collaborators/missing")
check 'unknown collaborator account is rejected' "$code" '404'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PUT \
    -H 'Content-Type: application/json' -d '{"permission":"admin"}' \
    "$BASE/api/v1/repos/admin/secret/collaborators/bob")
check 'invalid collaborator permission is rejected' "$code" '400'

body=$(curl -s -u "admin:$ADMIN_PW" -X PUT -H 'Content-Type: application/json' \
    -d '{"permission":"read"}' \
    "$BASE/api/v1/repos/admin/secret/collaborators/bob")
echo "$body" | grep -q '"username":"bob"' && echo "$body" | grep -q '"permission":"read"' \
    && ok 'owner grants read collaborator access' || bad 'owner grants read collaborator access' "$body"

body=$(curl -s -u "admin:$ADMIN_PW" \
    "$BASE/api/v1/repos/admin/secret/collaborators")
echo "$body" | grep -q '"count":1' && echo "$body" | grep -q '"username":"bob"' \
    && ok 'owner can list collaborators' || bad 'owner can list collaborators' "$body"

code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 \
    "$BASE/api/v1/repos/admin/secret/collaborators")
check 'a collaborator cannot manage the access list' "$code" '403'

code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 \
    "$BASE/api/v1/repos/admin/secret")
check 'read collaborator can browse private repository' "$code" '200'

$GIT clone -q "http://bob:bob-password-1@127.0.0.1:$PORT/admin/secret.git" "$WORK/wbob" 2>"$WORK/ebobclone" \
    && ok 'read collaborator can clone' || bad 'read collaborator can clone' "$(cat "$WORK/ebobclone")"

( cd "$WORK/w1" && $GIT push -q \
    "http://bob:bob-password-1@127.0.0.1:$PORT/admin/secret.git" \
    HEAD:refs/heads/main 2>"$WORK/ebobread" )
if [ $? -ne 0 ]; then ok 'read collaborator cannot push'
else bad 'read collaborator cannot push' 'push succeeded'; fi

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PUT \
    -H 'Content-Type: application/json' -d '{"permission":"write"}' \
    "$BASE/api/v1/repos/admin/secret/collaborators/bob")
check 'owner promotes collaborator to write' "$code" '200'

( cd "$WORK/w1" && $GIT push -q \
    "http://bob:bob-password-1@127.0.0.1:$PORT/admin/secret.git" \
    HEAD:refs/heads/main 2>"$WORK/ebobwrite" ) \
    && ok 'write collaborator can push' || bad 'write collaborator can push' "$(cat "$WORK/ebobwrite")"

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X DELETE \
    "$BASE/api/v1/repos/admin/secret/collaborators/bob")
check 'owner removes collaborator' "$code" '200'

code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 \
    "$BASE/api/v1/repos/admin/secret")
check 'removed collaborator loses access' "$code" '404'

# ── Issues ───────────────────────────────────────────────────────────────────
ISSUES="$BASE/api/v1/repos/admin/demo/issues"
code=$(curl -s -o /dev/null -w '%{http_code}' "$ISSUES")
check 'issue list is public on a public repository' "$code" '200'

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d '{"title":"nope"}' "$ISSUES")
check 'creating an issue without credentials is 401' "$code" '401'

body=$(curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"title":"Track smoke regression","body":"The browser should show this issue."}' "$ISSUES")
echo "$body" | grep -q '"number":1' && echo "$body" | grep -q '"state":"open"' \
    && ok 'owner can create an issue' || bad 'owner can create an issue' "$body"

body=$(curl -s "$ISSUES")
echo "$body" | grep -q '"count":1' && echo "$body" | grep -q 'Track smoke regression' \
    && ok 'issue list returns the new issue' || bad 'issue list returns the new issue' "$body"

body=$(curl -s "$ISSUES/1")
echo "$body" | grep -q 'The browser should show this issue' && echo "$body" | grep -q '"comment_count":0' \
    && ok 'issue detail includes its body' || bad 'issue detail includes its body' "$body"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d '{"body":"nope"}' "$ISSUES/1/comments")
check 'commenting without credentials is 401' "$code" '401'

body=$(curl -s -u bob:bob-password-1 -X POST -H 'Content-Type: application/json' \
    -d '{"body":"I can reproduce this."}' "$ISSUES/1/comments")
echo "$body" | grep -q '"author":"bob"' && echo "$body" | grep -q 'I can reproduce this' \
    && ok 'a signed-in reader can comment on an issue' || bad 'a signed-in reader can comment on an issue' "$body"

code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 -X PATCH \
    -H 'Content-Type: application/json' -d '{"state":"closed"}' "$ISSUES/1")
check 'a reader cannot close somebody else issue' "$code" '403'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PATCH \
    -H 'Content-Type: application/json' -d '{"state":"closed"}' "$ISSUES/1")
check 'owner can close an issue' "$code" '200'

body=$(curl -s "$ISSUES")
echo "$body" | grep -q '"count":0' \
    && ok 'open issue list hides a closed issue' || bad 'open issue list hides a closed issue' "$body"
body=$(curl -s "$ISSUES?state=closed")
echo "$body" | grep -q '"count":1' && echo "$body" | grep -q '"state":"closed"' \
    && ok 'closed issue list returns the issue' || bad 'closed issue list returns the issue' "$body"

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PATCH \
    -H 'Content-Type: application/json' -d '{"state":"unknown"}' "$ISSUES/1")
check 'invalid issue state is rejected' "$code" '400'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PATCH \
    -H 'Content-Type: application/json' -d '{"state":"open"}' "$ISSUES/1")
check 'owner can reopen an issue' "$code" '200'

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

# Omitting ttl_seconds still means a token that never expires -- what a CI job
# wants, and what every token issued before expiry existed already is.
curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"label":"smoke"}' "$BASE/api/v1/user/tokens" | grep -q '"expires_at"' \
    && bad 'a token without a ttl never expires' 'expires_at was set anyway' \
    || ok 'a token without a ttl never expires'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST \
    -H 'Content-Type: application/json' -d '{"ttl_seconds":"soon"}' \
    "$BASE/api/v1/user/tokens")
check 'a non-numeric ttl is refused' "$code" '400'

# ── Who the caller is ───────────────────────────────────────────────────────
# The browser cannot infer the administrator bit from the credential it holds,
# so it asks. Anything else would be the page repeating a claim nobody checked.
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/user")
check 'the caller identity needs credentials' "$code" '401'
body=$(curl -s -u "admin:$ADMIN_PW" "$BASE/api/v1/user")
echo "$body" | grep -q '"username":"admin"' && echo "$body" | grep -q '"admin":true' \
    && ok 'an administrator is told so' || bad 'an administrator is told so' "$body"
body=$(curl -s -u bob:bob-password-1 "$BASE/api/v1/user")
echo "$body" | grep -q '"username":"bob"' && echo "$body" | grep -q '"admin":false' \
    && ok 'an ordinary account is told so' || bad 'an ordinary account is told so' "$body"
# The browser signs in with a token, not a password, so that is the credential
# this endpoint actually sees.
if [ -n "$TOKEN" ]; then
    curl -s -u "admin:$TOKEN" "$BASE/api/v1/user" | grep -q '"admin":true' \
        && ok 'a token answers the same question' || bad 'a token answers the same question' 'no'
else
    bad 'a token answers the same question' 'no token to try'
fi
# It answers who, not what is held: the token listing is its own endpoint and
# its own permission, and nothing here should hand back credential material.
curl -s -u "admin:$ADMIN_PW" "$BASE/api/v1/user" | grep -q '"tokens"\|"pwhash"\|"recovery"' \
    && bad 'the identity carries no credential material' "$(curl -s -u "admin:$ADMIN_PW" "$BASE/api/v1/user")" \
    || ok 'the identity carries no credential material'
# == Passwords and recovery codes ===========================================
# The one thing a solo operator cannot talk their way out of: auth_bootstrap
# only runs when NO account exists, so before recovery codes a forgotten
# password meant deleting the account store. Driven on a throwaway account
# rather than admin, whose password every case below this one still needs.
#
# Bodies that interpolate a value go through a file. Writing them inline means
# nesting quotes inside quotes, and the version of this block that did produced
# a body the server rejected while the shell reported no error at all.
RECOVER=$(curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"username":"recoverme","password":"first-password-1"}' "$BASE/api/v1/users")
RCODE=$(echo "$RECOVER" | sed -n 's/.*"recovery_code":"\([A-Z0-9-]*\)".*/\1/p')
if [ -n "$RCODE" ]; then
    ok 'creating an account hands back a recovery code'
else
    bad 'creating an account hands back a recovery code' "$RECOVER"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"username":"recoverme","recovery_code":"AAAA-BBBB-CCCC-DDDD","new_password":"nope-password-1"}' \
    "$BASE/api/v1/user/password/reset")
check 'a wrong recovery code is refused' "$code" '403'

# Read off a screen and typed back in months later, so lower case and missing
# dashes have to work. That is what normalize_code is for.
SLOPPY=$(echo "$RCODE" | tr 'A-Z' 'a-z' | tr -d '-')
printf '{"username":"recoverme","recovery_code":"%s","new_password":"second-password-1"}' "$SLOPPY" > "$WORK/reset.json"
body=$(curl -s -X POST -H 'Content-Type: application/json' \
    --data-binary @- < "$WORK/reset.json" "$BASE/api/v1/user/password/reset")
echo "$body" | grep -q '"reset":true' \
    && ok 'a recovery code typed loosely still resets' \
    || bad 'a recovery code typed loosely still resets' "$body"

NEWCODE=$(echo "$body" | sed -n 's/.*"recovery_code":"\([A-Z0-9-]*\)".*/\1/p')
if [ -n "$NEWCODE" ] && [ "$NEWCODE" != "$RCODE" ]; then
    ok 'a reset hands back a fresh code'
else
    bad 'a reset hands back a fresh code' "$body"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -u recoverme:first-password-1 "$BASE/api/v1/repos")
check 'the old password stops working' "$code" '401'
code=$(curl -s -o /dev/null -w '%{http_code}' -u recoverme:second-password-1 "$BASE/api/v1/repos")
check 'the new password works' "$code" '200'

# Spending a code must spend it. Enforced by replacing the stored hash, so a
# replay has nothing left to match.
printf '{"username":"recoverme","recovery_code":"%s","new_password":"third-password-1"}' "$RCODE" > "$WORK/replay.json"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --data-binary @- < "$WORK/replay.json" "$BASE/api/v1/user/password/reset")
check 'a spent recovery code cannot be replayed' "$code" '403'

# A change proves the current password first, and revokes every token — which is
# the half ../xpauth records that its own change cannot do.
RTOK=$(curl -s -u recoverme:second-password-1 -X POST -H 'Content-Type: application/json' \
    -d '{"label":"before the change"}' "$BASE/api/v1/user/tokens" \
    | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')
code=$(curl -s -o /dev/null -w '%{http_code}' -u recoverme:second-password-1 -X POST \
    -H 'Content-Type: application/json' \
    -d '{"old_password":"not-the-one","new_password":"fourth-password-1"}' \
    "$BASE/api/v1/user/password")
check 'a change with the wrong current password is refused' "$code" '400'
code=$(curl -s -o /dev/null -w '%{http_code}' -u recoverme:second-password-1 -X POST \
    -H 'Content-Type: application/json' \
    -d '{"old_password":"second-password-1","new_password":"fourth-password-1"}' \
    "$BASE/api/v1/user/password")
check 'the password changes' "$code" '200'
if [ -n "$RTOK" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "recoverme:$RTOK" "$BASE/api/v1/repos")
    check 'a change revokes the tokens issued before it' "$code" '401'
fi

# == Bounds on free text and on token count =================================
# None of these were bounded while accounts and the index were JSON files that
# simply grew. They are columns now, so an unbounded value is the difference
# between a 400 that says what is wrong and a 500 out of the database — and the
# two stores have to answer the same way, which is what these assert.
# Built with awk rather than `tr` on /dev/zero: writing a NUL escape into a
# generated script is how this line first arrived as a literal NUL byte.
LONG=$(awk 'BEGIN { s = ""; while (length(s) < 4096) s = s "x"; print s }')

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST     -H 'Content-Type: application/json'     -d "{\"name\":\"toolong\",\"description\":\"$LONG\"}" "$BASE/api/v1/repos")
check 'an over-long description is refused' "$code" '400'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST     -H 'Content-Type: application/json'     -d "{\"username\":\"longmail\",\"password\":\"a-password-1\",\"email\":\"$LONG\"}"     "$BASE/api/v1/users")
check 'an over-long email is refused' "$code" '400'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X POST     -H 'Content-Type: application/json' -d "{\"label\":\"$LONG\"}"     "$BASE/api/v1/user/tokens")
check 'an over-long token label is refused' "$code" '400'

# The refusal that matters most: the token list is ONE blob in ONE column, so
# without a cap enough tokens make the account too large to write at all — and
# revoking one is itself a write, so the account would be wedged by its own
# credentials. Driven on bob so the admin account the rest of the suite uses is
# left alone.
capped=no
i=0
while [ $i -lt 80 ]; do
    c=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 -X POST         -H 'Content-Type: application/json' -d '{"label":"flood"}'         "$BASE/api/v1/user/tokens")
    [ "$c" = "400" ] && { capped=yes; break; }
    [ "$c" = "201" ] || [ "$c" = "200" ] || break
    i=$((i+1))
done
check 'an account cannot hold unlimited live tokens' "$capped" 'yes'

# The browser's credential: short-lived, and revoked the moment it logs out.
SESSION=$(curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"label":"web browser","ttl_seconds":43200}' "$BASE/api/v1/user/tokens")
echo "$SESSION" | grep -q '"expires_at":[0-9]' \
    && ok 'a ttl token reports its expiry' || bad 'a ttl token reports its expiry' "$SESSION"
SESSION_TOKEN=$(echo "$SESSION" | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')
if [ -n "$SESSION_TOKEN" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$SESSION_TOKEN" \
        "$BASE/api/v1/repos/admin/secret")
    check 'a session token reads a private repository' "$code" '200'

    code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$SESSION_TOKEN" \
        -X DELETE "$BASE/api/v1/user/tokens")
    check 'a session token revokes itself' "$code" '200'

    # The positive verification cache must not keep answering for a credential
    # that no longer exists -- that window is the whole point of revoking.
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$SESSION_TOKEN" \
        "$BASE/api/v1/repos/admin/secret")
    check 'a revoked token stops working at once' "$code" '401'

    # The password is not a token, so there is nothing for it to revoke.
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" \
        -X DELETE "$BASE/api/v1/user/tokens")
    check 'a password cannot revoke a token' "$code" '400'
else
    bad 'a ttl token reports its expiry' 'no token in the response'
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

# The listing's second column: the newest commit touching each entry, from one
# history walk rather than a `git log -1` per file. Two commits exist here --
# 'initial commit' touched README.md, src/app.lua and binary.dat, and 'second'
# touched only README.md -- so the two answers have to differ, and a walk that
# simply attributed the tip commit to everything would pass a weaker assertion.
L="$DEMO/lastcommits/main"
curl -s "$L" | tr ',' '\n' | grep -q '"subject":"second"' \
    && ok 'last commit is reported for a changed file' \
    || bad 'last commit is reported for a changed file' "$(curl -s "$L")"
curl -s "$L" | tr ',' '\n' | grep -q '"subject":"initial commit"' \
    && ok 'an untouched entry keeps its older commit' \
    || bad 'an untouched entry keeps its older commit' "$(curl -s "$L")"
# A directory is attributed by what happened INSIDE it: `src` itself never
# appears in a commit, only src/app.lua does.
curl -s "$L" | grep -q '"name":"src"' \
    && ok 'a directory is attributed by its contents' \
    || bad 'a directory is attributed by its contents' "$(curl -s "$L")"
curl -s "$L" | grep -q '"latest"' \
    && ok 'the directory reports its own newest commit' \
    || bad 'the directory reports its own newest commit' "$(curl -s "$L")"
# The column shows the subject and the row's tooltip shows the whole message,
# so the walk has to carry the body -- the subject says what changed, and the
# reason it changed is in the part that did not fit.
curl -s "$L" | grep -q '"body":"why the second commit happened"' \
    && ok 'the last-commit walk carries the message body' \
    || bad 'the last-commit walk carries the message body' "$(curl -s "$L")"
# Scoped to the subdirectory, and to its direct children only.
curl -s "$L/src" | grep -q '"name":"app.lua"' \
    && ok 'last commits scope to a subdirectory' \
    || bad 'last commits scope to a subdirectory' "$(curl -s "$L/src")"
if curl -s "$L/src" | grep -q '"name":"README.md"'; then
    bad 'a subdirectory listing excludes its siblings' "$(curl -s "$L/src")"
else
    ok 'a subdirectory listing excludes its siblings'
fi
# Same ref and path handling as every other browsing route: both are resolved by
# the same code, and both are hostile input.
code=$(curl -s -o /dev/null -w '%{http_code}' "$DEMO/lastcommits/no-such-ref")
check 'last commits on an unknown ref is a 404' "$code" '404'
code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$DEMO/lastcommits/main/../../etc")
check 'last commits refuses a traversing path' "$code" '400'

# A file whose content was decided IN a merge -- a conflict resolved there, the
# only way a change lands through a merge and nowhere else. Without `-c` on the
# walk the merge commit prints no names at all and the file is credited to
# whichever parent the walk reached next, which is a commit that does not
# contain it: a wrong answer rather than a blank one. Its own repository,
# because adding a merge to demo would move the counts the compare cases assert.
curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"name":"merged"}' "$BASE/api/v1/repos" >/dev/null
rm -rf "$WORK/wmerge"
(
    cd "$WORK" && git init -q -b main wmerge && cd wmerge &&
    C="git -c user.email=smoke@test -c user.name=smoke" &&
    printf 'base\n' > shared.txt && git add -A && $C commit -qm 'root' &&
    git checkout -q -b feature &&
    printf 'from feature\n' > shared.txt && git add -A && $C commit -qm 'feature side' &&
    git checkout -q main &&
    printf 'from main\n' > shared.txt && git add -A && $C commit -qm 'main side' &&
    { git merge feature -q 2>/dev/null || true; } &&
    printf 'resolved in the merge\n' > shared.txt && git add -A &&
    $C commit -qm 'the merge that decided it' &&
    $GIT push -q "http://admin:$ADMIN_PW@127.0.0.1:$PORT/admin/merged.git" main
) >/dev/null 2>&1
mrg=$(curl -s "$BASE/api/v1/repos/admin/merged/lastcommits/main")
echo "$mrg" | grep -q '"subject":"the merge that decided it"' \
    && ok 'a merge that resolved a file is credited with it' \
    || bad 'a merge that resolved a file is credited with it' "$mrg"
# The specific wrong answer this replaces, named so a regression is legible.
if echo "$mrg" | grep -q '"subject":"main side"'; then
    bad 'the file is not credited to a parent that lacks it' "$mrg"
else
    ok 'the file is not credited to a parent that lacks it'
fi

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

page1=$(curl -s "$DEMO/commits?ref=main&limit=1&skip=0")
echo "$page1" | grep -q '"count":1' \
    && ok 'commits honours limit' || bad 'commits honours limit' "$page1"
echo "$page1" | grep -q '"has_more":true' \
    && ok 'commits reports a following page' || bad 'commits reports a following page' "$page1"
page2=$(curl -s "$DEMO/commits?ref=main&limit=1&skip=1")
echo "$page2" | grep -q '"skip":1' && echo "$page2" | grep -q '"has_more":false' \
    && ok 'commits serves the next page' || bad 'commits serves the next page' "$page2"

# The initial commit must list its files. diff-tree compares against the first
# parent, and a root commit has none, so this is zero without --root.
# From git, not from the JSON. The old derivation took the LAST `"oid":` in the
# commits response, and that response carries one of its own beside the array --
# the resolved ref -- so which commit came out depended on key order, which Lua
# does not promise. It landed on the TIP as often as on the root, and neither
# case below noticed: a one-line README means the tip's patch still carries
# `hello gitloom` as context, so the assertion passed against either commit.
root=$( cd "$WORK/w1" && git rev-list --max-parents=0 HEAD | head -1 )
curl -s "$DEMO/commits/$root" | grep -q '"files":\[{' \
    && ok 'root commit lists its files' || bad 'root commit lists its files' "$(curl -s "$DEMO/commits/$root" | grep -o '"files":[^]]*.')"

# The diff endpoint returns patch content for the same resolved commit. The
# initial commit is important here: it exercises the --root path rather than a
# normal parent-to-child diff.
# `src/app.lua` rather than `hello gitloom`: README.md is one line long, so the
# TIP's patch carries that string as context too and the old assertion could not
# tell the two commits apart -- which is exactly how the broken `root` above
# went unnoticed. Only the initial commit adds the subdirectory.
curl -s "$DEMO/commits/$root/diff" | grep -q 'src/app.lua' \
    && ok 'commit diff returns patch content' || bad 'commit diff returns patch content' "$(curl -s "$DEMO/commits/$root/diff" | head -c 240)"

# A path filter is decoded before it reaches git, and a traversal attempt is
# rejected just like the tree/raw browsing endpoints.
curl -s "$DEMO/commits/$root/diff?path=README.md" | grep -q '"path":"README.md"' \
    && ok 'commit diff honours a path filter' || bad 'commit diff honours a path filter' "$(curl -s "$DEMO/commits/$root/diff?path=README.md")"
code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$DEMO/commits/$root/diff?path=%2e%2e%2fgitloom.cfg")
check 'commit diff rejects a traversal path' "$code" '400'

# ── Comparing two revisions ─────────────────────────────────────────────────
# THREE dots, not two: a comparison measures from where the histories last
# agreed, not from the tip of base. `side` branches off the ROOT commit and adds
# one file, while main has moved on with 'second' -- so main and side each have
# one commit the other does not, and a TWO-dot diff would additionally report
# README.md as changed, attributing the undoing of 'second' to side. That file's
# absence below is the assertion that separates the two forms; every other check
# here would pass either way.
( cd "$WORK/w1" &&
  git checkout -q -b side "$root" &&
  printf 'only on side\n' > side.txt && git add -A &&
  git -c user.email=smoke@test -c user.name=smoke commit -qm 'side commit' &&
  $GIT push -q "$AUTH" side:refs/heads/side &&
  git checkout -q main ) >/dev/null 2>&1
CMP=$(curl -s "$DEMO/compare/main/side")
echo "$CMP" | grep -q '"ahead":1' && echo "$CMP" | grep -q '"behind":1' \
    && ok 'compare counts ahead and behind' || bad 'compare counts ahead and behind' "$CMP"
echo "$CMP" | grep -q "\"merge_base\":\"$root\"" \
    && ok 'compare measures from the merge base' || bad 'compare measures from the merge base' "$CMP"
echo "$CMP" | grep -q '"subject":"side commit"' \
    && ok 'compare lists the commits it would add' || bad 'compare lists the commits it would add' "$CMP"
echo "$CMP" | grep -q '"path":"side.txt"' \
    && ok 'compare lists the files it would change' || bad 'compare lists the files it would change' "$CMP"
if echo "$CMP" | grep -q '"path":"README.md"'; then
    bad 'compare does not attribute the other branch changes' "$CMP"
else
    ok 'compare does not attribute the other branch changes'
fi
# Both ends are resolved like every other ref, and both are hostile input.
code=$(curl -s -o /dev/null -w '%{http_code}' "$DEMO/compare/main/no-such-branch")
check 'compare on an unknown head is a 404' "$code" '404'
code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$DEMO/compare/-a/main")
check 'compare refuses an option-shaped base' "$code" '404'
# The patch has to start where the file list starts, or the two halves of one
# comparison describe different things.
CMPD=$(curl -s "$DEMO/compare/main/side/diff")
echo "$CMPD" | grep -q 'side.txt' \
    && ok 'compare diff returns patch content' || bad 'compare diff returns patch content' "$(echo "$CMPD" | head -c 240)"
if echo "$CMPD" | grep -q 'a/README.md'; then
    bad 'compare diff starts at the merge base' "$(echo "$CMPD" | head -c 240)"
else
    ok 'compare diff starts at the merge base'
fi
code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$DEMO/compare/main/side/diff?path=%2e%2e%2fgitloom.cfg")
check 'compare diff rejects a traversal path' "$code" '400'
# A ref against itself is empty rather than an error, which is what the browser
# lands on when both selectors start on the default branch.
curl -s "$DEMO/compare/main/main" | grep -q '"ahead":0' \
    && ok 'comparing a ref with itself is empty' || bad 'comparing a ref with itself is empty' "$(curl -s "$DEMO/compare/main/main")"

# ── Branch protection ───────────────────────────────────────────────────────
# The hook's own decisions first, driven directly. Two of its four branches are
# not reachable through a push against a DEFAULT branch: git refuses to delete
# the branch HEAD names before any hook runs (receive.denyDeleteCurrent), and a
# creation of a branch that already exists is not a thing a client can send. A
# hook is not the place to leave a path nothing exercises.
Z=0000000000000000000000000000000000000000
A=1111111111111111111111111111111111111111
HOOK="$(dirname "$0")/../hooks/update"
GITLOOM_PROTECT_REFS='refs/heads/main' sh "$HOOK" refs/heads/other "$A" "$Z" 2>/dev/null
check 'the hook ignores an unprotected ref' "$?" '0'
GITLOOM_PROTECT_REFS='' sh "$HOOK" refs/heads/main "$A" "$Z" 2>/dev/null
check 'the hook allows everything with no policy set' "$?" '0'
# A ref that merely ends with a protected name is a different ref. The list is
# matched with spaces on both sides for exactly this.
GITLOOM_PROTECT_REFS='refs/heads/main' sh "$HOOK" refs/heads/notmain "$A" "$Z" 2>/dev/null
check 'the hook matches whole ref names' "$?" '0'
GITLOOM_PROTECT_REFS='refs/heads/main' sh "$HOOK" refs/heads/main "$Z" "$A" 2>/dev/null
check 'the hook allows creating a protected ref' "$?" '0'
hookout=$(GITLOOM_PROTECT_REFS='refs/heads/main' sh "$HOOK" refs/heads/main "$A" "$Z" 2>&1)
hookrc=$?
check 'the hook refuses deleting a protected ref' "$hookrc" '1'
echo "$hookout" | grep -q 'cannot be deleted' \
    && ok 'the refusal says why' || bad 'the refusal says why' "$hookout"

# End to end, on a repository of its own so a refused force-push cannot disturb
# the history every case above asserts against.
curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
    -d '{"name":"prot"}' "$BASE/api/v1/repos" >/dev/null
PROT="http://admin:$ADMIN_PW@127.0.0.1:$PORT/admin/prot.git"
rm -rf "$WORK/wprot"
(
    cd "$WORK" && git init -q -b main wprot && cd wprot &&
    printf 'one\n' > f.txt && git add -A &&
    git -c user.email=smoke@test -c user.name=smoke commit -qm 'p one' &&
    printf 'two\n' >> f.txt && git add -A &&
    git -c user.email=smoke@test -c user.name=smoke commit -qm 'p two' &&
    $GIT push -q "$PROT" main
) >/dev/null 2>&1
before=$(curl -s "$BASE/api/v1/repos/admin/prot/branches" | grep -o '"oid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
( cd "$WORK/wprot" && git reset -q --hard HEAD~1 &&
  printf 'rewritten\n' > f.txt && git add -A &&
  git -c user.email=smoke@test -c user.name=smoke commit -qm 'p rewrite' ) >/dev/null 2>&1
pushout=$( cd "$WORK/wprot" && $GIT push --force "$PROT" main 2>&1 )
if [ $? -eq 0 ]; then
    bad 'a force-push to the default branch is refused' "the push succeeded"
else
    ok 'a force-push to the default branch is refused'
fi
# The reason has to reach the person pushing, not just the log: that is the
# whole of what the hook's stderr is for.
echo "$pushout" | grep -q 'cannot be force-updated' \
    && ok 'the pusher is told why' || bad 'the pusher is told why' "$pushout"
after=$(curl -s "$BASE/api/v1/repos/admin/prot/branches" | grep -o '"oid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
check 'the protected branch did not move' "$after" "$before"
# Only the default branch. Everything else is somebody's own work in progress.
( cd "$WORK/wprot" && git branch -f side HEAD && $GIT push -q "$PROT" side ) >/dev/null 2>&1
( cd "$WORK/wprot" && git commit -q --allow-empty -m 'p side' && git branch -f side HEAD &&
  $GIT push --force "$PROT" side ) >/dev/null 2>&1 \
    && ok 'another branch may still be force-pushed' || bad 'another branch may still be force-pushed' 'refused'

# Deleting the branch a clone checks out is refused by gitloom's own `-c`, not
# by whatever git's default happens to be and not by the repository's config --
# which is why this sets that config to `ignore` first. `-c` outranks it.
#
# The assertion is on WHICH refusal comes back: git's own wording proves the
# pinned setting did it. The hook would refuse this too (main is protected) and
# its message says `gitloom:`, so the two are distinguishable and this case
# cannot pass for the wrong reason.
git --git-dir="$ROOT/admin/merged.git" config receive.denyDeleteCurrent ignore
delout=$( cd "$WORK/wmerge" && $GIT push --delete \
    "http://admin:$ADMIN_PW@127.0.0.1:$PORT/admin/merged.git" main 2>&1 )
if [ $? -eq 0 ]; then
    bad 'the default branch cannot be deleted' 'the deletion succeeded'
else
    ok 'the default branch cannot be deleted'
fi
echo "$delout" | grep -q 'current branch' \
    && ok 'the pinned setting is what refuses it' || bad 'the pinned setting is what refuses it' "$delout"

# Protection on with no hook to run it is the failure the whole design exists to
# prevent: an instance that reports itself healthy while nothing is guarded. It
# has to be a refusal to boot, so this asserts the process is gone rather than
# listening.
PORT4=$((PORT+3))
LOG4="$WORK/gitloom4.log"
mkdir -p "$WORK/repos4" "$WORK/data4" "$WORK/tmp4"
"$XNET" main.lua \
    LISTEN_PORT="$PORT4" REPO_ROOT="$WORK/repos4" DATA_DIR="$WORK/data4" \
    TMP_DIR="$WORK/tmp4" USERS_FILE="$WORK/data4/users.json" \
    ADMIN_USER=admin ADMIN_PASSWORD="$ADMIN_PW" \
    HOOKS_DIR="$WORK/no-such-hooks" \
    > "$LOG4" 2>&1 &
PID4=$!
i=0
while [ $i -lt 100 ]; do
    kill -0 "$PID4" 2>/dev/null || break
    curl -sf "http://127.0.0.1:$PORT4/api/v1/version" >/dev/null 2>&1 && break
    i=$((i+1)); sleep 0.2
done
if kill -0 "$PID4" 2>/dev/null; then
    bad 'a missing hook refuses the boot' 'the instance is still running'
    kill "$PID4" 2>/dev/null
else
    ok 'a missing hook refuses the boot'
fi
grep -q 'cannot be armed' "$LOG4" \
    && ok 'the boot failure names the reason' || bad 'the boot failure names the reason' "$(tail -3 "$LOG4")"

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
for ep in branches tags commits tree/main lastcommits/main compare/main/main; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/repos/admin/secret/$ep")
    check "private repo hidden from browsing: $ep" "$code" '404'
done
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" "$BASE/api/v1/repos/admin/secret/branches")
check 'owner can browse a private repository' "$code" '200'

code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PATCH \
    -H 'Content-Type: application/json' -d '{"private":true}' "$DEMO")
check 'owner can make a repository private' "$code" '200'
code=$(curl -s -o /dev/null -w '%{http_code}' "$DEMO")
check 'anonymous detail is hidden after making a repository private' "$code" '404'
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PATCH \
    -H 'Content-Type: application/json' -d '{"private":false}' "$DEMO")
check 'owner can make a repository public again' "$code" '200'
code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 -X PATCH \
    -H 'Content-Type: application/json' -d '{"description":"not yours"}' "$DEMO")
check 'a stranger cannot update repository metadata' "$code" '403'

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
#
# Driven through a forwarded address, and not because the header is what is
# being tested here — the limiter cannot tell the two apart, it keys on whatever
# http_client_ip resolved. It is so that this test does not lock out 127.0.0.1,
# which every case below it also authenticates from. It used to: the ones that
# followed only passed while the positive credential cache was still warm, so
# adding cases anywhere above them broke cases nowhere near them.
LOCKIP='198.51.100.5'
locked=no
i=0
while [ $i -lt 25 ]; do
    c=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Forwarded-For: $LOCKIP" \
        -u "lockme:wrong-$i" "$BASE/api/v1/users")
    [ "$c" = "429" ] && { locked=yes; break; }
    i=$((i+1))
done
check 'repeated credential failures are locked out' "$locked" 'yes'
# Both counters are now tripped for this attempt — the address and the username
# — so all this asserts is that the refusal says when to come back.
curl -s -D- -o /dev/null -H "X-Forwarded-For: $LOCKIP" \
    -u "lockme:wrong-again" "$BASE/api/v1/users" | grep -qi '^retry-after:' \
    && ok 'lockout sends Retry-After' || bad 'lockout sends Retry-After' 'header missing'

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

# == The push ceiling ========================================================
# MAX_REQUEST_SIZE_MB used to BE the largest repository this server could
# accept: the whole POST body was buffered before receive-pack saw any of it.
# A smart-HTTP body is now streamed to git as it arrives, so the limit governs
# buffered requests only.
#
# Told apart on a SECOND instance with the ceiling at 4 MiB, which is the only
# way to distinguish the two without pushing something enormous: a buffered
# 24 MiB body is a 413, a streamed one is a push.
#
# 4 and not 1, because the ceiling also has to hold whatever the client sends
# while a handler is still working. git sends a small probe POST before a large
# push and starts streaming the real body as soon as it is answered — before
# HEAD has finished syncing — so a 1 MiB ceiling refuses those read-ahead bytes
# and the push dies for a reason unrelated to its size. gitloom.cfg says so too.
#
# Skipped where the transport is file staging: a streamed body needs the read
# flow control that only the streaming transport has, so GIT_STREAM=off and
# Windows both keep the buffered path, where this limit IS the push ceiling.
if [ "$BIG_MB" -gt 0 ] && grep -q 'transport: streaming' "$LOG" 2>/dev/null; then
    PORT2=$((PORT+1))
    BASE2="http://127.0.0.1:$PORT2"
    LOG2="$WORK/gitloom2.log"
    mkdir -p "$WORK/repos2" "$WORK/data2" "$WORK/tmp2"

    "$XNET" main.lua \
        LISTEN_PORT="$PORT2" REPO_ROOT="$WORK/repos2" DATA_DIR="$WORK/data2" \
        TMP_DIR="$WORK/tmp2" USERS_FILE="$WORK/data2/users.json" \
        ADMIN_USER=admin ADMIN_PASSWORD="$ADMIN_PW" \
        GIT_STREAM="${GIT_STREAM:-auto}" MAX_REQUEST_SIZE_MB=4 \
        BODY_QUEUE_HIGH_KB=16 STREAM_STDIN_HIGH_KB=64 STREAM_STDIN_LOW_KB=16 \
        > "$LOG2" 2>&1 &
    PID2=$!

    i=0
    while [ $i -lt 100 ]; do
        curl -sf "$BASE2/api/v1/version" >/dev/null 2>&1 && break
        kill -0 "$PID2" 2>/dev/null || break
        i=$((i+1)); sleep 0.2
    done

    # Both water marks are forced down to a fraction of their defaults, so the
    # push below actually crosses them many times over: the connection is paused
    # and resumed whenever the queue fills, and the coroutine parks on the ticker
    # whenever git's stdin backs up. At the defaults a 24 MiB push on a fast
    # loopback can cross neither, which is how the first version of this looked
    # correct while the wait path segfaulted the moment it was reached.
    if curl -sf "$BASE2/api/v1/version" >/dev/null 2>&1; then
        curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
            -d '{"name":"over"}' "$BASE2/api/v1/repos" >/dev/null

        ( cd "$WORK/big" && $GIT push -q \
            "http://admin:$ADMIN_PW@127.0.0.1:$PORT2/admin/over.git" \
            HEAD:refs/heads/main ) 2>"$WORK/eover" \
            && ok "push ${BIG_MB} MiB past a 4 MiB buffered ceiling" \
            || bad "push ${BIG_MB} MiB past a 4 MiB buffered ceiling" \
                   "$(tail -2 "$WORK/eover")"

        # It is a real push, not a 200 over a truncated packfile.
        $GIT clone -q "$BASE2/admin/over.git" "$WORK/overclone" 2>/dev/null &&
          cmp -s "$WORK/big/blob0.bin" "$WORK/overclone/blob0.bin" \
            && ok 'the streamed push is byte-identical' \
            || bad 'the streamed push is byte-identical' 'clone differs or failed'

        # The ceiling still means something for everything that IS buffered,
        # and still says so with a status rather than a dropped connection.
        # Fed on stdin rather than as --data-binary @"$WORK/…": on Windows the
        # shell is MSYS and curl is not, and a path behind an @ is one of the
        # arguments MSYS does not rewrite — curl then cannot open it and the
        # case reports a connection failure that has nothing to do with the
        # server.
        head -c 8388608 /dev/urandom > "$WORK/oversize.bin"
        code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" \
            -X POST -H 'Content-Type: application/json' \
            --data-binary @- < "$WORK/oversize.bin" "$BASE2/api/v1/repos")
        check 'a buffered body over the ceiling is still 413' "$code" '413'

        # A client that vanishes mid-upload leaves a handler parked on a body
        # that will never arrive. Nothing but the socket's own close can end
        # that wait, and until it did the streaming slot and the git child were
        # held for GIT_TIMEOUT_SEC — ten minutes per abandoned push.
        if command -v timeout >/dev/null 2>&1; then
            ( cd "$WORK/big" && timeout -s KILL 1 $GIT push -q \
                "http://admin:$ADMIN_PW@127.0.0.1:$PORT2/admin/over.git" \
                +HEAD:refs/heads/abandoned ) >/dev/null 2>&1
            sleep 1
            code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE2/api/v1/version")
            check 'an abandoned push does not take the server with it' "$code" '200'
            ( cd "$WORK/big" && $GIT push -q \
                "http://admin:$ADMIN_PW@127.0.0.1:$PORT2/admin/over.git" \
                +HEAD:refs/heads/after ) >/dev/null 2>&1 \
                && ok 'a push after an abandoned one still works' \
                || bad 'a push after an abandoned one still works' 'push failed'
        fi
    else
        bad 'the second instance boots' "$(tail -5 "$LOG2")"
    fi

    kill "$PID2" 2>/dev/null
    PID2=

    # == The streamed-body ceiling ==========================================
    # MAX_PUSH_SIZE_MB is the one bound left on a push, and it is enforced as
    # the bytes arrive: a chunked body never says how big it is, so the push is
    # cut off partway rather than refused up front.
    #
    # What has to be true afterwards is that the connection ENDS. The body stops
    # being decoded at the ceiling and everything after it lands in the buffer
    # for the next request — so a connection kept alive here reads the rest of a
    # packfile as pipelined HTTP, which is neither a refusal nor a diagnosis.
    PORT3=$((PORT+2))
    BASE3="http://127.0.0.1:$PORT3"
    LOG3="$WORK/gitloom3.log"
    mkdir -p "$WORK/repos3" "$WORK/data3" "$WORK/tmp3"

    "$XNET" main.lua \
        LISTEN_PORT="$PORT3" REPO_ROOT="$WORK/repos3" DATA_DIR="$WORK/data3" \
        TMP_DIR="$WORK/tmp3" USERS_FILE="$WORK/data3/users.json" \
        ADMIN_USER=admin ADMIN_PASSWORD="$ADMIN_PW" \
        GIT_STREAM="${GIT_STREAM:-auto}" MAX_PUSH_SIZE_MB=1 BODY_TIMEOUT_SEC=5 \
        > "$LOG3" 2>&1 &
    PID2=$!

    i=0
    while [ $i -lt 100 ]; do
        curl -sf "$BASE3/api/v1/version" >/dev/null 2>&1 && break
        kill -0 "$PID2" 2>/dev/null || break
        i=$((i+1)); sleep 0.2
    done

    if curl -sf "$BASE3/api/v1/version" >/dev/null 2>&1; then
        curl -s -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
            -d '{"name":"capped"}' "$BASE3/api/v1/repos" >/dev/null

        ( cd "$WORK/big" && $GIT push -q \
            "http://admin:$ADMIN_PW@127.0.0.1:$PORT3/admin/capped.git" \
            HEAD:refs/heads/main ) >/dev/null 2>&1 \
            && bad 'a push over MAX_PUSH_SIZE_MB is refused' 'push succeeded' \
            || ok 'a push over MAX_PUSH_SIZE_MB is refused'

        # Refused, not half-applied.
        curl -s "$BASE3/api/v1/repos/admin/capped" | grep -q '"empty":true' \
            && ok 'a refused push leaves the repository empty' \
            || bad 'a refused push leaves the repository empty' \
                   "$(curl -s "$BASE3/api/v1/repos/admin/capped")"

        # And the instance is still an HTTP server afterwards — the packfile
        # tail was dropped with the connection rather than parsed as requests.
        code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE3/api/v1/version")
        check 'the instance survives a refused push' "$code" '200'

        # The invariant underneath both of those: a streamed body that did not
        # end cleanly ends the connection with it. Asserted here on the reachable
        # half — a body the handler answered without draining — because the
        # decoder-error and ceiling halves leave through the same line, and no
        # HTTP client will keep uploading past the response that proves it.
        #
        # Driven with curl rather than git: git-receive-pack rejects random bytes
        # as soon as it sees them, which is a body the handler stops reading.
        curl -s -o /dev/null -D "$WORK/undrained.headers" -u "admin:$ADMIN_PW" \
            -X POST -H 'Content-Type: application/x-git-receive-pack-request' \
            -H 'Transfer-Encoding: chunked' --data-binary @- \
            < "$WORK/oversize.bin" \
            "$BASE3/admin/capped.git/git-receive-pack"
        grep -qi '^connection: *close' "$WORK/undrained.headers" \
            && ok 'an unfinished streamed body ends the connection' \
            || bad 'an unfinished streamed body ends the connection' \
                   "$(grep -i '^connection' "$WORK/undrained.headers")"

        # A client that sends its headers and then goes quiet has to be let go
        # of. HANDSHAKE_TIMEOUT_SEC stops covering a connection the moment its
        # request parses, and GIT_TIMEOUT_SEC bounds the git child rather than
        # the upload — so until BODY_TIMEOUT_SEC nothing did, and that request's
        # coroutine and connection were held for the life of the process.
        #
        # The pkt-line below promises 50 bytes and delivers 14, so receive-pack
        # waits for the rest instead of rejecting the input and ending the wait
        # for us. The fifo is what makes curl stop after sending it.
        # Asserted from the server's log rather than from how long curl took:
        # what curl does with a stdin that stops depends on curl, and the claim
        # here is about the server letting go, which is the line it writes when
        # it does.
        if command -v mkfifo >/dev/null 2>&1; then
            rm -f "$WORK/stall.fifo"; mkfifo "$WORK/stall.fifo"
            ( printf '0032xxxxxxxxxx'; sleep 8 ) > "$WORK/stall.fifo" &
            STALLER=$!
            # -T -, not --data-binary @-: the latter reads stdin to the end
            # before it sends anything, so the body arrives complete and there
            # is no stall to observe. -T streams as it reads, which is the
            # whole point of the case.
            curl -s -o /dev/null --max-time 20 -u "admin:$ADMIN_PW" \
                -X POST -T - \
                -H 'Content-Type: application/x-git-receive-pack-request' \
                < "$WORK/stall.fifo" \
                "$BASE3/admin/capped.git/git-receive-pack"
            kill "$STALLER" 2>/dev/null
            grep -q 'streamed body did not finish' "$LOG3" \
                && ok 'a stalled body is abandoned rather than waited on' \
                || bad 'a stalled body is abandoned rather than waited on' \
                       'no timeout in the log'
            code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE3/api/v1/version")
            check 'the instance survives an abandoned body' "$code" '200'
        fi
    else
        bad 'the capped instance boots' "$(tail -5 "$LOG3")"
    fi

    kill "$PID2" 2>/dev/null
    PID2=
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

# == Search ==================================================================
#
# git grep against a resolved object id, fixed-string. The literal case is the
# one worth asserting: a pattern given to a regex engine is CPU anybody with
# read access can spend, and `-F` is what makes that impossible rather than
# merely bounded.
S="$BASE/api/v1/repos/admin/demo/search"
curl -s -u "admin:$ADMIN_PW" "$S?q=hello%20gitloom" | grep -q '"path":"README.md"' \
    && ok 'search finds a line in a file' || bad 'search finds a line in a file' "$(curl -s -u "admin:$ADMIN_PW" "$S?q=hello%20gitloom")"
# `.*` matches everything as a regex and nothing as a literal. This is the whole
# difference, and the first version of the endpoint shipped with an invalid git
# option that made EVERY search answer "nothing" -- including this one, which is
# why the count is asserted against a query that must find something too.
curl -s -u "admin:$ADMIN_PW" "$S?q=.%2A" | grep -q '"count":0' \
    && ok 'a regex metacharacter is searched literally' || bad 'a regex metacharacter is searched literally' "$(curl -s -u "admin:$ADMIN_PW" "$S?q=.%2A")"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" "$S?q=")
check 'search with no query is refused' "$code" '400'
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" "$S?q=x&ref=no-such-ref")
check 'search on an unknown ref is a 404' "$code" '404'
code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 \
    "$BASE/api/v1/repos/admin/secret/search?q=x")
check 'search cannot reach a private repository' "$code" '404'

# == Rename ==================================================================
curl -s -u "admin:$ADMIN_PW" -H 'Content-Type: application/json' \
    -d '{"title":"carry me"}' "$BASE/api/v1/repos/admin/demo/issues" > /dev/null
curl -s -u "admin:$ADMIN_PW" -X PATCH -H 'Content-Type: application/json' \
    -d '{"name":"renamed"}' "$BASE/api/v1/repos/admin/demo" | grep -q '"name":"renamed"' \
    && ok 'owner can rename a repository' || bad 'owner can rename a repository' 'rename refused'
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" "$BASE/api/v1/repos/admin/demo")
check 'the old name is gone' "$code" '404'
# Issues are keyed by repository, so a rename that did not carry them would not
# lose them -- it would strand them under a name nothing looks up, and the
# repository would come back looking like it never had any.
curl -s -u "admin:$ADMIN_PW" "$BASE/api/v1/repos/admin/renamed/issues" | grep -q 'carry me' \
    && ok 'issues follow the rename' || bad 'issues follow the rename' "$(curl -s -u "admin:$ADMIN_PW" "$BASE/api/v1/repos/admin/renamed/issues")"
# The content has to still be there and still be clonable: this moved a
# directory, and a rename that lost the objects would look fine in the API.
rm -rf "$WORK/renamed"
git clone -q "http://admin:$ADMIN_PW@127.0.0.1:$PORT/admin/renamed.git" "$WORK/renamed" 2>/dev/null \
    && grep -q 'hello gitloom' "$WORK/renamed/README.md" \
    && ok 'the renamed repository still clones with its content' \
    || bad 'the renamed repository still clones with its content' 'clone failed or empty'
# A change of case only. The index key does not move, but the directory must,
# and on Windows and macOS a single rename onto a name that differs only in case
# either refuses or silently does nothing.
curl -s -u "admin:$ADMIN_PW" -X PATCH -H 'Content-Type: application/json' \
    -d '{"name":"ReNamed"}' "$BASE/api/v1/repos/admin/renamed" | grep -q '"name":"ReNamed"' \
    && ok 'a rename that only changes case is applied' || bad 'a rename that only changes case is applied' 'case rename refused'
ls "$ROOT/admin" | grep -q '^ReNamed.git$' \
    && ok 'and the directory on disk carries the new spelling' \
    || bad 'and the directory on disk carries the new spelling' "$(ls "$ROOT/admin")"
curl -s -u "admin:$ADMIN_PW" -H 'Content-Type: application/json' \
    -d '{"name":"taken"}' "$BASE/api/v1/repos" > /dev/null
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PATCH \
    -H 'Content-Type: application/json' -d '{"name":"taken"}' "$BASE/api/v1/repos/admin/ReNamed")
check 'renaming onto an existing name is refused' "$code" '409'
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X PATCH \
    -H 'Content-Type: application/json' -d '{"name":"../escape"}' "$BASE/api/v1/repos/admin/ReNamed")
check 'a rename cannot climb out of the repository root' "$code" '400'
code=$(curl -s -o /dev/null -w '%{http_code}' -u bob:bob-password-1 -X PATCH \
    -H 'Content-Type: application/json' -d '{"name":"stolen"}' "$BASE/api/v1/repos/admin/ReNamed")
check 'a stranger cannot rename' "$code" '403'
# Put it back, so the delete cases below still name something that exists.
curl -s -u "admin:$ADMIN_PW" -X PATCH -H 'Content-Type: application/json' \
    -d '{"name":"demo"}' "$BASE/api/v1/repos/admin/ReNamed" > /dev/null

# == Tokens ==================================================================
#
# The id is the account's own handle on a token. It is deliberately not derived
# from the stored digest: that would have been free and stable, and would also
# publish part of the verifier for a live credential in a listing.
curl -s -u "admin:$ADMIN_PW" -H 'Content-Type: application/json' \
    -d '{"label":"smoke-listed"}' "$BASE/api/v1/user/tokens" > /dev/null
TOKENS=$(curl -s -u "admin:$ADMIN_PW" "$BASE/api/v1/user/tokens")
echo "$TOKENS" | grep -q '"label":"smoke-listed"' \
    && ok 'the account can list its own tokens' || bad 'the account can list its own tokens' "$TOKENS"
echo "$TOKENS" | grep -q '"hash"' \
    && bad 'a token listing never carries the stored digest' "$TOKENS" \
    || ok 'a token listing never carries the stored digest'
TID=$(echo "$TOKENS" | tr ',' '\n' | grep -o '"id":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X DELETE \
    "$BASE/api/v1/user/tokens/$TID")
check 'a token can be revoked by id' "$code" '200'
curl -s -u "admin:$ADMIN_PW" "$BASE/api/v1/user/tokens" | grep -q "$TID" \
    && bad 'the revoked token is gone from the listing' 'still listed' \
    || ok 'the revoked token is gone from the listing'
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X DELETE \
    "$BASE/api/v1/user/tokens/ffffffffffffffff")
check 'revoking a token that does not exist is a 404' "$code" '404'
# The boundary that matters: the account is the authenticated caller, never a
# value out of the request, so there is no shape of this that reaches somebody
# else's token -- and an id belonging to another account is simply not found.
# Its own account rather than bob's. bob is at AUTH_MAX_TOKENS by this point in
# the suite -- which is the token-cap case doing its job -- so his token request
# is refused, and reusing him here made all three of these fail for a reason
# that had nothing to do with what they test.
curl -s -u "admin:$ADMIN_PW" -H 'Content-Type: application/json' \
    -d '{"username":"tokenowner","password":"tokenowner-password-1"}' "$BASE/api/v1/users" > /dev/null
OTHER_TOKEN=$(curl -s -u tokenowner:tokenowner-password-1 -H 'Content-Type: application/json' \
    -d '{"label":"theirs"}' "$BASE/api/v1/user/tokens" | tr ',' '\n' | grep -o '"token":"[0-9a-f]*"' | cut -d'"' -f4)
OTHER_ID=$(curl -s -u "tokenowner:$OTHER_TOKEN" "$BASE/api/v1/user/tokens" | tr ',' '\n' | grep -o '"id":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PW" -X DELETE \
    "$BASE/api/v1/user/tokens/$OTHER_ID")
check 'one account cannot revoke another account token' "$code" '404'
code=$(curl -s -o /dev/null -w '%{http_code}' -u "tokenowner:$OTHER_TOKEN" "$BASE/api/v1/user/tokens")
check 'and that token still works afterwards' "$code" '200'
# Revoking the credential in flight is a logout, and it has to take effect at
# once -- the positive verification cache would otherwise keep answering 'ok'
# for AUTH_CACHE_SEC with a token that no longer exists.
curl -s -u "tokenowner:$OTHER_TOKEN" -X DELETE "$BASE/api/v1/user/tokens/$OTHER_ID" | grep -q '"was_current":true' \
    && ok 'revoking the token in use says so' || bad 'revoking the token in use says so' 'not reported'
code=$(curl -s -o /dev/null -w '%{http_code}' -u "tokenowner:$OTHER_TOKEN" "$BASE/api/v1/user/tokens")
check 'and it stops working immediately' "$code" '401'

# -- Public registration uses its own instance and rate-limit bucket. ---------
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"username":"signup","password":"signup-password-1"}' "$BASE/api/v1/user/register")
check 'public registration is disabled by default' "$code" '403'
REG_PORT=$((PORT+4))
REG_BASE="http://127.0.0.1:$REG_PORT"
mkdir -p "$WORK/reg/repos" "$WORK/reg/data" "$WORK/reg/tmp"
"$XNET" main.lua LISTEN_PORT="$REG_PORT" REPO_ROOT="$WORK/reg/repos" \
    DATA_DIR="$WORK/reg/data" TMP_DIR="$WORK/reg/tmp" USERS_FILE="$WORK/reg/data/users.json" \
    DB_DRIVER=file ADMIN_USER=admin ADMIN_PASSWORD="$ADMIN_PW" GIT_STREAM=off \
    AUTH_ALLOW_REGISTRATION=1 AUTH_REGISTER_MAX=10 AUTH_REGISTER_WINDOW_SEC=3600 \
    > "$WORK/registration.log" 2>&1 &
PID_REG=$!
i=0
while [ $i -lt 100 ]; do
    curl -sf "$REG_BASE/api/v1/version" >/dev/null && break
    i=$((i+1)); sleep 0.2
done
for payload in '{' '{}' '{"username":"../bad","password":"signup-password-1"}' \
    '{"username":"signup","password":"short"}' \
    '{"username":"signup","password":123456789}' \
    '{"username":"signup","password":"signup-password-1","email":{}}'; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
        -d "$payload" "$REG_BASE/api/v1/user/register")
    check "registration rejects invalid input: $payload" "$code" '400'
done
code=$(curl -s -o "$WORK/signup.json" -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"username":"signup","password":"signup-password-1","admin":true}' \
    "$REG_BASE/api/v1/user/register")
check 'anonymous registration succeeds' "$code" '201'
grep -q '"admin":false' "$WORK/signup.json" && grep -q '"recovery_code":"' "$WORK/signup.json" \
    && ok 'registration returns an ordinary account and recovery code' \
    || bad 'registration returns an ordinary account and recovery code' "$(cat "$WORK/signup.json")"
grep -qE 'pwhash|"tokens"|pbkdf2' "$WORK/signup.json" \
    && bad 'registration hides stored credentials' 'credential material leaked' \
    || ok 'registration hides stored credentials'
code=$(curl -s -o /dev/null -w '%{http_code}' -u signup:signup-password-1 "$REG_BASE/api/v1/user")
check 'registered account can authenticate' "$code" '200'
code=$(curl -s -o /dev/null -w '%{http_code}' -u signup:signup-password-1 "$REG_BASE/api/v1/users")
check 'registration cannot grant administrator access' "$code" '403'
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"username":"signup","password":"replacement-password-1"}' "$REG_BASE/api/v1/user/register")
check 'duplicate registration is a conflict' "$code" '409'
curl -s -o "$WORK/race1.json" -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"username":"race","password":"race-password-1"}' "$REG_BASE/api/v1/user/register" > "$WORK/race1.status" &
RACE1=$!
curl -s -o "$WORK/race2.json" -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"username":"race","password":"race-password-2"}' "$REG_BASE/api/v1/user/register" > "$WORK/race2.status" &
RACE2=$!
wait "$RACE1"; wait "$RACE2"
codes="$(cat "$WORK/race1.status") $(cat "$WORK/race2.status")"
case "$codes" in
    '201 409'|'409 201') ok 'concurrent registration cannot overwrite an account' ;;
    *) bad 'concurrent registration cannot overwrite an account' "$codes" ;;
esac
code=$(curl -s -o /dev/null -D "$WORK/signup.headers" -w '%{http_code}' \
    -H 'Content-Type: application/json' -d '{"username":"signup2","password":"signup-password-1"}' \
    "$REG_BASE/api/v1/user/register")
check 'registration limit includes successes and survives login' "$code" '429'
grep -qi '^Retry-After:' "$WORK/signup.headers" \
    && ok 'registration limit supplies retry time' || bad 'registration limit supplies retry time' 'missing header'
code=$(curl -s -o /dev/null -w '%{http_code}' -u signup:signup-password-1 "$REG_BASE/api/v1/user")
check 'registration limit does not block login or replace the password' "$code" '200'
kill "$PID_REG" 2>/dev/null
wait "$PID_REG" 2>/dev/null
PID_REG=''

# == TLS =====================================================================
# Every case above this line is plaintext, and that is precisely how the TLS
# transport stayed unusable without one of them going red: HTTPS=1 served the
# API and a small clone perfectly well, while a push over 8 MiB was closed with
# no reply at all and a clone over 10 MiB hung forever at exactly that mark.
# Both were caps in the runtime's TLS layer being applied to the wrong thing —
# the inbound one to bytes a fast peer delivered rather than to bytes nobody had
# consumed, the outbound one to a whole file pushed into the queue at once
# instead of paced against the socket. Neither shows up below the cap, so the
# payload here has to be larger than both. That is the only reason this section
# moves megabytes, and why one file is enough.
#
# TLS_MB=0 keeps the cheap checks and skips the transfers. Without openssl the
# whole section skips: it is what makes the certificate, and gitloom does not
# ship one.
TLS_MB="${TLS_MB:-12}"
if ! command -v openssl >/dev/null 2>&1; then
    skip 'the TLS transport (openssl not installed)'
else
    TLS_PORT=$((PORT+5))
    TLS_BASE="https://127.0.0.1:$TLS_PORT"
    LOG_TLS="$WORK/gitloom-tls.log"
    mkdir -p "$WORK/tls/repos" "$WORK/tls/data" "$WORK/tls/tmp"

    # A config file rather than -subj/-addext: -addext wants openssl 1.1.1, and
    # MSYS rewrites an argument beginning with a slash into a Windows path, so
    # "/CN=localhost" arrives as a drive letter and the certificate ends up with
    # no name anyone can verify.
    cat > "$WORK/tls/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = localhost
[v3]
subjectAltName   = DNS:localhost,IP:127.0.0.1
basicConstraints = CA:FALSE
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -config "$WORK/tls/openssl.cnf" \
        -keyout "$WORK/tls/key.pem" -out "$WORK/tls/cert.pem" >/dev/null 2>&1

    if [ ! -s "$WORK/tls/cert.pem" ]; then
        skip 'the TLS transport (could not create a test certificate)'
    else
        "$XNET" main.lua \
            LISTEN_PORT="$TLS_PORT" HTTPS=1 \
            TLS_CERT_FILE="$WORK/tls/cert.pem" TLS_KEY_FILE="$WORK/tls/key.pem" \
            REPO_ROOT="$WORK/tls/repos" DATA_DIR="$WORK/tls/data" \
            TMP_DIR="$WORK/tls/tmp" USERS_FILE="$WORK/tls/data/users.json" \
            ADMIN_USER=admin ADMIN_PASSWORD="$ADMIN_PW" \
            GIT_STREAM="${GIT_STREAM:-auto}" AUTH_ALLOW_REGISTRATION=0 \
            > "$LOG_TLS" 2>&1 &
        PID_TLS=$!

        i=0
        while [ $i -lt 100 ]; do
            curl -skf "$TLS_BASE/api/v1/version" >/dev/null 2>&1 && break
            kill -0 "$PID_TLS" 2>/dev/null || break
            i=$((i+1)); sleep 0.2
        done

        if ! curl -skf "$TLS_BASE/api/v1/version" >/dev/null 2>&1; then
            bad 'the TLS instance boots' "$(tail -5 "$LOG_TLS")"
        else
            ok 'the TLS instance boots'

            # The scheme in a clone URL comes from whether OUR socket is TLS.
            # Handing out http:// from an https instance is not cosmetic: git
            # follows it and re-sends HTTP Basic on every request of every clone
            # and push, in clear, which is the exposure TLS was turned on for.
            curl -s -k -u "admin:$ADMIN_PW" -X POST -H 'Content-Type: application/json' \
                -d '{"name":"tls"}' "$TLS_BASE/api/v1/repos" > "$WORK/tls/create.json"
            grep -q '"clone_url":"https://' "$WORK/tls/create.json" \
                && ok 'a TLS instance hands out an https clone URL' \
                || bad 'a TLS instance hands out an https clone URL' "$(cat "$WORK/tls/create.json")"

            # git checks the certificate like any other client, and needs to be
            # told about this one. On Windows it uses schannel, which ignores
            # http.sslCAInfo and reads the Windows certificate store instead —
            # so the backend has to be named, and the path has to be one a
            # native program can open rather than an MSYS one.
            TLS_CA="$WORK/tls/cert.pem"
            GIT_TLS_OPTS=""
            case "$(uname -s 2>/dev/null)" in
                MINGW*|MSYS*|CYGWIN*|Windows*)
                    command -v cygpath >/dev/null 2>&1 && TLS_CA="$(cygpath -m "$TLS_CA")"
                    GIT_TLS_OPTS="-c http.sslBackend=openssl" ;;
            esac
            GIT_TLS_OPTS="$GIT_TLS_OPTS -c http.sslCAInfo=$TLS_CA"

            # The outbound failure this section is here for does not error, it
            # STALLS — the body stops arriving and the client waits for bytes
            # nobody is going to send. Under a deadline that is a red case;
            # without one it is a suite that never finishes, which is worse than
            # no case at all. Only a guard: 12 MiB over loopback is seconds.
            TLS_T=""
            command -v timeout >/dev/null 2>&1 && TLS_T="timeout -s KILL 300"

            if [ "$TLS_MB" -gt 0 ]; then
                # One incompressible file, larger than both old caps. Split into
                # several it would still push as one packfile, but the raw fetch
                # below wants a single body that crosses the outbound cap on its
                # own.
                ( cd "$WORK/tls" && git init -q payload && cd payload &&
                  head -c $((TLS_MB * 1048576)) /dev/urandom > blob.bin &&
                  git add -A &&
                  git -c user.email=smoke@test -c user.name=smoke commit -qm tls ) >/dev/null 2>&1

                # shellcheck disable=SC2086
                ( cd "$WORK/tls/payload" && $TLS_T $GIT $GIT_TLS_OPTS push -q \
                    "https://admin:$ADMIN_PW@127.0.0.1:$TLS_PORT/admin/tls.git" \
                    HEAD:refs/heads/main ) 2>"$WORK/tls/epush" \
                    && ok "push ${TLS_MB} MiB over TLS" \
                    || bad "push ${TLS_MB} MiB over TLS" "$(tail -2 "$WORK/tls/epush")"

                # shellcheck disable=SC2086
                if $TLS_T $GIT $GIT_TLS_OPTS clone -q "$TLS_BASE/admin/tls.git" \
                        "$WORK/tls/clone" 2>"$WORK/tls/eclone"; then
                    ok "clone ${TLS_MB} MiB over TLS"
                    # Byte-identical, not merely present: the failure this case
                    # exists for delivered a prefix of the body and then stopped.
                    cmp -s "$WORK/tls/payload/blob.bin" "$WORK/tls/clone/blob.bin" \
                        && ok 'the TLS clone is byte-identical' \
                        || bad 'the TLS clone is byte-identical' 'contents differ'
                else
                    bad "clone ${TLS_MB} MiB over TLS" "$(tail -2 "$WORK/tls/eclone")"
                    skip 'the TLS clone is byte-identical'
                fi

                # A file response and a deferred close on one connection. Closing
                # when the queue looks empty rather than when the file has
                # finished drops whatever has not reached the socket, which at
                # this size is most of the body.
                code=$(curl -s -k -u "admin:$ADMIN_PW" -H 'Connection: close' --http1.1 \
                    -o "$WORK/tls/raw.bin" -w '%{http_code}' \
                    "$TLS_BASE/api/v1/repos/admin/tls/raw/main/blob.bin")
                check 'a raw file over TLS answers 200' "$code" '200'
                cmp -s "$WORK/tls/payload/blob.bin" "$WORK/tls/raw.bin" \
                    && ok 'Connection: close over TLS delivers the whole body' \
                    || bad 'Connection: close over TLS delivers the whole body' \
                           "got $(wc -c < "$WORK/tls/raw.bin" 2>/dev/null) bytes"
            else
                skip 'the TLS transfers (TLS_MB=0)'
            fi
        fi

        kill "$PID_TLS" 2>/dev/null
        wait "$PID_TLS" 2>/dev/null
        PID_TLS=''
    fi
fi

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
