#!/usr/bin/env bash
# bgrpiimage-network: hand eth0/wlan0 to systemd-networkd and keep the other
# network managers out of the way.
set -euo pipefail

GEN=/opt/bgrpiimage/bgrpiimage-network
# shellcheck source=../bgrpiimage-common/apply-lib.sh
source /opt/bgrpiimage/bgrpiimage-common/apply-lib.sh

# NOTE: crda was removed from Debian in trixie - the regulatory database
# (wireless-regdb) is now loaded directly by the kernel via cfg80211.
# See https://tracker.debian.org/news/1510987/removed-crda/
bg_apt_update
bg_apt_install systemd-resolved wpasupplicant wireless-regdb iw rfkill

# systemd-networkd takes ownership of eth0/wlan0
bg_unit_enable systemd-networkd
bg_unit_enable systemd-resolved

# Disable NetworkManager / dhcpcd if present - they fight over interfaces.
#
# Image only, and bg_unit_mask enforces that. Masking NetworkManager on a
# device where an operator un-masked it for an LTE backhaul takes the WAN
# away - and because mask does not stop a running unit, it takes it away at
# the NEXT boot, which is the worst possible moment to find out and the
# hardest to attribute to an update that "succeeded" days earlier.
bg_unit_disable NetworkManager
bg_unit_disable dhcpcd
bg_unit_mask NetworkManager
# Masking NetworkManager.service alone leaves NetworkManager-wait-online.service
# symlinked into network-online.target.wants. It fails fast today because its
# Requires= is masked, but it is a second 60 s wait waiting to happen.
bg_unit_disable NetworkManager-wait-online.service
bg_unit_mask NetworkManager-wait-online.service NetworkManager-dispatcher.service

bg_install_tree "$GEN/systemd-networkd" /etc/systemd/network 0644
if bg_changed; then bg_intent "networkd-reload"; fi

# resolv.conf -> systemd-resolved stub.
#
# Image only. On a device this is a denylisted path: an isolated plant LAN
# with a static resolv.conf pointing at the customer's own DNS is normal, and
# replacing it with a link into /run breaks name resolution everywhere at
# once - apt, docker pull, NTP by name - in a way that surfaces hours later.
if bg_is_image; then
    ln -sf /run/systemd/resolve/stub-resolv.conf "$(bg_path /etc/resolv.conf)"
fi

# wpa_supplicant per-interface
#
# Image only, like the two other denylisted paths in this module - and this one
# was the exception by omission rather than by intent. /etc/wpa_supplicant/* is
# on BGRPI_DENY_GLOBS because a deployed unit's PSK is site data an update has
# no business rewriting, so bg_install refuses it and bg_die takes the module
# down with it. A failing module is not a warning either: bgrpiimage-update
# rolls the WHOLE update back and exits 1.
#
# That is not hypothetical. A device flashed at v0.5.0 still has this
# directory staged under /opt from its image, the payload extract merges rather
# than replaces, so the stale copy survives every update - and the module then
# reaches for a path it may not write, on a bundle that does not even carry
# one. Asking for a denied write and being refused is the module's bug; the
# denylist worked exactly as designed.
if bg_is_image && [[ -d "$GEN/wpa_supplicant" ]]; then
    bg_install_tree "$GEN/wpa_supplicant" /etc/wpa_supplicant 0600
    for f in "$(bg_path /etc/wpa_supplicant)"/wpa_supplicant-*.conf; do
        [[ -f "$f" ]] || continue
        iface=$(basename "$f" .conf); iface=${iface#wpa_supplicant-}
        bg_unit_enable "wpa_supplicant@${iface}.service"
    done
    # The staged copy carries the PSK in cleartext at the mode the generator
    # wrote, and nothing reads it after this point. See the v0.7.8 fix.
    rm -rf "$GEN/wpa_supplicant"
fi

# --- rfkill: lift the vendor soft block ---
# raspberrypi-sys-mods ships /etc/modprobe.d/rfkill_default.conf with
# `options rfkill default_state=0`, which soft-blocks EVERY radio type at
# module init. We ship a zz- prefixed override instead of editing that file:
# it is a dpkg conffile, so editing it turns every upgrade into a conflict.
bg_install_tree "$GEN/modprobe.d" /etc/modprobe.d 0644

# A saved WLAN block would be restored by systemd-rfkill on the next boot even
# with default_state=1. NEVER widen this glob to '*': the *:bluetooth entries
# are pi-gen's Bluetooth whitelist against default_state=0 and deleting them
# soft-blocks Bluetooth on CM4 (platform-fe215040.serial:bluetooth).
#
# Image only. rfkill saved state is device state, not configuration: a
# deployed unit whose radio an operator deliberately blocked under site policy
# must not have that decision quietly reversed by an update.
if bg_is_image; then
    rm -f "$(bg_path /var/lib/systemd/rfkill)"/*:wlan
fi
