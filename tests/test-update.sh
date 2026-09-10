#!/usr/bin/env bash
# End-to-end test for bgrpiimage-update against a device that is NOT pristine.
#
# A fresh container is the easy case and not the interesting one. Every device
# this will ever run on has been touched: someone rotated the password, pinned
# a static IP, changed a CAN bitrate with whatever helper the image shipped
# with. The refusals and the preservation rules are the whole product, so the
# fixtures here are deliberately dirty and most of the assertions are
# negative - "this must NOT have happened".
#
# The mock release is served over real TLS with a throwaway CA in the trust
# store, because the updater pins --proto '=https' --tlsv1.2 and an http mock
# would only prove the pin works rather than exercising the path a device
# takes.
#
# Requires a bundle in dist/ - `make test-update` renders and packs first.
#
#   bash tests/test-update.sh          # or: make test-update
set -uo pipefail

if [ -z "${BGRPI_TEST_INNER:-}" ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
    ls "$root"/dist/*.confbundle.tar.gz >/dev/null 2>&1 \
        || { echo "no bundle in dist/ - run: make bundle" >&2; exit 1; }
    mount="$root"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) mount=$(cygpath -w "$root"); export MSYS_NO_PATHCONV=1 ;;
    esac
    exec docker run --rm -e BGRPI_TEST_INNER=1 \
        -v "${mount}:/repo:ro" debian:trixie-slim \
        bash /repo/tests/test-update.sh
fi

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
sect() { echo "=== $* ==="; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
    curl jq ca-certificates openssl python3 >/dev/null 2>&1

# Newest by mtime, not first alphabetically. dist/ accumulates bundles on a
# developer's machine, and `ls | head -1` picked the lowest version string
# there - so the gate meant to guard a commit tested a months-old bundle.
# CI never noticed because CI only ever has the one it just built.
BUNDLE=$(ls -1t /repo/dist/*.confbundle.tar.gz | head -1)

# The bundle CARRIES bgrpiimage-update, and `apply` installs it over
# /usr/local/sbin - so every assertion made after an apply exercises the
# PACKED copy, not the working tree. Editing the script and running this file
# directly therefore tests the previous version and reports passes that mean
# nothing. `make test-update` depends on `bundle` to avoid this; this check is
# for the direct run, and it exists because it already cost an afternoon.
if ! cmp -s <(tar xzOf "$BUNDLE" root/usr/local/sbin/bgrpiimage-update 2>/dev/null) \
            /repo/src/modules/bgrpiimage-base/filesystem/root/usr/local/sbin/bgrpiimage-update
then
    echo "STALE BUNDLE: $(basename "$BUNDLE") carries a bgrpiimage-update that differs"
    echo "from src/. Everything after an apply would test the packed copy. Re-pack first:"
    echo "  make bundle    # or: python scripts/bundle.py config/variants/<variant>.json --out dist"
    exit 1
fi
VERSION=$(basename "$BUNDLE" | sed 's/.*-v\(.*\)\.confbundle\.tar\.gz/\1/')
VARIANT=$(basename "$BUNDLE" | sed 's/^bgrpiimage-\(.*\)-v.*/\1/')
BASE_SHA=$(tar xzOf "$BUNDLE" manifest.json | jq -r '.applies_to.base_image_sha256')

# Every networkd file this bundle ships, by basename. Used both to assert
# the apply landed and to pick an interface for the shadowing test, so the
# suite means the same thing for a variant with CAN and one without.
NET_FILES=$(tar tzf "$BUNDLE" | grep '/systemd-networkd/' | xargs -r -n1 basename | sort)
# Prefer a CAN interface when the variant has one: that is the hazard this
# check exists for, and the one docs/post-flash-setup.md documents.
SHADOW_SRC=$(printf '%s\n' "$NET_FILES" | grep -E '^[0-9]+-can.*\.network$' | head -1)
[ -n "$SHADOW_SRC" ] || SHADOW_SRC=$(printf '%s\n' "$NET_FILES" | grep '\.network$' | head -1)
SHADOW_IFACE=$(printf '%s' "$SHADOW_SRC" | sed 's/^[0-9]*-//; s/\.network$//')
echo "bundle: $VARIANT v$VERSION   networkd files: $(printf '%s' "$NET_FILES" | tr '\n' ' ')"
echo "shadowing test will use: ${SHADOW_IFACE:-none}"

# --- stubs: the updater asks systemd about effect, not files ---------------
mkdir -p /stub
for c in systemctl udevadm sshd; do printf '#!/bin/sh\nexit 0\n' > "/stub/$c"; chmod +x "/stub/$c"; done
printf '#!/bin/sh\nexit 0\n' > /stub/systemd-analyze; chmod +x /stub/systemd-analyze
printf '#!/bin/sh\nexit 0\n' > /stub/journalctl;      chmod +x /stub/journalctl
cat > /stub/networkctl <<'EOF'
#!/bin/sh
# `status <iface>` is how the updater proves which file actually applied.
case "$1" in
  status) echo "Network File: /etc/systemd/network/40-$2.network" ;;
esac
exit 0
EOF
chmod +x /stub/networkctl
export PATH="/stub:$PATH"

# --- TLS + a release that looks like GitHub's -----------------------------
mkdir -p /srv/tls && cd /srv/tls || exit 1
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 1 \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' >/dev/null 2>&1
cp cert.pem /usr/local/share/ca-certificates/t.crt && update-ca-certificates >/dev/null 2>&1

REPO=bauer-group/XPD-RPIImage
WEB=/srv/web
DL="$WEB/$REPO/releases/download/v$VERSION"
mkdir -p "$DL" "$WEB/repos/$REPO/releases"
printf '{"tag_name":"v%s"}\n' "$VERSION" > "$WEB/repos/$REPO/releases/latest"
cp "$BUNDLE" "$DL/"
cp /repo/dist/*.bundle.manifest.json "$DL/" 2>/dev/null || \
    tar xzOf "$BUNDLE" manifest.json > "$DL/bgrpiimage-${VARIANT}-v${VERSION}.bundle.manifest.json"
# The detached signature for the standalone manifest. `check` fetches it to
# decide whether the manifest it is about to believe is genuine, so serving it
# is what exercises the trusted path rather than the unverifiable one.
cp /repo/dist/*.bundle.manifest.json.sig "$DL/" 2>/dev/null || \
    tar xzOf "$BUNDLE" manifest.json.sig > "$DL/bgrpiimage-${VARIANT}-v${VERSION}.bundle.manifest.json.sig"
( cd "$DL" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )

# Helpers and trust keys, exactly as the release job publishes them.
B=/repo/src/modules/bgrpiimage-base/filesystem/root
install -m 0755 "$B/usr/local/sbin/bgrpiimage-setup"  "$DL/bgrpiimage-setup"
install -m 0755 "$B/usr/local/sbin/bgrpiimage-update" "$DL/bgrpiimage-update"
install -m 0644 "$B"/usr/share/bgrpiimage/trusted-keys.d/*.pub "$DL/"

cd "$WEB" || exit 1
python3 -c "
import http.server, ssl, socketserver, os
os.chdir('$WEB')
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('/srv/tls/cert.pem', '/srv/tls/key.pem')
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
h = socketserver.TCPServer(('127.0.0.1', 8443), Q)
h.socket = ctx.wrap_socket(h.socket, server_side=True)
h.serve_forever()
" &
sleep 2
export BGRPIIMAGE_UPDATE_API=https://localhost:8443
export BGRPIIMAGE_UPDATE_DL=https://localhost:8443
export BGRPIIMAGE_UPDATE_REPO="$REPO"

U=/usr/local/sbin/bgrpiimage-update

# ---------------------------------------------------------------------------
# A device that has been in service, not a fresh one.
# ---------------------------------------------------------------------------
seed_device() { # seed_device [version] [variant] [base_sha] [contract]
    rm -rf /etc/bgrpiimage-release /etc/bgrpiimage-applied /var/lib/bgrpiimage \
           /opt/bgrpiimage /etc/systemd/network /boot/firmware
    mkdir -p /etc/systemd/network /etc/ssh/sshd_config.d /etc/update-motd.d /etc/sudoers.d \
             /etc/apt/apt.conf.d /etc/modprobe.d /boot/firmware/overlays \
             /var/lib/bgrpiimage /usr/local/sbin /etc/profile.d /var/run
    # The updater ships inside the bundle, but the device must already have a
    # copy to run - exactly as a flashed unit does.
    install -m 0755 /repo/src/modules/bgrpiimage-base/filesystem/root/usr/local/sbin/bgrpiimage-update "$U"
    install -m 0755 /repo/src/modules/bgrpiimage-base/filesystem/root/usr/local/sbin/bgrpiimage-setup /usr/local/sbin/
    install -m 0644 /repo/src/modules/bgrpiimage-base/filesystem/root/etc/profile.d/50-bgrpiimage-shell.sh /etc/profile.d/
    # The trust store a signed image ships. Section 10 removes it again to
    # cover hardware from before signing existed.
    mkdir -p /usr/share/bgrpiimage/trusted-keys.d
    cp /repo/src/modules/bgrpiimage-base/filesystem/root/usr/share/bgrpiimage/trusted-keys.d/*.pub \
       /usr/share/bgrpiimage/trusted-keys.d/ 2>/dev/null || true
    printf '# stock\ndtparam=audio=on\n' > /boot/firmware/config.txt
    printf '# stock bashrc\n' > /etc/bash.bashrc
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tbg-canbus\n' > /etc/hosts
    printf 'VERSION_CODENAME=trixie\n' > /etc/os-release
    for o in mcp2515-can0 mcp2515-can1; do : > "/boot/firmware/overlays/$o.dtbo"; done
    cat > /etc/bgrpiimage-release <<EOF
BGRPIIMAGE_DIST="bgrpiimage"
BGRPIIMAGE_VARIANT='${2:-$VARIANT}'
BGRPIIMAGE_VERSION='${1:-0.0.1}'
BGRPIIMAGE_BASE_IMAGE_SHA256='${3:-$BASE_SHA}'
BGRPIIMAGE_APPLY_CONTRACT=${4:-1}
EOF
}

sect "1. a device that is behind"
seed_device 0.0.1
$U check >/tmp/c 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q "available" /tmp/c && ok "check reports an update" || { bad "check did not report one"; cat /tmp/c; }

sect "2. plan changes nothing"
before=$(find /etc /boot -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum)
$U plan >/tmp/p 2>&1 || true
after=$(find /etc /boot -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum)
[ "$before" = "$after" ] && ok "plan wrote nothing outside /opt" || bad "plan modified the system"

sect "3. apply"
seed_device 0.0.1
$U apply --yes >/tmp/a 2>&1; rc=$?
[ $rc -eq 0 ] && ok "apply succeeded" || { bad "apply failed"; tail -20 /tmp/a; }
grep -q "BGRPIIMAGE_CONFIG_VERSION='$VERSION'" /etc/bgrpiimage-applied \
    && ok "config version stamped in the applied file" || bad "config version not stamped"
grep -q "BGRPIIMAGE_VERSION='0.0.1'" /etc/bgrpiimage-release \
    && ok "release file still reports the FLASHED image" \
    || bad "release file was overwritten - the base-image check would be destroyed"
missing=""
for n in $NET_FILES; do
    [ -f "/etc/systemd/network/$n" ] || missing="$missing $n"
done
[ -z "$missing" ] && ok "every networkd file the bundle carries landed" \
                  || bad "not installed:$missing"
grep -q 'bgrpiimage AUTO-GENERATED' /boot/firmware/config.txt \
    && ok "config.txt fence written" || bad "config.txt not updated"
[ -f /var/run/reboot-required ] && ok "reboot handed to the existing window machinery" || bad "no reboot flag"

sect "4. applying the same release again"
$U apply --yes >/tmp/a2 2>&1; rc=$?
grep -q "already at" /tmp/a2 && ok "refuses as already current (rc=$rc)" || { bad "did not detect already-current"; tail -5 /tmp/a2; }

sect "5. refusals"
# Only reachable via --file: the download path builds the asset name from
# the device's own variant, so a wrong-variant bundle cannot be fetched. The
# realistic case is an operator handed the wrong file.
seed_device 0.0.1 "some-other-variant"
$U apply --yes --file "$BUNDLE" >/tmp/r 2>&1; grep -qi "this device is" /tmp/r \
    && ok "variant mismatch refused (--file)" || { bad "variant mismatch allowed"; tail -3 /tmp/r; }

seed_device 0.0.1 "$VARIANT" "0000000000000000000000000000000000000000000000000000000000000000"
$U apply --yes >/tmp/r 2>&1; grep -qi "reflash required" /tmp/r \
    && ok "base OS change refused" || { bad "base OS change allowed"; tail -3 /tmp/r; }

seed_device 0.0.1 "$VARIANT" "$BASE_SHA" 0
$U apply --yes >/tmp/r 2>&1; grep -qi "predates in-place updates" /tmp/r \
    && ok "pre-contract image refused" || { bad "pre-contract image allowed"; tail -3 /tmp/r; }

seed_device 99.0.0
$U apply --yes >/tmp/r 2>&1; grep -qi "older than the installed" /tmp/r \
    && ok "implicit downgrade refused" || { bad "downgrade allowed"; tail -3 /tmp/r; }

sect "6. an operator override that would swallow a new setting"
seed_device 0.0.1
if [ -z "$SHADOW_IFACE" ]; then
    ok "skipped: this variant ships no .network file to shadow"
else
    # The shape a helper older than the release would have written: the
    # [Match] section and one setting, missing whatever the release added.
    # For CAN that is exactly the v0.7.2 case - a bitrate override with no
    # RestartSec, which silently turns bus-off recovery back off.
    lost=$(tar xzOf "$BUNDLE" "$(tar tzf "$BUNDLE" | grep "/${SHADOW_SRC}\$" | head -1)" \
           | grep -oE '^[A-Za-z]+=' | tr -d '=' | grep -vE '^(Name)$' | tail -1)
    cat > "/etc/systemd/network/05-bgrpiimage-${SHADOW_IFACE}.network" <<EOF
[Match]
Name=${SHADOW_IFACE}
EOF
    $U apply --yes >/tmp/s 2>&1
    if grep -qi "silently discard" /tmp/s; then
        ok "refused because the override lacks keys the release adds"
        grep -qi "$lost" /tmp/s && ok "names a setting that would be lost ($lost)" \
                                || bad "did not name the lost key"
    else
        bad "applied over a shadowing override"; tail -6 /tmp/s
    fi
fi

sect "7. what an update must never touch"
seed_device 0.0.1
printf 'admin:$6$rotated$hash:20000:0:99999:7:::\n' > /etc/shadow
printf 'nameserver 10.0.0.1\n' > /etc/resolv.conf
printf 'admin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/010-bgrpiimage-admin
sha_shadow=$(sha256sum /etc/shadow); sha_resolv=$(sha256sum /etc/resolv.conf)
sha_sudo=$(sha256sum /etc/sudoers.d/010-bgrpiimage-admin); sha_hosts=$(sha256sum /etc/hosts)
# The fixtures have to exist, or the comparisons below are two identical
# sha256sum failures reporting success for a file that was never there.
for f in /etc/shadow /etc/resolv.conf /etc/sudoers.d/010-bgrpiimage-admin /etc/hosts; do
    [ -s "$f" ] || bad "fixture missing: $f"
done
$U apply --yes >/tmp/t 2>&1 || true
[ "$(sha256sum /etc/shadow)" = "$sha_shadow" ] && ok "rotated password untouched" || bad "/etc/shadow was modified"
[ "$(sha256sum /etc/resolv.conf)" = "$sha_resolv" ] && ok "static resolv.conf untouched" || bad "/etc/resolv.conf was modified"
[ "$(sha256sum /etc/sudoers.d/010-bgrpiimage-admin)" = "$sha_sudo" ] && ok "sudoers untouched" || bad "sudoers was modified"
[ "$(sha256sum /etc/hosts)" = "$sha_hosts" ] && ok "hosts untouched" || bad "/etc/hosts was modified"
[ ! -f /opt/bgrpiimage/bgrpiimage-users/create-users.sh ] \
    && ok "users module is not in the bundle" || bad "users module shipped"

sect "8. rollback"
seed_device 0.0.1
cp /boot/firmware/config.txt /tmp/config.before
$U apply --yes >/dev/null 2>&1 || true
$U rollback >/tmp/rb 2>&1; rc=$?
[ $rc -eq 0 ] && ok "rollback ran" || { bad "rollback failed"; tail -5 /tmp/rb; }
cmp -s /tmp/config.before /boot/firmware/config.txt \
    && ok "config.txt restored to its pre-apply content" || bad "config.txt not restored"

sect "9. a corrupt download"
seed_device 0.0.1
printf 'tampered' >> "$DL/$(basename "$BUNDLE")"
$U apply --yes >/tmp/x 2>&1; grep -qi "checksum mismatch" /tmp/x \
    && ok "corrupt bundle refused" || { bad "corrupt bundle accepted"; tail -3 /tmp/x; }
cp "$BUNDLE" "$DL/"

sect "10. signatures"
seed_device 0.0.1
$U apply --yes >/tmp/sg 2>&1 || true
grep -qi "signature verified" /tmp/sg \
    && ok "a genuine bundle verifies against the shipped key" \
    || { bad "signature was not verified"; tail -4 /tmp/sg; }

# A tampered manifest must fail the signature, not merely the file hashes:
# the signature is what stands between a device and whoever can write to the
# release, and the per-file hashes are only as good as the manifest carrying
# them.
seed_device 0.0.1
work=/tmp/tamper && rm -rf $work && mkdir -p $work
tar xzf "$DL/$(basename "$BUNDLE")" -C $work
sed -i 's/"version": "/"version": "9/' $work/manifest.json
( cd $work && tar czf "$DL/$(basename "$BUNDLE")" manifest.json manifest.json.sig root )
( cd "$DL" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )
$U apply --yes >/tmp/sg2 2>&1
grep -qi "signature does not match" /tmp/sg2 \
    && ok "tampered manifest refused by signature" \
    || { bad "tampered manifest accepted"; tail -4 /tmp/sg2; }
cp "$BUNDLE" "$DL/"
( cd "$DL" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )

# Signed by a key the device does not know.
seed_device 0.0.1
rm -rf $work && mkdir -p $work
tar xzf "$BUNDLE" -C $work
openssl genpkey -algorithm ed25519 -out /tmp/foreign.key 2>/dev/null
openssl pkeyutl -sign -rawin -inkey /tmp/foreign.key \
    -in $work/manifest.json -out $work/manifest.json.sig 2>/dev/null
( cd $work && tar czf "$DL/$(basename "$BUNDLE")" manifest.json manifest.json.sig root )
( cd "$DL" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )
$U apply --yes >/tmp/sg3 2>&1
grep -qi "does not match any trusted key" /tmp/sg3 \
    && ok "foreign signature refused" \
    || { bad "foreign signature accepted"; tail -4 /tmp/sg3; }

# Unsigned entirely.
seed_device 0.0.1
rm -rf $work && mkdir -p $work
tar xzf "$BUNDLE" -C $work && rm -f $work/manifest.json.sig
( cd $work && tar czf "$DL/$(basename "$BUNDLE")" manifest.json root )
( cd "$DL" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )
$U apply --yes >/tmp/sg4 2>&1
grep -qi "not signed" /tmp/sg4 \
    && ok "unsigned bundle refused" || { bad "unsigned bundle accepted"; tail -4 /tmp/sg4; }
cp "$BUNDLE" "$DL/"
( cd "$DL" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )

# Hardware from before signing: the image carries no trust store at all. This
# is the case an existing fleet is in, so the message has to say what to do
# rather than just fail.
seed_device 0.0.1
rm -rf /usr/share/bgrpiimage/trusted-keys.d
$U apply --yes >/tmp/sg5 2>&1
grep -qi "no trusted keys" /tmp/sg5 \
    && ok "a device with no trust store refuses and explains" \
    || { bad "device without trust store did not refuse clearly"; tail -4 /tmp/sg5; }

sect "11. bootstrapping hardware from before in-place updates"
# What a device flashed at, say, v0.7.7 actually looks like: no updater, no
# trust store, and a release file with none of the identity the checks need.
# The documented procedure has to take it from there to a working update, or
# an existing fleet can never join without a reflash.
seed_device 0.0.1
rm -rf /usr/share/bgrpiimage/trusted-keys.d /usr/local/sbin/bgrpiimage-update
cat > /etc/bgrpiimage-release <<EOF
BGRPIIMAGE_DIST="bgrpiimage"
BGRPIIMAGE_VARIANT='$VARIANT'
BGRPIIMAGE_VERSION='0.7.7'
EOF

# It must refuse before the bootstrap - otherwise this proves nothing.
if [ -x /usr/local/sbin/bgrpiimage-update ]; then
    bad "fixture is wrong: the updater is still installed"
else
    ok "a pre-update device has no updater at all"
fi

# --- the documented procedure, run verbatim --------------------------------
R="$BGRPIIMAGE_UPDATE_DL/$REPO/releases/download/v$VERSION"
curl -fsSL --proto '=https' -o /usr/local/sbin/bgrpiimage-update "$R/bgrpiimage-update"
chmod 0755 /usr/local/sbin/bgrpiimage-update
curl -fsSL --proto '=https' -o /usr/local/sbin/bgrpiimage-setup  "$R/bgrpiimage-setup"
chmod 0755 /usr/local/sbin/bgrpiimage-setup
install -d /usr/share/bgrpiimage/trusted-keys.d
curl -fsSL --proto '=https' \
     -o /usr/share/bgrpiimage/trusted-keys.d/bgrpiimage-recovery.pub \
     "$R/bgrpiimage-recovery.pub"
# base_image.sha256 has been the same since v0.5.0, so any device from that
# release onwards is provably on this base - see the note in the docs.
{
  echo "BGRPIIMAGE_BASE_IMAGE_SHA256='$BASE_SHA'"
  echo "BGRPIIMAGE_APPLY_CONTRACT=1"
} >> /etc/bgrpiimage-release

$U apply --yes >/tmp/bs 2>&1; rc=$?
[ $rc -eq 0 ] && ok "bootstrapped device applies the update" \
              || { bad "apply failed after bootstrap"; tail -12 /tmp/bs; }
grep -qi "signature verified" /tmp/bs \
    && ok "and verifies the signature against the fetched key" \
    || bad "signature was not verified after bootstrap"
grep -q "BGRPIIMAGE_CONFIG_VERSION='$VERSION'" /etc/bgrpiimage-applied \
    && ok "configuration version recorded" || bad "version not recorded"
grep -q "BGRPIIMAGE_VERSION='0.7.7'" /etc/bgrpiimage-release \
    && ok "still reports the originally flashed image" \
    || bad "the flashed version was overwritten"

sect "12. payload the bundle no longer carries"
# A device flashed at v0.5.0 staged bgrpiimage-network/wpa_supplicant/ under
# /opt. No current bundle carries that directory, but the payload extract used
# to merge rather than replace, so it survived every update - and
# bgrpiimage-network then reached for /etc/wpa_supplicant/*, which the denylist
# forbids on a running device. bg_install refused, the module died, and a failed
# module rolls the entire update back. The device could not be updated at all.
seed_device 0.0.1
mkdir -p /opt/bgrpiimage/bgrpiimage-network/wpa_supplicant
cat > /opt/bgrpiimage/bgrpiimage-network/wpa_supplicant/wpa_supplicant-wlan0.conf <<'EOF'
network={
    ssid="stale-from-the-flashed-image"
    psk="cleartext-left-behind"
}
EOF

$U apply --yes >/tmp/stale 2>&1; rc=$?
[ $rc -eq 0 ] && ok "an update is not defeated by stale payload" \
              || { bad "apply failed on stale payload (rc=$rc)"; tail -12 /tmp/stale; }
grep -q "rolling back" /tmp/stale \
    && bad "the whole update was rolled back" \
    || ok "and nothing was rolled back"
[ ! -e /opt/bgrpiimage/bgrpiimage-network/wpa_supplicant ] \
    && ok "the stale directory is gone, with the cleartext PSK in it" \
    || bad "stale payload survived the update"
# The replace must not become a wipe: what the bundle DOES carry has to be there.
[ -f /opt/bgrpiimage/bgrpiimage-network/systemd-networkd/10-eth.network ] \
    && ok "and the payload the bundle carries is still installed" \
    || bad "replacing the payload dir removed files the bundle carries"

sect "13. a release this variant has no bundle for"
# What v0.13.4 looked like from a device: the release exists, `check`
# advertises it, but no confbundle was published for this variant - so the
# download 404s. The run has to stop THERE, naming that reason.
#
# It did not. download_bundle reports failure with `die`, which is `exit 1`,
# and prepare() is only ever called as `dir=$(prepare)`. Bash CLEARS the -e
# option inside a command-substitution subshell when not in posix mode, so
# errexit was not in force anywhere inside prepare(): the die exited its own
# subshell, the empty string was assigned to $tarball, and extract_bundle ran
# tar on "" three times. The operator's LAST message - the one they act on -
# was "bundle has no manifest.json", which blames the bundle for a 404.
seed_device 0.0.1
printf '{"tag_name":"v%s"}\n' "99.99.99" > "$WEB/repos/$REPO/releases/latest"

$U apply --yes >/tmp/nb 2>&1; rc=$?
[ $rc -ne 0 ] && ok "apply refuses when there is no bundle (rc=$rc)" \
              || { bad "apply reported success with no bundle"; tail -5 /tmp/nb; }
grep -q "no bundle for" /tmp/nb \
    && ok "and names the missing bundle as the reason" \
    || { bad "did not report the missing bundle"; tail -5 /tmp/nb; }
grep -qE 'tar \(child\)|Cannot open' /tmp/nb \
    && { bad "tar ran on an empty path"; grep -cE 'tar \(child\)' /tmp/nb; } \
    || ok "and no tar cascade reached the operator"
grep -qi "no manifest.json" /tmp/nb \
    && bad "blames a missing manifest for what was a 404" \
    || ok "and does not blame the manifest"
# The reason the operator acts on is the last one printed, not the first.
[ "$(grep -cE '^\[x\]|\[x\]' /tmp/nb)" -le 1 ] \
    && ok "exactly one failure is reported" \
    || { bad "more than one failure reported - the last one misleads"; grep '\[x\]' /tmp/nb; }
[ ! -f /etc/bgrpiimage-applied ] && ok "and nothing was applied" || bad "state was written"

# A device that cannot reach the release API must fail the same way: one
# reason, the true one. Same root cause, different entry point.
seed_device 0.0.1
BGRPIIMAGE_UPDATE_API=https://127.0.0.1:9 $U apply --yes >/tmp/nr 2>&1; rc=$?
[ $rc -ne 0 ] && ok "apply refuses when the release API is unreachable" \
              || bad "apply continued without resolving a version"
grep -qi "could not reach" /tmp/nr \
    && ok "and says so" || { bad "did not name the unreachable API"; tail -3 /tmp/nr; }
grep -qi "not a release version" /tmp/nr \
    && bad "follows the real error with a misleading empty-version message" \
    || ok "and does not follow it with a misleading empty-version message"

printf '{"tag_name":"v%s"}\n' "$VERSION" > "$WEB/repos/$REPO/releases/latest"

sect "14. an archive tar cannot read must fail closed"
# The two guards above the extract - "nothing outside root/ and manifest.json"
# and "no absolute or traversing paths" - used to run `tar tzf | grep ... ||
# true`, which hides tar's own exit status behind grep's. An archive tar
# cannot read produces no lines, so grep matches nothing and BOTH guards
# passed: an archive nothing had inspected was certified clean. This serves a
# file whose checksum is correct - so the transfer check cannot catch it - but
# which is not an archive at all.
seed_device 0.0.1
head -c 4096 /dev/urandom > "$DL/$(basename "$BUNDLE")"
( cd "$DL" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )
$U apply --yes >/tmp/na 2>&1; rc=$?
[ $rc -ne 0 ] && ok "apply refuses an unreadable archive (rc=$rc)" \
              || bad "an unreadable archive was accepted"
grep -qi "cannot read" /tmp/na \
    && ok "and says the archive could not be read" \
    || { bad "did not report an unreadable archive"; tail -4 /tmp/na; }
[ ! -f /etc/bgrpiimage-applied ] && ok "and nothing was applied" || bad "state was written"
cp "$BUNDLE" "$DL/"
( cd "$DL" && sha256sum "$(basename "$BUNDLE")" > "$(basename "$BUNDLE").sha256" )

sect "15. the rollback point is real, and a broken one is not hidden"
# snapshot() used to `|| true` its tar, print "snapshot: ..." either way and
# then move last-rollback regardless - so a device that could not write the
# snapshot was told it had a rollback point, lost the pointer to the one it
# really had, and applied anyway. It also ended its file-list loop on the
# status of the last `[[ -f ]]` test, so a bundle whose last path was a file
# the device did not have yet aborted apply under errexit with no output.
seed_device 0.0.1
$U apply --yes >/tmp/sn 2>&1; rc=$?
[ $rc -eq 0 ] && ok "apply succeeded" || { bad "apply failed (rc=$rc)"; tail -12 /tmp/sn; }
snap=$(cat /var/lib/bgrpiimage/last-rollback 2>/dev/null || true)
{ [ -n "$snap" ] && [ -f "$snap" ]; } \
    && ok "last-rollback points at a snapshot that exists" \
    || bad "last-rollback does not name a real snapshot: '${snap:-}'"
tar tzf "$snap" >/dev/null 2>&1 \
    && ok "and that snapshot is a readable archive" || bad "snapshot is not readable"

# A restore that cannot complete must say so. Unchecked, it took errexit's
# silent exit and never reached the applied-state write, so `status` went on
# reporting the result of the apply the operator had just tried to undo.
printf 'not a tarball at all' > "$snap"
$U rollback >/tmp/rb2 2>&1; rc=$?
[ $rc -ne 0 ] && ok "rollback refuses a damaged snapshot (rc=$rc)" \
              || bad "rollback reported success restoring a damaged snapshot"
grep -qi "failed part-way" /tmp/rb2 \
    && ok "and names the failure" \
    || { bad "rollback failed silently"; sed 's/^/      | /' /tmp/rb2; }
grep -q "BGRPIIMAGE_CONFIG_RESULT='rolled-back'" /etc/bgrpiimage-applied \
    && bad "recorded a rollback that did not happen" \
    || ok "and does not record a rollback that did not happen"

sect "16. check answers applicability, not just novelty"
# check used to verify one thing: that the published tag differed from the
# installed one. Everything else that can make an apply impossible - no bundle
# for this variant, an older version, a contract or format this image cannot
# take - was left for apply to discover after the full download. Worse, it
# said "run: sudo bgrpiimage-update apply" in every one of those cases.
seed_device 0.0.1
$U check >/tmp/ck 2>&1; rc=$?
[ $rc -eq 1 ] && ok "an applicable update exits 1" \
              || { bad "expected 1, got $rc"; tail -3 /tmp/ck; }
grep -qi "could not verify the manifest signature" /tmp/ck \
    && { bad "did not verify the published manifest signature"; sed 's/^/      | /' /tmp/ck; } \
    || ok "and verified the manifest signature before believing it"

# Exactly the v0.13.4 case: the release exists, the bundle does not yet.
printf '{"tag_name":"v%s"}\n' "99.99.99" > "$WEB/repos/$REPO/releases/latest"
$U check >/tmp/ck2 2>&1; rc=$?
[ $rc -eq 2 ] && ok "a release with no bundle for this variant exits 2, not 1" \
              || { bad "expected 2, got $rc"; tail -3 /tmp/ck2; }
grep -qi "no configuration bundle" /tmp/ck2 \
    && ok "and says the bundle has not landed yet" || bad "did not explain why"
grep -qi "run: sudo.*apply" /tmp/ck2 \
    && bad "still tells the operator to run an apply that would 404" \
    || ok "and does not send the operator into a failing apply"
printf '{"tag_name":"v%s"}\n' "$VERSION" > "$WEB/repos/$REPO/releases/latest"

# A published version older than the installed one is not an update. preflight
# already refused it - but only after downloading and verifying the bundle.
seed_device 99.0.0
$U check >/tmp/ck3 2>&1; rc=$?
[ $rc -eq 2 ] && ok "an older published version exits 2" \
              || { bad "expected 2, got $rc"; tail -3 /tmp/ck3; }
grep -qi "older than the installed" /tmp/ck3 \
    && ok "and says so instead of advertising a downgrade" || bad "advertised a downgrade"

# An image from before the identity contract can never apply anything. It used
# to be told to apply, every time, forever.
seed_device 0.0.1 "$VARIANT" "$BASE_SHA" 0
$U check >/tmp/ck4 2>&1; rc=$?
[ $rc -eq 3 ] && ok "a pre-contract image exits 3 (reflash)" \
              || { bad "expected 3, got $rc"; tail -3 /tmp/ck4; }

sect "17. apply when there is nobody to prompt"
# `read` returns 1 at end of input, and under errexit that ended the run
# before the refusal could be printed: apply from cron or Ansible exited 1
# with no output whatsoever.
seed_device 0.0.1
$U apply </dev/null >/tmp/ni 2>&1; rc=$?
[ $rc -ne 0 ] && ok "refuses without --yes on a closed stdin (rc=$rc)" \
              || bad "applied with nobody to consent"
grep -qi "stdin is not a terminal" /tmp/ni \
    && ok "and explains why, instead of exiting silently" \
    || { bad "exited without saying anything"; sed 's/^/      | /' /tmp/ni; }
[ ! -f /etc/bgrpiimage-applied ] && ok "and nothing was applied" || bad "state was written"

sect "18. the recorded helper version follows the helper on disk"
# The bundle carries bgrpiimage-setup and apply installs it, but only
# bgrpiimage-setup itself ever wrote BGRPIIMAGE_HELPER_VERSION. So the
# documented way back - `apply --version <older>` - put an older helper on
# disk while the record still named the newer one, and `update --self` then
# decided there was nothing to do and refused to fetch it back. The helper is
# the recovery tool; being silently pinned to an old copy with no CLI way out
# is the worst file for that to happen to.
seed_device 0.0.1
$U apply --yes >/tmp/hv 2>&1 || { bad "apply failed"; tail -8 /tmp/hv; }
grep -q "BGRPIIMAGE_HELPER_VERSION='$VERSION'" /etc/bgrpiimage-applied \
    && ok "apply records the helper version it just installed" \
    || { bad "helper version not recorded after apply"
         grep HELPER /etc/bgrpiimage-applied 2>/dev/null | sed 's/^/      | /' \
           || echo "      | (no BGRPIIMAGE_HELPER_VERSION line at all)"; }

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
