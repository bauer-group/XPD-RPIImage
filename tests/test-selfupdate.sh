#!/usr/bin/env bash
# Exercises `bgrpiimage-setup update --self` end to end.
#
# Why a container and a real TLS server, rather than mocking curl:
# the production code pins --proto '=https' --tlsv1.2, so an http mock would
# only ever prove that the pin works. Serving over TLS with a throwaway CA in
# the container trust store exercises the path a device actually takes, and
# the container keeps the test's writes to /usr/local/sbin and /etc away from
# the machine running it.
#
# Runs itself inside debian:trixie-slim when invoked from a host; the second
# entry (BGRPI_TEST_INNER=1) is the body. One file, works from a developer
# workstation and from CI.
#
#   bash tests/test-selfupdate.sh      # or: make test
set -uo pipefail

# ---------------------------------------------------------------------------
# Outer half: re-exec in a container
# ---------------------------------------------------------------------------
if [ -z "${BGRPI_TEST_INNER:-}" ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    mount="$root"
    # Git Bash hands Docker a POSIX path it cannot resolve; this repo is
    # developed on Windows, so make the target usable there rather than
    # Linux-only.
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            mount=$(cygpath -w "$root")
            export MSYS_NO_PATHCONV=1
            ;;
    esac
    command -v docker >/dev/null || { echo "docker is required to run this test" >&2; exit 1; }
    exec docker run --rm -e BGRPI_TEST_INNER=1 \
        -v "${mount}:/repo:ro" \
        debian:trixie-slim bash /repo/tests/test-selfupdate.sh
fi

# ---------------------------------------------------------------------------
# Inner half: the test body
# ---------------------------------------------------------------------------
PASS=0; FAIL=0
ok()    { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()   { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check() { # check <desc> <expected-rc> <actual-rc>
    if [ "$2" = "$3" ]; then ok "$1 (rc=$3)"; else bad "$1 (want rc=$2, got $3)"; fi
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
    curl jq ca-certificates openssl python3 >/dev/null 2>&1

SRC=/repo/src/modules/bgrpiimage-base/filesystem/root/usr/local/sbin/bgrpiimage-setup
WEB=/srv/web
REPO=bauer-group/XPD-RPIImage
TAG=v9.9.9

[ -r "$SRC" ] || { echo "helper not found at $SRC" >&2; exit 1; }

# ---- throwaway CA + server cert -------------------------------------------
mkdir -p /srv/tls && cd /srv/tls || exit 1
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
    -days 1 -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
    >/dev/null 2>&1
cp cert.pem /usr/local/share/ca-certificates/test-selfupdate.crt
update-ca-certificates >/dev/null 2>&1

# ---- the artefacts a release would publish --------------------------------
mkdir -p "$WEB/repos/$REPO/releases" "$WEB/$REPO/releases/download/$TAG"
printf '{"tag_name":"%s"}\n' "$TAG" > "$WEB/repos/$REPO/releases/latest"

# The published helper is the real one with a marker appended, so a successful
# swap is observable rather than merely assumed.
D="$WEB/$REPO/releases/download/$TAG"
cp "$SRC" "$D/bgrpiimage-setup"
printf '# PUBLISHED-MARKER-9.9.9\n' >> "$D/bgrpiimage-setup"
( cd "$D" && sha256sum bgrpiimage-setup > bgrpiimage-setup.sha256 )

cd "$WEB" || exit 1
python3 -c "
import http.server, ssl, socketserver, os
os.chdir('$WEB')
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('/srv/tls/cert.pem', '/srv/tls/key.pem')
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
httpd = socketserver.TCPServer(('127.0.0.1', 8443), Q)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
" &
sleep 2

export BGRPIIMAGE_UPDATE_API=https://localhost:8443
export BGRPIIMAGE_UPDATE_DL=https://localhost:8443
export BGRPIIMAGE_UPDATE_REPO="$REPO"

install -m 0755 "$SRC" /usr/local/sbin/bgrpiimage-setup
S=/usr/local/sbin/bgrpiimage-setup

echo "=== 1. refusals that happen before any download ==="
$S update >/dev/null 2>&1;                       check "bare 'update' is refused"        2 $?
$S update --bogus >/dev/null 2>&1;               check "unknown update option refused"   1 $?
$S update --self --version main >/dev/null 2>&1; check "non-semver tag refused"          1 $?
$S update --self --version 1.2 >/dev/null 2>&1;  check "short version refused"           1 $?
$S update --self --version >/dev/null 2>&1;      check "--version without value refused" 1 $?

echo "=== 2. happy path ==="
$S update --self >/tmp/out 2>&1; rc=$?
check "update --self succeeds" 0 $rc
[ $rc -ne 0 ] && sed 's/^/        /' /tmp/out
grep -q 'PUBLISHED-MARKER-9.9.9' "$S" \
    && ok "installed helper is the published one" || bad "installed helper was NOT swapped"
[ -f /usr/local/sbin/bgrpiimage-setup.prev ] \
    && ok "previous helper kept as .prev" || bad ".prev missing"
[ ! -e /usr/local/sbin/.bgrpiimage-setup.new ] \
    && ok "staging file cleaned up" || bad "staging file left behind"
grep -q "BGRPIIMAGE_HELPER_VERSION='9.9.9'" /etc/bgrpiimage-applied \
    && ok "helper version recorded" || bad "helper version not recorded"
grep -q 'BGRPIIMAGE_HELPER_UPDATED_AT=' /etc/bgrpiimage-applied \
    && ok "timestamp recorded" || bad "timestamp not recorded"
( . /etc/bgrpiimage-applied ) \
    && ok "/etc/bgrpiimage-applied is shell-sourceable" || bad "applied file not sourceable"
grep -q 'BGRPIIMAGE_VERSION' /etc/bgrpiimage-release 2>/dev/null \
    && bad "self-update wrote /etc/bgrpiimage-release" \
    || ok "/etc/bgrpiimage-release left alone (it records the flashed image)"

echo "=== 3. idempotence ==="
$S update --self >/tmp/out2 2>&1;                check "re-run is a no-op"               0 $?
grep -q 'already at' /tmp/out2 \
    && ok "reports already-current" || bad "did not report already-current"
n=$(grep -c 'BGRPIIMAGE_HELPER_VERSION=' /etc/bgrpiimage-applied)
[ "$n" = "1" ] && ok "applied file not duplicated ($n line)" \
               || bad "applied file has $n version lines"

echo "=== 4. integrity refusals ==="
# A refusal must leave the installed helper untouched: a half-replaced
# recovery tool is the worst outcome this command can produce.
install -m 0755 "$SRC" "$S"
rm -f /etc/bgrpiimage-applied
cp "$D/bgrpiimage-setup" /tmp/good; cp "$D/bgrpiimage-setup.sha256" /tmp/good.sha

printf 'tampered\n' >> "$D/bgrpiimage-setup"
$S update --self >/dev/null 2>&1;                check "checksum mismatch refused"       1 $?
cp /tmp/good "$D/bgrpiimage-setup"

printf 'not our script\n' > "$D/bgrpiimage-setup"
( cd "$D" && sha256sum bgrpiimage-setup > bgrpiimage-setup.sha256 )
$S update --self >/dev/null 2>&1;                check "foreign content refused"         1 $?

printf '#!/usr/bin/env bash\r\n# bgrpiimage-setup - on-device helper\r\n' > "$D/bgrpiimage-setup"
( cd "$D" && sha256sum bgrpiimage-setup > bgrpiimage-setup.sha256 )
$S update --self >/dev/null 2>&1;                check "CRLF content refused"            1 $?

cp /tmp/good "$D/bgrpiimage-setup"
rm -f "$D/bgrpiimage-setup.sha256"
$S update --self >/dev/null 2>&1;                check "missing checksum asset refused"  1 $?
cp /tmp/good.sha "$D/bgrpiimage-setup.sha256"

grep -q 'PUBLISHED-MARKER' "$S" \
    && bad "helper was swapped despite a refusal" \
    || ok "helper untouched by every refusal"

echo "=== 5. unreachable endpoint ==="
BGRPIIMAGE_UPDATE_API=https://127.0.0.1:9 BGRPIIMAGE_UPDATE_DL=https://127.0.0.1:9 \
    $S update --self >/dev/null 2>&1;            check "unreachable API refused"         1 $?

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
