#!/usr/bin/env bash
# Proves that moving a module's logic from start_chroot_script into apply.sh
# changed nothing about what lands on the filesystem.
#
# The refactor is the riskiest step of the in-place update work: it touches
# nine hand-written scripts whose only current test is "the image still
# boots", which costs a ~40 minute build per variant to find out. So instead
# of trusting review, run BOTH versions in a clean container and diff the
# filesystem they produce.
#
#   old = the module's start_chroot_script at BASE_REF - pinned to the last
#         release before the refactor, NOT to HEAD~1. Comparing against the
#         previous commit would go vacuous the moment the refactor merged,
#         since both sides would then be the same six-line adapter.
#   new = today's start_chroot_script, which unpacks and calls apply.sh
#
# The comparison stays meaningful as the work continues, because it only
# exercises BGRPI_CTX=image: the guards added later are device-context
# behaviour and do not change what a build produces. Bump BASE_REF
# deliberately, and only when build output is MEANT to change.
#
# Everything the scripts would reach outside the filesystem - apt, systemctl,
# locale-gen - is stubbed to a logged no-op, so the delta between the two runs
# is exactly the files each version wrote, plus the sequence of external
# commands each version asked for. Both are compared.
#
#   bash tests/test-apply-parity.sh [module ...]     # or: make test-parity
set -uo pipefail

BASE_REF="${BASE_REF:-v0.8.0}"

# ---------------------------------------------------------------------------
# Outer half
# ---------------------------------------------------------------------------
if [ -z "${BGRPI_TEST_INNER:-}" ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

    modules=("$@")
    if [ ${#modules[@]} -eq 0 ]; then
        # Only modules that have an apply.sh AND are in MODULES of a rendered
        # variant. A module the current render switched off has an emptied
        # payload directory, and comparing against it would measure the
        # absence of files rather than the refactor - bgrpiimage-can under the
        # base variant, for instance, where the old script's unconditional
        # `cp -a` of a missing directory legitimately fails.
        mapfile -t modules < <(
            cd "$root" || exit 1
            active=$(cat src/variants/*/config 2>/dev/null \
                     | sed -n "s/^export MODULES=//p" | tr -d "'\"" | tr ',' '\n' | sort -u)
            find src/modules -maxdepth 2 -name apply.sh \
                | sed 's|src/modules/||; s|/apply.sh||' | sort \
                | while read -r m; do
                      printf '%s\n' "$active" | grep -qx "$m" && echo "$m"
                  done
        )
    fi
    if [ ${#modules[@]} -eq 0 ]; then
        echo "no module has an apply.sh yet - nothing to compare"; exit 0
    fi

    # actions/checkout clones shallow (fetch-depth: 1) with no tags, so the
    # pinned reference is simply absent in CI. Fetch just that one ref rather
    # than making every build pull the full history for a test that needs one
    # commit.
    if ! ( cd "$root" && git cat-file -e "${BASE_REF}^{commit}" ) 2>/dev/null; then
        ( cd "$root" && git fetch --depth=1 origin \
            "refs/tags/${BASE_REF}:refs/tags/${BASE_REF}" ) >/dev/null 2>&1 \
        || ( cd "$root" && git fetch --depth=1 origin "$BASE_REF" ) >/dev/null 2>&1 \
        || true
    fi
    if ! ( cd "$root" && git cat-file -e "${BASE_REF}^{commit}" ) 2>/dev/null; then
        echo "cannot resolve BASE_REF=${BASE_REF} - fetch it or override BASE_REF" >&2
        exit 1
    fi

    # Stage the pre-refactor scripts next to the tree, so the container sees
    # both versions without needing git or network inside it.
    old=$(mktemp -d)
    trap 'rm -rf "$old"' EXIT
    for m in "${modules[@]}"; do
        if ! ( cd "$root" && git show "${BASE_REF}:src/modules/${m}/start_chroot_script" ) \
                > "$old/${m}" 2>/dev/null; then
            echo "cannot read ${m}/start_chroot_script at ${BASE_REF}" >&2
            exit 1
        fi
    done

    mount_root="$root"; mount_old="$old"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            mount_root=$(cygpath -w "$root"); mount_old=$(cygpath -w "$old")
            export MSYS_NO_PATHCONV=1
            ;;
    esac

    rc=0
    for m in "${modules[@]}"; do
        echo "=== ${m} ==="
        for mode in old new; do
            docker run --rm -e BGRPI_TEST_INNER=1 -e MODE="$mode" -e MODULE="$m" \
                -v "${mount_root}:/repo:ro" -v "${mount_old}:/old:ro" \
                debian:trixie-slim bash /repo/tests/test-apply-parity.sh \
                > "$old/${m}.${mode}.out" 2>"$old/${m}.${mode}.err" \
                || { echo "  ERROR  ${mode} run failed:"; sed 's/^/         /' "$old/${m}.${mode}.err" | tail -20; rc=1; continue 2; }
        done
        if diff -u "$old/${m}.old.out" "$old/${m}.new.out" > "$old/${m}.diff"; then
            echo "  PASS   identical filesystem result and external calls"
        else
            echo "  FAIL   the refactor changed behaviour:"
            sed 's/^/         /' "$old/${m}.diff" | head -60
            rc=1
        fi
    done
    exit $rc
fi

# ---------------------------------------------------------------------------
# Inner half: run one version, print a manifest
# ---------------------------------------------------------------------------
: "${MODE:?}" ; : "${MODULE:?}"

# --- stubs -----------------------------------------------------------------
# Logged no-ops. The log is part of the compared output, so a refactor that
# silently drops an `apt-get install` or a `systemctl enable` fails here.
mkdir -p /stub
for c in apt-get systemctl locale-gen update-locale dpkg-reconfigure \
         networkctl udevadm curl rpi-eeprom-config vcgencmd; do
    cat > "/stub/$c" <<EOF
#!/bin/sh
echo "CALL $c \$*" >> /calls.log
exit 0
EOF
    chmod +x "/stub/$c"
done
# dpkg-query is used by the device path to test for installed packages; in the
# image path it is not reached. Report "not installed" so the device branch is
# exercised honestly if it ever runs here.
cat > /stub/dpkg-query <<'EOF'
#!/bin/sh
echo "CALL dpkg-query $*" >> /calls.log
exit 1
EOF
chmod +x /stub/dpkg-query
export PATH="/stub:$PATH"
: > /calls.log

# --- CustomPiOS shim -------------------------------------------------------
# Only two helpers are used across all nine scripts (verified with grep):
# unpack and install_cleanup_trap. Neither is apply logic.
cat > /common.sh <<'EOF'
install_cleanup_trap() { :; }
unpack() {
  from=$1; to=$2
  cp -r --preserve=mode,timestamps "$from/." "$to/"
}
EOF

# --- payload ---------------------------------------------------------------
# CustomPiOS copies module/filesystem/ into the chroot as /filesystem, then
# the script's `unpack /filesystem/root / root` moves it to /. The common
# module ships apply-lib.sh the same way and runs first, so merge both.
mkdir -p /filesystem
for m in bgrpiimage-common "$MODULE"; do
    [ -d "/repo/src/modules/$m/filesystem" ] \
        && cp -r "/repo/src/modules/$m/filesystem/." /filesystem/
done

# Normalise the payload to the modes a Linux checkout+render produces.
#
# Without this the test measures the HOST filesystem rather than the code:
# this repo is developed on Windows, where every file in the working tree
# reads as 0755, and the old `cp -a` propagates whatever it finds. So the
# pre-refactor scripts appear to install /etc/systemd/network/*.network as
# 0755 here and as 0644 in CI - a difference in the mount, not in the change
# under test. generate.py marks exactly the generated *.sh files executable
# (write(..., executable=True)); everything else it writes is 0644, and of the
# two tracked payload files only usr/local/sbin/bgrpiimage-setup is 0755.
find /filesystem -type f -exec chmod 0644 {} +
find /filesystem/root/opt/bgrpiimage -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true
find /filesystem/root/usr/local/sbin -type f -exec chmod 0755 {} + 2>/dev/null || true

# Some scripts write into /boot/firmware; give them the file raspios ships.
mkdir -p /boot/firmware
printf '# stock config.txt\ndtparam=audio=on\n' > /boot/firmware/config.txt
mkdir -p /etc/update-motd.d /etc/systemd/network /etc/wpa_supplicant /var/lib/bgrpiimage
printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' > /etc/hosts
printf 'VERSION_CODENAME=trixie\nID=debian\n' > /etc/os-release

snapshot() {
    # path, mode and content hash for every file in the trees our modules
    # touch. cp -a preserves timestamps, so a find -newer approach would miss
    # exactly the files the network module copies.
    for d in /etc /opt /usr/local /boot /var/lib; do
        [ -d "$d" ] || continue
        find "$d" -type f -printf '%m %p ' -exec sha256sum {} \; 2>/dev/null \
            | awk '{print $1, $2, $3}'
        # Symlinks too, by target rather than content: bgrpiimage-network
        # points /etc/resolv.conf at systemd-resolved's stub, and a refactor
        # that dropped or retargeted that link would otherwise pass unnoticed.
        find "$d" -type l -printf 'LINK %p -> %l\n' 2>/dev/null
    done | sort
}

snapshot > /before.txt

if [ "$MODE" = "old" ]; then
    bash "/old/$MODULE" >/dev/null 2>&1
else
    bash "/repo/src/modules/$MODULE/start_chroot_script" >/dev/null 2>&1
fi
run_rc=$?

snapshot > /after.txt

echo "### exit status"
echo "$run_rc"
echo "### filesystem delta"
comm -13 /before.txt /after.txt
echo "### external calls"
# Order can legitimately differ (the library groups apt calls), so compare the
# multiset rather than the sequence.
sort /calls.log | uniq -c | sed 's/^ *//'
