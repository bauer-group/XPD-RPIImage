#!/usr/bin/env bash
# bgrpiimage-boot: maintain the bgRPIImage block in the firmware config.txt.
#
# The block is fenced so a re-run replaces it instead of appending a second
# copy - the property that makes this module re-appliable at all.
#
# The write is a whole-file replace through a temp file and rename(2), NOT the
# in-place `sed -i` + `>>` this used to do. Two separate writes to a file on
# /boot/firmware - which is FAT32, with no journal - leave a window in which
# config.txt has the old block deleted and the new one not yet appended. On a
# build that window is harmless because nothing interrupts a chroot. On a
# device it is the one file whose corruption cannot be fixed over SSH: no
# dtparam=spi=on and no mcp2515 overlays means both CAN interfaces simply do
# not exist at the next boot, and recovering needs an rpiboot jumper, a USB-C
# cable and someone standing at the cabinet.
set -euo pipefail

GEN=/opt/bgrpiimage/bgrpiimage-boot
# shellcheck source=../bgrpiimage-common/apply-lib.sh
source /opt/bgrpiimage/bgrpiimage-common/apply-lib.sh

CFG="$(bg_path "${BGRPIIMAGE_BOOT_CONFIG_PATH:-/boot/firmware/config.txt}")"

# Fallback for images that still use the legacy path.
if [[ ! -f "$CFG" && -f "$(bg_path /boot/config.txt)" ]]; then
    CFG="$(bg_path /boot/config.txt)"
fi
if [[ ! -f "$CFG" ]]; then
    bg_warn "no config.txt found - skipping"
    exit 0
fi

START_MARK="# >>> bgrpiimage AUTO-GENERATED >>>"
END_MARK="# <<< bgrpiimage AUTO-GENERATED <<<"

# Build the intended file in memory: everything outside the fence, unchanged,
# followed by a freshly generated fence.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# The blank line in front of the fence is separator, not content, so it has to
# be regenerated rather than preserved. Deleting only START..END leaves the
# previous separator behind, and the next run adds another - the file grew one
# blank line per apply and its hash changed every time, which on a device
# means a reboot intent for an update that altered nothing. Command
# substitution strips ALL trailing newlines; printf puts exactly one back.
body="$(
    if grep -qF "$START_MARK" "$CFG"; then
        sed "/${START_MARK//\//\\/}/,/${END_MARK//\//\\/}/d" "$CFG"
    else
        cat "$CFG"
    fi
)"
{
    printf '%s\n' "$body"
    printf '\n%s\n' "$START_MARK"
    cat "$GEN/config-bgrpiimage.txt"
    printf '%s\n' "$END_MARK"
} > "$tmp"

if [[ "$(sha256sum "$tmp" | cut -d' ' -f1)" == "$(sha256sum "$CFG" | cut -d' ' -f1)" ]]; then
    exit 0
fi

if bg_dry; then
    bg_log "would rewrite ${CFG#"$BGRPI_ROOT"}"
    exit 0
fi

# Keep the outgoing file on a device, where it is the only way back if the new
# overlays do not probe. At build time the previous content is the stock
# raspios config, which is reproducible from the base image.
if bg_is_device; then
    cp -p "$CFG" "${CFG}.bgrpiimage-bak" 2>/dev/null || true
fi

# Same filesystem, so this is a rename(2) and not a copy: config.txt is either
# entirely the old file or entirely the new one, never a truncated mixture.
install -m 0755 -d "$(dirname "$CFG")"
cat "$tmp" > "${CFG}.new"
sync
mv -f "${CFG}.new" "$CFG"
# FAT32 has no journal, so flush the directory entry too rather than trusting
# the page cache to survive the power cut this whole dance exists to survive.
sync
bg_log "rewrote ${CFG#"$BGRPI_ROOT"}"

# Overlays and dtparams are read by the firmware at boot; nothing takes effect
# until then, and nothing here can force it.
bg_intent "reboot config.txt"
