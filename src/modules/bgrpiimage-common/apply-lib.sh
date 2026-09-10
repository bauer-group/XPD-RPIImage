# shellcheck shell=bash
# bgrpiimage apply-lib - the only thing in this project that writes to a
# configured system. Sourced by every module's apply.sh; never executed.
#
# WHY THIS EXISTS
#
# Until now the logic that turns generated payload into a configured system
# lived in src/modules/*/start_chroot_script, which only the image build can
# reach: those scripts call CustomPiOS helpers (`unpack`, `install_cleanup_trap`)
# and assume a blank rootfs in a chroot where nothing is running, nothing
# belongs to an operator, and there is no session to lose. That assumption is
# in their idioms, not in a line you can patch.
#
# So the logic moves into per-module apply.sh files that source this library,
# and the chroot script becomes a six-line adapter. The same apply.sh then
# serves two callers: the image build (BGRPI_CTX=image) and, once the updater
# lands, a running device (BGRPI_CTX=device).
#
# THE CONTRACT
#
#   BGRPI_CTX      image | device   Unset means device. That default is
#                                   deliberate: the dangerous direction is
#                                   running a build-only step (apt, purge
#                                   cloud-init, deluser) on live hardware, so
#                                   the fail-safe is to assume we are live.
#   BGRPI_ROOT     path prefix      Default "". Every write goes through
#                                   bg_path, so pointing this at a scratch
#                                   directory runs the REAL apply scripts
#                                   unprivileged against a throwaway tree.
#                                   This is the project's only affordance for
#                                   testing apply logic without building an
#                                   image.
#   BGRPI_DRY_RUN  0 | 1            Compute and report, never write.
#   BGRPI_INTENTS  path             Where activation intents are appended.
#
# PRECONDITION  the module's payload directory is current.
# POSTCONDITION the system matches that payload, and everything that must be
#               reloaded, restarted or rebooted for it to take effect has been
#               appended to BGRPI_INTENTS.
#
# MODULES QUEUE INTENTS; THEY NEVER ACT
#
# A module knows it wrote 40-can0.network. It does not know whether eleven
# other files changed in the same transaction, whether the operator's session
# runs over the interface it is about to bounce, or whether a reboot is
# already pending. Only the caller knows that, so activation is the caller's
# decision. bg_install emits intents automatically from OBSERVED change, which
# is also why re-applying an unchanged system is silent rather than noisy.

set -euo pipefail

BGRPI_CTX="${BGRPI_CTX:-device}"
BGRPI_ROOT="${BGRPI_ROOT:-}"
BGRPI_DRY_RUN="${BGRPI_DRY_RUN:-0}"
BGRPI_INTENTS="${BGRPI_INTENTS:-${BGRPI_ROOT}/run/bgrpiimage-intents}"

# Set by bg_install/bg_write to whether the last call actually changed
# anything, so a module can make a follow-up action conditional on real change
# rather than on having been run.
BGRPI_LAST_CHANGED=0

# Same question across a whole module. Needed because the interesting intents
# are usually module-wide - one daemon-reload covers six unit files - and
# emitting them unconditionally means a device restarts timers on every update
# that changed nothing, which is exactly the noise the content comparison
# exists to avoid.
BGRPI_CHANGE_COUNT=0

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _BG_C=$'\033[1;36m'; _BG_G=$'\033[1;32m'; _BG_Y=$'\033[1;33m'
    _BG_R=$'\033[1;31m'; _BG_N=$'\033[0m'
else
    _BG_C=''; _BG_G=''; _BG_Y=''; _BG_R=''; _BG_N=''
fi

bg_log()  { echo "${_BG_C}[*]${_BG_N} $*"; }
bg_ok()   { echo "${_BG_G}[+]${_BG_N} $*"; }
bg_warn() { echo "${_BG_Y}[!]${_BG_N} $*" >&2; }
bg_die()  { echo "${_BG_R}[x]${_BG_N} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------
bg_is_image()  { [[ "$BGRPI_CTX" == "image" ]]; }
bg_is_device() { [[ "$BGRPI_CTX" != "image" ]]; }
bg_dry()       { [[ "$BGRPI_DRY_RUN" == "1" ]]; }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# Every destination in every module goes through this. Two consequences worth
# stating: --dry-run cannot lie (the only way to touch the filesystem is a
# function that honours it), and BGRPI_ROOT makes the real scripts testable.
bg_path() {
    local p="$1"
    [[ "$p" == /* ]] || bg_die "bg_path needs an absolute path, got '$p'"
    printf '%s%s' "$BGRPI_ROOT" "$p"
}

# ---------------------------------------------------------------------------
# Intents
# ---------------------------------------------------------------------------
# One line per intent, deduplicated by the caller. Free-form on purpose: the
# vocabulary is still settling, and a module that needs a new kind of
# activation should not have to change this library to say so.
bg_intent() {
    local line="$*"
    [[ -n "$line" ]] || return 0
    mkdir -p "$(dirname "$BGRPI_INTENTS")" 2>/dev/null || true
    if [[ -f "$BGRPI_INTENTS" ]] && grep -qxF "$line" "$BGRPI_INTENTS" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$line" >> "$BGRPI_INTENTS"
}

# ---------------------------------------------------------------------------
# What an update may never write
# ---------------------------------------------------------------------------
# Enforced here, in the one function that writes, rather than trusted to each
# module. A denylist nine scripts are supposed to respect is a code-review
# convention and will be violated within two releases; a denylist the writer
# enforces is a property of the system.
#
# DEVICE CONTEXT ONLY. Several of these are written legitimately at image
# build time - /etc/hostname and /etc/hosts are exactly what bgrpiimage-base
# is for. The list is about what an UPDATE to a configured, deployed machine
# may touch, and the answer for all of it is "not this".
#
# Three kinds of entry:
#   identity and access    shadow/passwd/sudoers/pam - the only two ways onto
#                          these boxes are sudo and su, and they are each
#                          other's only fallback. An update that breaks both
#                          is a truck roll with an rpiboot jumper.
#   operator-owned state   the 05- overrides this project's own helper writes,
#                          wpa_supplicant PSKs, rfkill saved state, static
#                          resolv.conf, hostname - site data, not platform.
#   boot and storage       cmdline.txt and fstab, where one typo is an
#                          unbootable device rather than a failed service.
BGRPI_DENY_GLOBS=(
    '/etc/shadow' '/etc/passwd' '/etc/group' '/etc/gshadow'
    '/etc/subuid' '/etc/subgid'
    '/etc/sudoers' '/etc/sudoers.d/*'
    '/etc/pam.d/*'
    '/etc/ssh/ssh_host_*'
    '/home/*' '/root/*'
    '/etc/hostname' '/etc/hosts'
    '/etc/resolv.conf'
    '/etc/wpa_supplicant/*'
    '/var/lib/systemd/rfkill/*'
    '/etc/systemd/network/05-bgrpiimage-*'
    '/etc/docker/daemon.json'
    '/boot/firmware/cmdline.txt'
    '/etc/fstab' '/etc/crypttab'
    '/etc/apt/sources.list' '/etc/apt/sources.list.d/*' '/etc/apt/keyrings/*'
    '/etc/machine-id'
    # Describes the FLASHED image and must keep doing so: it is the input
    # to the base-image check that decides whether the next update is a
    # config change or a reflash. An updater that stamps its own success
    # here destroys the basis of its own next safety check. The applied
    # configuration version lives in /etc/bgrpiimage-applied instead.
    '/etc/bgrpiimage-release'
)

bg_denied() {
    local dest="$1" g
    bg_is_image && return 1
    for g in "${BGRPI_DENY_GLOBS[@]}"; do
        # shellcheck disable=SC2053  # glob match on the right is the point
        [[ "$dest" == $g ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------
_bg_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Content-addressed: identical source and destination means no write, no
# intent, no log line. This is what makes "re-apply everything, every time"
# cheap and quiet, and it is what lets activation decisions be derived from
# observed change instead of declared per release.
bg_install() {
    local src="$1" dest="$2" mode="${3:-0644}" target
    target="$(bg_path "$dest")"
    BGRPI_LAST_CHANGED=0

    [[ -r "$src" ]] || bg_die "bg_install: source not readable: $src"
    if bg_denied "$dest"; then
        bg_die "refusing to write $dest on a running system - see BGRPI_DENY_GLOBS"
    fi

    if [[ -f "$target" ]] && [[ "$(_bg_sha "$src")" == "$(_bg_sha "$target")" ]]; then
        # Content matches; still assert the mode, because a wrong mode is a
        # real defect (see the cleartext-credential fix in v0.7.8) and fixing
        # it is not a content change.
        bg_dry || chmod "$mode" "$target" 2>/dev/null || true
        return 0
    fi

    BGRPI_LAST_CHANGED=1
    BGRPI_CHANGE_COUNT=$((BGRPI_CHANGE_COUNT + 1))
    if bg_dry; then
        bg_log "would write $dest"
        return 0
    fi
    install -D -m "$mode" "$src" "$target"
    bg_log "wrote $dest"
}

# Same semantics for a heredoc body rather than a file.
bg_write() {
    local dest="$1" mode="${2:-0644}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    bg_install "$tmp" "$dest" "$mode"
    rm -f "$tmp"
}

# Mirror a payload directory into a destination directory, file by file, so
# each file gets the content comparison above rather than an unconditional
# `cp -a` that rewrites mtimes and tells us nothing about what changed.
bg_install_tree() {
    local srcdir="$1" destdir="$2" mode="${3:-0644}" f rel changed=0
    [[ -d "$srcdir" ]] || return 0
    while IFS= read -r -d '' f; do
        rel="${f#"$srcdir"/}"
        bg_install "$f" "${destdir%/}/$rel" "$mode"
        [[ "$BGRPI_LAST_CHANGED" == "1" ]] && changed=1
    done < <(find "$srcdir" -type f -print0)
    BGRPI_LAST_CHANGED="$changed"
}

bg_changed() { [[ "$BGRPI_LAST_CHANGED" == "1" ]]; }
bg_any_changed() { (( BGRPI_CHANGE_COUNT > 0 )); }

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------
# systemctl in a chroot works on the filesystem (enable/disable manipulate
# symlinks) but cannot talk to a running manager. On a device it does both.
# Neither caller wants a failure here to abort the whole module, which is why
# the original chroot scripts all wrote `2>/dev/null || true` - kept, but in
# one place instead of nine.
# All three take a list, because systemctl does: one invocation is one
# transaction against the manager, and grouping keeps the command identical to
# the one the pre-refactor scripts issued.
bg_unit_enable() {
    (( $# )) || return 0
    bg_dry && { bg_log "would enable $*"; return 0; }
    systemctl enable "$@" >/dev/null 2>&1 && return 0
    # Deliberately asymmetric. A build must fail loudly: an image whose units
    # are not enabled boots into the wrong state, and nobody finds that out
    # until the hardware is in a cabinet. A device must not have an entire
    # update aborted because one unit would not enable - it reports and lets
    # the caller decide, which is the same reasoning as the intent model.
    if bg_is_image; then
        bg_die "could not enable $*"
    fi
    bg_warn "could not enable $*"
}

bg_unit_disable() {
    (( $# )) || return 0
    bg_dry && { bg_log "would disable $*"; return 0; }
    systemctl disable "$@" >/dev/null 2>&1 || true
}

# mask/unmask are deliberately image-only. Masking a unit on a running device
# is an operator decision about that device - an update that masks
# NetworkManager on a box where someone un-masked it for an LTE backhaul takes
# the WAN away, and does so at the NEXT boot, which is the worst possible time
# to discover it.
bg_unit_mask() {
    (( $# )) || return 0
    if bg_is_device; then
        bg_warn "refusing to mask $* on a running system"
        return 0
    fi
    bg_dry && { bg_log "would mask $*"; return 0; }
    systemctl mask "$@" >/dev/null 2>&1 || true
}

bg_unit_unmask() {
    (( $# )) || return 0
    if bg_is_device; then
        bg_warn "refusing to unmask $* on a running system"
        return 0
    fi
    bg_dry && { bg_log "would unmask $*"; return 0; }
    systemctl unmask "$@" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
# Image: install. Device: report and refuse.
#
# The moment an update installs packages it owns an OS updater, and this image
# already has one - unattended-upgrades, with a maintenance window and a
# reboot policy that a config update must not duplicate or pre-empt. Worse,
# apt can pull a kernel and set /var/run/reboot-required behind the operator's
# back, which then trips bgrpiimage-reboot-window.sh and reboots a CAN gateway
# nobody asked to reboot.
bg_apt_install() {
    (( $# )) || return 0
    if bg_is_device; then
        local missing=()
        local p
        # Both the real package names and everything they Provide, gathered in
        # one dpkg-query rather than one per package.
        #
        # `dpkg-query -W <name>` alone does NOT resolve virtual packages, and
        # Debian renames things: on trixie `dnsutils` is provided by
        # `bind9-dnsutils` and is never installed under the queried name. The
        # old check therefore reported a package as missing on a device where
        # `apt install dnsutils` answers "already the newest version" - which
        # reads as the release wanting something the operator cannot supply,
        # and sends them looking for a problem that does not exist.
        local installed
        installed=$(dpkg-query -W -f='${Status}\t${Package}\t${Provides}\n' 2>/dev/null \
            | awk -F'\t' '$1 == "install ok installed" {
                    print $2
                    if ($3 != "") {
                        gsub(/ *\([^)]*\)/, "", $3)   # drop "(= 1.2)" version qualifiers
                        n = split($3, a, / *, */)
                        for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
                    }
                }')
        for p in "$@"; do
            grep -qxF "$p" <<<"$installed" || missing+=("$p")
        done
        if (( ${#missing[@]} )); then
            bg_warn "this release expects packages that are not installed: ${missing[*]}"
            bg_warn "install them yourself or reflash - an update will not run apt"
        fi
        return 0
    fi
    bg_dry && { bg_log "would apt-get install $*"; return 0; }
    apt-get install -y --no-install-recommends "$@"
}

bg_apt_install_list() {
    local list="$1"
    [[ -f "$list" ]] || return 0
    local pkgs=()
    mapfile -t pkgs < <(grep -vE '^\s*(#|$)' "$list")
    (( ${#pkgs[@]} )) && bg_apt_install "${pkgs[@]}"
    return 0
}

bg_apt_update() {
    bg_is_device && return 0
    bg_dry && { bg_log "would apt-get update"; return 0; }
    apt-get update
}
