#!/usr/bin/env bash
# Asserts the guards in apply-lib.sh actually refuse.
#
# These are the guards that stand between an update and a truck roll, and
# every one of them is a negative: "this must NOT happen". Negatives rot
# silently - a refactor that drops a condition passes every other test in the
# suite, because nothing it does is wrong, it just stops declining. So they
# get their own assertions.
#
#   bash tests/test-apply-guards.sh      # or: make test-guards
set -uo pipefail

if [ -z "${BGRPI_TEST_INNER:-}" ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
    mount="$root"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) mount=$(cygpath -w "$root"); export MSYS_NO_PATHCONV=1 ;;
    esac
    exec docker run --rm -e BGRPI_TEST_INNER=1 \
        -v "${mount}:/repo:ro" debian:trixie-slim \
        bash /repo/tests/test-apply-guards.sh
fi

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

LIB=/repo/src/modules/bgrpiimage-common/apply-lib.sh
mkdir -p /scratch/etc /stub
printf 'payload\n' > /src.txt
for c in systemctl networkctl udevadm; do
    printf '#!/bin/sh\nexit 0\n' > "/stub/$c"; chmod +x "/stub/$c"
done
export PATH="/stub:$PATH"

# Run one bg_install in a subshell and report its exit status.
try_install() { # ctx dest
    ( export BGRPI_CTX="$1" BGRPI_ROOT=/scratch BGRPI_INTENTS=/i.txt
      # shellcheck disable=SC1090
      . "$LIB"
      bg_install /src.txt "$2" 0644 ) >/dev/null 2>&1
}

echo "=== denylist: refused on a device, allowed while building an image ==="
for p in /etc/shadow /etc/passwd /etc/sudoers.d/010-bgrpiimage-admin \
         /etc/pam.d/su /etc/ssh/ssh_host_rsa_key /etc/hostname /etc/hosts \
         /etc/resolv.conf /etc/wpa_supplicant/wpa_supplicant-wlan0.conf \
         /var/lib/systemd/rfkill/0:wlan \
         /etc/systemd/network/05-bgrpiimage-can0.network \
         /etc/docker/daemon.json /boot/firmware/cmdline.txt /etc/fstab \
         /etc/apt/sources.list.d/docker.list /etc/machine-id; do
    if try_install device "$p"; then bad "device write to $p was ALLOWED"; else ok "device refuses $p"; fi
done

echo "=== the same paths are legitimate at build time ==="
for p in /etc/hostname /etc/hosts; do
    if try_install image "$p"; then ok "image may write $p"; else bad "image write to $p was refused"; fi
done

echo "=== paths this project owns stay writable on a device ==="
for p in /etc/systemd/network/40-can0.network /etc/systemd/network/70-can0.link \
         /etc/apt/apt.conf.d/50unattended-upgrades /etc/issue \
         /etc/update-motd.d/10-bgrpiimage /etc/bgrpiimage-release; do
    if try_install device "$p"; then ok "device may write $p"; else bad "device write to $p was refused"; fi
done

echo "=== unit masking is build-only ==="
mask_rc() { # ctx -> "refused" | "did it"
    ( export BGRPI_CTX="$1" BGRPI_ROOT=/scratch BGRPI_INTENTS=/i.txt
      # shellcheck disable=SC1090
      . "$LIB"
      bg_unit_mask NetworkManager 2>&1 ) | grep -q 'refusing to mask' && echo refused || echo did
}
[ "$(mask_rc device)" = "refused" ] && ok "device refuses to mask a unit" || bad "device masked a unit"
[ "$(mask_rc image)"  = "did" ]     && ok "image may mask a unit"        || bad "image refused to mask"

echo "=== dry run writes nothing ==="
rm -rf /scratch; mkdir -p /scratch
( export BGRPI_CTX=device BGRPI_ROOT=/scratch BGRPI_DRY_RUN=1 BGRPI_INTENTS=/i.txt
  # shellcheck disable=SC1090
  . "$LIB"
  bg_install /src.txt /etc/issue 0644 ) >/dev/null 2>&1
if [ -e /scratch/etc/issue ]; then bad "dry run created a file"; else ok "dry run created nothing"; fi

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
