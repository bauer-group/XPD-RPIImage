#!/usr/bin/env bash
# Applies every module twice against the same root and asserts the second run
# is a no-op.
#
# Idempotence is THE property an in-place updater depends on, and it is the
# one that is mechanically checkable. It is also the property this codebase
# has already been bitten by: create-users.sh runs `chpasswd` and `chage -d 0`
# unconditionally, so re-applying it would reset an operator's rotated
# password to the shipped default - fleet-wide, silently, reported as success.
# A "run it twice, the second time must change nothing" assertion catches that
# whole class without anyone having to think of the specific case.
#
# Runs with BGRPI_CTX=device, because that is the context the updater will use
# and the one where a non-idempotent step does damage. The image context is
# covered by tests/test-apply-parity.sh instead.
#
# BGRPI_ROOT is what makes this possible at all: every write in every module
# goes through bg_path, so the real apply scripts can be pointed at a scratch
# directory. The payload stays at its real /opt/bgrpiimage location, exactly
# as a device carries it.
#
#   bash tests/test-apply-idempotence.sh      # or: make test-idempotence
set -uo pipefail

# ---------------------------------------------------------------------------
# Outer half
# ---------------------------------------------------------------------------
if [ -z "${BGRPI_TEST_INNER:-}" ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
    mount="$root"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) mount=$(cygpath -w "$root"); export MSYS_NO_PATHCONV=1 ;;
    esac
    exec docker run --rm -e BGRPI_TEST_INNER=1 \
        -v "${mount}:/repo:ro" debian:trixie-slim \
        bash /repo/tests/test-apply-idempotence.sh
fi

# ---------------------------------------------------------------------------
# Inner half
# ---------------------------------------------------------------------------
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# Stub what the device path may still reach. dpkg-query reports "installed" so
# bg_apt_install stays quiet; systemctl is a no-op because enabling a unit in
# a container tells us nothing.
mkdir -p /stub
for c in systemctl networkctl udevadm; do
    printf '#!/bin/sh\nexit 0\n' > "/stub/$c"; chmod +x "/stub/$c"
done
printf '#!/bin/sh\necho "install ok installed"\nexit 0\n' > /stub/dpkg-query
chmod +x /stub/dpkg-query
export PATH="/stub:$PATH"

# The payload lives where a flashed device has it: unpack to the real root.
for d in /repo/src/modules/*/filesystem/root; do
    [ -d "$d" ] && cp -r "$d/." / 2>/dev/null
done
find /opt/bgrpiimage -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true

SCRATCH=/scratch
export BGRPI_ROOT="$SCRATCH"
export BGRPI_CTX=device
export BGRPI_INTENTS=/intents.txt

# Seed the scratch root with the files a real device already has. A device is
# not a blank rootfs, and a module that assumes one would fail here - which is
# itself worth knowing.
mkdir -p "$SCRATCH"/etc/{systemd/network,ssh/sshd_config.d,update-motd.d,modprobe.d,apt/apt.conf.d,default,wpa_supplicant} \
         "$SCRATCH"/usr/local/sbin "$SCRATCH"/boot/firmware "$SCRATCH"/var/lib/bgrpiimage \
         "$SCRATCH"/etc/systemd/system
cp /usr/local/sbin/bgrpiimage-setup "$SCRATCH/usr/local/sbin/" 2>/dev/null || true
cp /etc/profile.d/50-bgrpiimage-shell.sh "$SCRATCH/etc/profile.d/" 2>/dev/null \
    || { mkdir -p "$SCRATCH/etc/profile.d"; cp /etc/profile.d/50-bgrpiimage-shell.sh "$SCRATCH/etc/profile.d/" 2>/dev/null; }
printf '# stock bash.bashrc\n'            > "$SCRATCH/etc/bash.bashrc"
printf '# stock config.txt\n'             > "$SCRATCH/boot/firmware/config.txt"
printf '127.0.0.1\tlocalhost\n'           > "$SCRATCH/etc/hosts"
printf 'VERSION_CODENAME=trixie\n'        > "$SCRATCH/etc/os-release"

snapshot() {
    find "$SCRATCH" -type f -printf '%m %P ' -exec sha256sum {} \; 2>/dev/null \
        | awk '{print $1, $2, $3}' | sort
    find "$SCRATCH" -type l -printf 'LINK %P -> %l\n' 2>/dev/null | sort
}

modules=$(find /repo/src/modules -maxdepth 2 -name apply.sh \
          | sed 's|/repo/src/modules/||; s|/apply.sh||' | sort)
[ -n "$modules" ] || { echo "no apply.sh found"; exit 1; }

run_all() {
    local m rc=0
    : > "$BGRPI_INTENTS"
    for m in $modules; do
        [ -x "/opt/bgrpiimage/$m/apply.sh" ] || continue
        if ! "/opt/bgrpiimage/$m/apply.sh" >>"/log.$1" 2>&1; then
            echo "    $m exited non-zero on run $1"; rc=1
        fi
    done
    return $rc
}

echo "=== run 1 (a device seeing this release for the first time) ==="
run_all 1 && ok "every module applied cleanly" || { bad "a module failed"; sed 's/^/        /' /log.1 | tail -25; }
snapshot > /after1.txt
cp "$BGRPI_INTENTS" /intents1.txt
echo "  ($(grep -c . /intents1.txt) intents queued, $(wc -l < /after1.txt) paths)"

echo "=== run 2 (the same release applied again) ==="
run_all 2 && ok "every module applied cleanly" || { bad "a module failed"; sed 's/^/        /' /log.2 | tail -25; }
snapshot > /after2.txt

# The assertion that matters. An intent is emitted only from OBSERVED change,
# so a second run that queues anything has written something it did not need
# to - which on a device means a service bounced, or a bus dropped, for
# nothing.
# grep -c prints 0 AND exits 1 when it matches nothing, so a `|| echo 0`
# fallback would append a SECOND zero and the test would compare garbage.
n2=$(grep -c . "$BGRPI_INTENTS" 2>/dev/null)
if [ "$n2" -eq 0 ]; then
    ok "second run queued no intents"
else
    bad "second run queued $n2 intent(s) - something was rewritten:"
    sed 's/^/        /' "$BGRPI_INTENTS"
fi

if diff -u /after1.txt /after2.txt > /fsdiff.txt; then
    ok "filesystem identical after both runs"
else
    bad "filesystem changed on the second run:"
    sed 's/^/        /' /fsdiff.txt | head -40
fi

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
