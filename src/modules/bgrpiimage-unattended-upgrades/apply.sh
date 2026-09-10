#!/usr/bin/env bash
# bgrpiimage-unattended-upgrades: APT security updates inside a maintenance
# window, plus a reboot window that stock unattended-upgrades cannot express.
#
# Two triggers wire up the same check script:
#  (a) apt-daily-upgrade.service ExecStartPost drop-in -> event-driven,
#      runs immediately after every unattended-upgrade attempt. Reboot fires
#      only when /var/run/reboot-required was set by a package post-install.
#  (b) bgrpiimage-reboot-window.timer                  -> daily safety net,
#      catches devices that missed (a) (offline during the window, etc).
#
# Note on 50unattended-upgrades: it is a dpkg conffile of the
# unattended-upgrades package. Installing over it is safe for the same reason
# the /etc/bash.bashrc append in bgrpiimage-base is safe - dpkg cannot prompt
# during an unattended upgrade, so its non-interactive default keeps the
# modified file and writes the maintainer's version alongside as .dpkg-dist.
set -euo pipefail

GEN=/opt/bgrpiimage/bgrpiimage-unattended-upgrades
# shellcheck source=../bgrpiimage-common/apply-lib.sh
source /opt/bgrpiimage/bgrpiimage-common/apply-lib.sh

bg_apt_update
bg_apt_install unattended-upgrades apt-listchanges

bg_install "$GEN/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades 0644
bg_install "$GEN/20auto-upgrades"       /etc/apt/apt.conf.d/20auto-upgrades       0644

# Timer overrides shift both download + install into our maintenance window.
bg_install "$GEN/apt-daily.timer.d/override.conf" \
           /etc/systemd/system/apt-daily.timer.d/override.conf 0644
bg_install "$GEN/apt-daily-upgrade.timer.d/override.conf" \
           /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf 0644

# Conditional reboot service + timer (only present when auto_reboot.enabled).
if [[ -f "$GEN/bgrpiimage-reboot-window.sh" ]]; then
    bg_install "$GEN/bgrpiimage-reboot-window.sh" \
               /usr/local/sbin/bgrpiimage-reboot-window.sh 0755
    bg_install "$GEN/bgrpiimage-reboot-window.service" \
               /etc/systemd/system/bgrpiimage-reboot-window.service 0644
    bg_install "$GEN/bgrpiimage-reboot-window.timer" \
               /etc/systemd/system/bgrpiimage-reboot-window.timer 0644
    bg_install "$GEN/apt-daily-upgrade.service.d/override.conf" \
               /etc/systemd/system/apt-daily-upgrade.service.d/override.conf 0644
    bg_unit_enable bgrpiimage-reboot-window.timer
fi

bg_unit_enable unattended-upgrades

# Unit files and timer overrides only take effect after the manager re-reads
# them. Queued, not done here: the caller batches one daemon-reload for the
# whole transaction instead of one per module.
bg_intent "daemon-reload"
bg_intent "restart apt-daily.timer apt-daily-upgrade.timer"

# Build-time hygiene: shrink the image by dropping the package cache. On a
# running device this would throw away a cache the operator may still need.
if bg_is_image; then
    apt-get clean
fi
