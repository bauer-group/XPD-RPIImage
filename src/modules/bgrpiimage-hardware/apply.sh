#!/usr/bin/env bash
# bgrpiimage-hardware: the runtime half of the hardware blocks.
#
# config.txt lines (dtoverlay=i2c-rtc,*, overclock, fan, leds, pcie, camera)
# are bgrpiimage-boot's job. This module owns everything that is NOT a
# config.txt line: the RTC userspace services, the systemd watchdog drop-in,
# the EEPROM oneshot, and the default ALSA sink.
#
# Until this file existed the module had only a start_chroot_script, so every
# one of those settings was reachable ONLY by flashing a fresh image. That was
# worse than it sounds: the config.txt half travels through bgrpiimage-boot,
# which IS update-capable, so an update would roll out `dtoverlay=i2c-rtc` to a
# fleet and never enable hwclock.service to go with it. Half a feature, applied
# silently. Now both halves ride the same update.
#
# Runs at image build time (BGRPI_CTX=image, via start_chroot_script) and on a
# running device. See apply-lib.sh for the contract.
set -euo pipefail

GEN=/opt/bgrpiimage/bgrpiimage-hardware
# shellcheck source=../bgrpiimage-common/apply-lib.sh
source /opt/bgrpiimage/bgrpiimage-common/apply-lib.sh

# hardware.env carries the booleans that decide which branches below run. It is
# generated from the resolved variant JSON, so an absent file means the module
# has nothing to do rather than that something went wrong.
[[ -f "$GEN/hardware.env" ]] || exit 0
# shellcheck disable=SC1091  # generated at build time, not in the repo
source "$GEN/hardware.env"

# Unconditional, exactly as the chroot script did. Guarding it on
# packages.list existing looked like a free optimisation and is not one:
# bg_apt_update already returns immediately in device context, so the only
# thing the guard changes is the image build, where the refresh is wanted.
bg_apt_update
if [[ -f "$GEN/packages.list" ]]; then
    bg_apt_install_list "$GEN/packages.list"
fi

# --- RTC ---------------------------------------------------------------------
# The overlay wires the chip onto I2C; here we only make sure the system reads
# it at boot. util-linux's hwclock.service does that by itself once /dev/rtc0
# exists, so enabling it is the whole job.
if [[ "${BGRPIIMAGE_RTC_ENABLED:-no}" == "yes" ]]; then
    bg_unit_enable hwclock.service
fi
# fake-hwclock is the no-hardware fallback: it saves the time at shutdown and
# restores it at boot, so a device without an RTC starts at "shortly before it
# lost power" instead of 1970. Debian ships the unit pre-enabled; enabling it
# again is a no-op and costs nothing.
if [[ "${BGRPIIMAGE_RTC_FAKE_HWCLOCK:-no}" == "yes" ]]; then
    bg_unit_enable fake-hwclock.service
fi

# --- Watchdog ----------------------------------------------------------------
# /etc/systemd/system.conf.d/ is manager configuration, not a unit file, and
# that distinction decides the intent below.
#
# The result is captured HERE, immediately, rather than read off bg_any_changed
# at the end. bg_install_tree leaves BGRPI_LAST_CHANGED describing this tree
# only, and it is the next bg_install that overwrites it - so asking later
# would answer a different question and make an ALSA-only change request a
# reboot.
watchdog_changed=0
if [[ -d "$GEN/system.conf.d" ]]; then
    bg_install_tree "$GEN/system.conf.d" /etc/systemd/system.conf.d 0644
    bg_changed && watchdog_changed=1
fi

# --- EEPROM bootloader (Pi5 / CM5) ------------------------------------------
# rpi-eeprom-config cannot reach the target EEPROM from a chroot, so the work is
# staged as a oneshot that runs on the first real boot.
#
# IMAGE CONTEXT ONLY, and deliberately so. Everything else in this module is a
# file an update may freely correct; this one arms a service that rewrites the
# BOOTLOADER EEPROM. A wrong BOOT_ORDER there is not a failed service, it is a
# device that does not come back and cannot be reached over SSH to be fixed -
# the same reasoning that keeps /boot/firmware/cmdline.txt on the apply-lib
# denylist. Flashing an image is a deliberate act with the board in someone's
# hand; a config update is not, and must not be able to do this.
if bg_is_image && [[ -f "$GEN/eeprom.env" ]]; then
    bg_install "$GEN/eeprom.env" /etc/bgrpiimage/eeprom.env 0644
    bg_install "$GEN/bgrpiimage-eeprom-apply.sh" \
               /usr/local/sbin/bgrpiimage-eeprom-apply 0755
    bg_install "$GEN/bgrpiimage-eeprom-apply.service" \
               /etc/systemd/system/bgrpiimage-eeprom-apply.service 0644
    bg_unit_enable bgrpiimage-eeprom-apply.service
fi

# --- Default ALSA sink ------------------------------------------------------
if [[ -d "$GEN/alsa" ]]; then
    bg_install_tree "$GEN/alsa" /etc/alsa/conf.d 0644
fi

# Queue, do not act.
#
# The unit files above need a daemon-reload like any other module's.
#
# The watchdog drop-in does NOT: /etc/systemd/system.conf.d/ is read by PID 1
# when it starts, and `systemctl daemon-reload` re-reads unit files, not
# manager configuration. Re-reading that needs `daemon-reexec`, which the
# updater's intent vocabulary does not have and which is not a thing to do
# casually on a live industrial device - re-executing PID 1 under a watchdog
# whose timeout is being changed is precisely the wrong moment for a surprise.
# So a watchdog change is queued as a reboot instead. That is not a fallback:
# a watchdog only starts protecting the machine once PID 1 has armed it, and
# the reboot intent is deferred to the maintenance window the updater already
# honours for config.txt, so it costs nothing extra on a device that is going
# to reboot for its overlay change anyway.
if bg_any_changed; then
    bg_intent "daemon-reload"
fi
if [[ "$watchdog_changed" == "1" ]]; then
    bg_intent "reboot systemd watchdog configuration"
fi
