#!/usr/bin/env bash
# bgrpiimage-base: identity, locale, packages, banners and the operator helper.
set -euo pipefail

GEN=/opt/bgrpiimage/bgrpiimage-base
# shellcheck source=../bgrpiimage-common/apply-lib.sh
source /opt/bgrpiimage/bgrpiimage-common/apply-lib.sh

SETUP="$(bg_path /usr/local/sbin/bgrpiimage-setup)"
SHELL_SNIPPET="$(bg_path /etc/profile.d/50-bgrpiimage-shell.sh)"

# The helper must be executable or every `sudo bgrpiimage-setup ...` in the
# MOTD and in docs/post-flash-setup.md fails with "command not found". It is
# tracked 0755 in git, but assert it here so the image never depends on how
# the checkout or unpack preserved the mode bit.
bg_dry || chmod 0755 "$SETUP"
# Strip CRLF as well. The repo is developed on Windows and scripts/build.sh
# bind-mounts the working tree straight into the build container, so a
# checkout made without the repo's .gitattributes ships a `#!/usr/bin/env
# bash\r` shebang - which execs as "bad interpreter: No such file or
# directory" and reads to a user as "the command does not exist".
bg_dry || sed -i 's/\r$//' "$SETUP"

# --- interactive shell conveniences ---
# Debian leaves ll/la/l commented out in /etc/skel/.bashrc and pi-gen does not
# uncomment them, so every account - root included - came up without `ll`.
#
# /etc/profile.d covers LOGIN shells only. Debian's /etc/bash.bashrc, the
# system-wide rc for NON-login interactive bash, does not source
# /etc/profile.d, so `sudo su`, `sudo -s`, a bare `bash` and tmux panes would
# still miss out - and password-less `su` is a documented workflow of this
# image (docs/configuration.md). Hence both hooks.
#
# /etc/bash.bashrc is a dpkg conffile of the `bash` package. Appending to it
# is safe here: dpkg cannot prompt during an unattended upgrade, so its
# non-interactive default keeps this modified file and writes the
# maintainer's version alongside as /etc/bash.bashrc.dpkg-dist. The grep
# guard keeps the append idempotent when a rootfs is rebuilt in place.
bg_dry || sed -i 's/\r$//' "$SHELL_SNIPPET"
bg_dry || chmod 0644 "$SHELL_SNIPPET"
if ! grep -q '50-bgrpiimage-shell.sh' "$(bg_path /etc/bash.bashrc)" 2>/dev/null; then
    if bg_dry; then
        bg_log "would append the profile.d hook to /etc/bash.bashrc"
    else
    cat >> "$(bg_path /etc/bash.bashrc)" <<'__BGRPIIMAGE_SHELL_EOF__'

# bgRPIImage: same aliases the login-shell path gets via /etc/profile.d.
# Reached only in interactive shells - /etc/bash.bashrc returns early when
# PS1 is unset.
if [ -r /etc/profile.d/50-bgrpiimage-shell.sh ]; then
    . /etc/profile.d/50-bgrpiimage-shell.sh
fi
__BGRPIIMAGE_SHELL_EOF__
    fi
fi

# --- hostname ---
#
# Image only. The hostname is site data: renaming a live host mid-session
# breaks sudo's host lookup and the operator's own shell prompt, for a change
# nobody has ever shipped as a bugfix.
if [[ -f "$GEN/hostname" ]] && bg_is_image; then
    bg_install "$GEN/hostname" /etc/hostname 0644
    # `sed -i s/...` exits 0 whether or not it substituted anything, so the
    # `|| echo ... >>` fallback this used to carry was unreachable: an
    # /etc/hosts with no 127.0.1.1 line silently kept none, the hostname did
    # not resolve, and sudo printed "unable to resolve host" on every call.
    # Decide on the grep instead. The ^ anchor matters too - the old pattern
    # was unanchored and would also have rewritten a 127.0.1.10 entry.
    _hn=$(cat "$GEN/hostname")
    if grep -qE '^127\.0\.1\.1[[:space:]]' "$(bg_path /etc/hosts)"; then
        sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${_hn}/" "$(bg_path /etc/hosts)"
    else
        printf '127.0.1.1\t%s\n' "$_hn" >> "$(bg_path /etc/hosts)"
    fi
    unset _hn
fi

# --- locale & timezone ---
if [[ -f "$GEN/locale.env" ]] && bg_is_image; then
    # shellcheck disable=SC1090
    source "$GEN/locale.env"
    ln -sf "/usr/share/zoneinfo/$BGRPIIMAGE_TIMEZONE" "$(bg_path /etc/localtime)"
    echo "$BGRPIIMAGE_TIMEZONE" > "$(bg_path /etc/timezone)"
    sed -i "s/^# *\(${BGRPIIMAGE_LOCALE//./\\.} \)/\1/" "$(bg_path /etc/locale.gen)" || true
    locale-gen "$BGRPIIMAGE_LOCALE" || true
    update-locale "LANG=$BGRPIIMAGE_LOCALE" "LC_ALL=$BGRPIIMAGE_LOCALE"
    # Keyboard layout (non-fatal if the package is absent on minimal images)
    if [[ -f "$(bg_path /etc/default/keyboard)" ]]; then
        sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"$BGRPIIMAGE_KEYBOARD\"/" "$(bg_path /etc/default/keyboard)"
    fi
fi

# --- initramfs policy (chroot build) ---
# initramfs-tools >= 0.148.3+rpt2 refuses MODULES=dep unless /sys is
# mounted, because it probes sysfs to decide which modules to bundle.
# The qemu cross-build chroot has no /sys, so update-initramfs fails the
# moment an apt trigger regenerates the initrd. MODULES=most bundles a
# broad module set without probing sysfs - the standard choice for
# chroot-built Raspberry Pi images. Must run before any apt operation.
#
# Build-only by definition: a running device has /sys and wants the narrower
# module set it was installed with.
if bg_is_image && [[ -f "$(bg_path /etc/initramfs-tools/initramfs.conf)" ]]; then
    sed -i 's/^MODULES=.*/MODULES=most/' "$(bg_path /etc/initramfs-tools/initramfs.conf)"
fi

# --- apt packages ---
bg_apt_update
bg_apt_install_list "$GEN/packages.list"
if [[ -n "${BGRPIIMAGE_BASE_EXTRA_PACKAGES:-}" ]]; then
    # shellcheck disable=SC2086
    bg_apt_install $BGRPIIMAGE_BASE_EXTRA_PACKAGES
fi

# --- release metadata (sourced by MOTD and ops tooling) ---
#
# Image only. This file answers "which image is this device running", and
# that answer must stay true after any number of configuration updates:
# it is what tells an updater whether the base OS moved underneath. The
# applied configuration version is recorded separately, in
# /etc/bgrpiimage-applied, by bgrpiimage-update.
if [[ -f "$GEN/release.env" ]] && bg_is_image; then
    bg_install "$GEN/release.env" /etc/bgrpiimage-release 0644
    # The codename is appended here rather than rendered by generate.py because
    # only this side knows it: the generator runs on the build host, where
    # /etc/os-release describes the developer's machine, not the image. In the
    # chroot it is the target rootfs's own file. An updater compares it against
    # the bundle's to catch a base that moved from trixie to the next release -
    # a weaker check than BASE_IMAGE_SHA256, but the only one available on
    # devices flashed before that hash was recorded.
    # shellcheck disable=SC1090  # path is BGRPI_ROOT-relative by design
    _cn=$(. "$(bg_path /etc/os-release)" 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")
    printf 'BGRPIIMAGE_BASE_CODENAME=%s\n' "'${_cn}'" >> "$(bg_path /etc/bgrpiimage-release)"
    unset _cn
fi

# --- SSH service (raspios ships ssh.service disabled by default) ---
if [[ -f "$GEN/ssh.env" ]]; then
    # shellcheck disable=SC1090
    source "$GEN/ssh.env"
    bg_apt_install openssh-server
    if [[ "${BGRPIIMAGE_SSH_ENABLED:-yes}" == "yes" ]]; then
        bg_unit_enable ssh
        # Legacy raspios trigger: presence of /boot/firmware/ssh also enables.
        if bg_is_image && [[ -d "$(bg_path /boot/firmware)" ]]; then
            touch "$(bg_path /boot/firmware/ssh)"
        fi
    elif bg_is_image; then
        # Disabling sshd is refused on a live device: the current session
        # survives, so the command looks successful, and the box is simply
        # unreachable at the next connection attempt.
        bg_unit_disable ssh
    else
        bg_warn "config says ssh should be disabled; refusing to do that on a running system"
    fi
fi


# --- pre-login + post-login banner ---
if [[ -f "$GEN/motd-banner.sh" ]]; then
    bg_install "$GEN/issue"            /etc/issue                                        0644
    bg_install "$GEN/issue.net"        /etc/issue.net                                    0644
    bg_install "$GEN/sshd_banner.conf" /etc/ssh/sshd_config.d/20-bgrpiimage-banner.conf  0644
    if bg_changed; then bg_intent "reload ssh"; fi
    # Wipe raspios default motd scripts so the banner is consistent across runs.
    #
    # Image only: on a device this glob would also delete an MOTD script the
    # customer added, and /etc/update-motd.d is not ours to empty.
    if bg_is_image; then
        rm -f "$(bg_path /etc/update-motd.d)"/*
        : > "$(bg_path /etc/motd)"
    fi
    bg_install "$GEN/motd-banner.sh" /etc/update-motd.d/10-bgrpiimage 0755
fi

# --- Bluetooth ---
# Only bluetooth.service: hciuart.service no longer exists on trixie (the
# pi-bluetooth package is gone and the UART attach is handled by the device
# tree plus bluez), so enabling it would fail with "Unit does not exist".
# The rfkill soft block that would otherwise keep the radio down is lifted by
# bgrpiimage-network's /etc/modprobe.d/zz-bgrpiimage-rfkill.conf.
if [[ -f "$GEN/bluetooth.env" ]]; then
    # shellcheck disable=SC1090
    source "$GEN/bluetooth.env"
    if [[ "${BGRPIIMAGE_BLUETOOTH_ENABLED:-yes}" == "yes" ]]; then
        bg_unit_unmask bluetooth.service
        bg_unit_enable bluetooth.service
    else
        bg_unit_disable bluetooth.service
        bg_unit_mask bluetooth.service
    fi
fi

# --- cloud-init ---
# Raspberry Pi OS trixie ships cloud-init installed and enabled. This image
# provisions its own users, network and boot config, so cloud-init is pure boot
# time plus risk: the trixie build runs first-boot-only modules on EVERY boot
# (raspberrypi/trixie-feedback#26) and can rewrite hostname, users and network
# behind systemd-networkd's back. Its units are Type=oneshot, i.e. unbounded.
#
# Deliberately NOT purging cloud-initramfs-growroot - rootfs expansion on this
# image comes from the `resize` entry pi-gen puts on the kernel cmdline, and
# removing the wrong package leaves the filesystem at its build size.
#
# Build-only: purging a package on a deployed device is an OS change, and this
# one has already happened there anyway.
if bg_is_image; then
    apt-get purge -y cloud-init 2>/dev/null || true
    rm -rf "$(bg_path /etc/cloud)" "$(bg_path /var/lib/cloud)"
    apt-get clean
fi
