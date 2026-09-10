#!/usr/bin/env bash
# bgrpiimage-can: install can-utils and drop the systemd configs for can0/can1.
#
# Two file types land in the same directory on purpose, because systemd splits
# ownership between two daemons: 40-canN.network carries the [CAN] bitrate and
# is read by systemd-networkd, while 70-canN.link carries TransmitQueueLength
# and is read by systemd-udevd. Both have a section called [Link] with
# disjoint key sets, so a misplaced key is silently discarded rather than
# rejected. Alternative would be /etc/network/interfaces.d - but we already
# standardize on networkd, so we stay consistent.
#
# Runs at image build time (BGRPI_CTX=image, via start_chroot_script) and, once
# the updater lands, on a running device. See apply-lib.sh for the contract.
set -euo pipefail

GEN=/opt/bgrpiimage/bgrpiimage-can
# shellcheck source=../bgrpiimage-common/apply-lib.sh
source /opt/bgrpiimage/bgrpiimage-common/apply-lib.sh

bg_apt_update
bg_apt_install_list "$GEN/packages.list"

# Mirrored file by file rather than `cp -a` of the directory, so each file is
# compared by content: an unchanged interface produces no write and no intent,
# which is what makes re-applying a whole release cheap and quiet.
bg_install_tree "$GEN/systemd-networkd" /etc/systemd/network 0644

# Queue, do not act. Reconfiguring a CAN link takes a production control bus
# down for the duration, and this module cannot know whether the caller is a
# build (where nothing is running), an operator at a keyboard, or a timer at
# 03:00. The caller decides; see the intent model in apply-lib.sh.
if bg_changed; then
    bg_intent "udev-reload"
    bg_intent "networkd-reload"
fi
