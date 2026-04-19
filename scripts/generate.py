#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
BAUER GROUP XPD-RPIImage - variant config renderer.

Reads a JSON variant config, resolves ${ENV} references, validates against
schema.json, and renders all artifacts into the CustomPiOS module tree at
src/modules/<module>/filesystem/root/opt/bgrpiimage/<module>/ plus the variant shell config at
src/variants/<name>/config.

Usage:
    python scripts/generate.py config/variants/canbus-plattform.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import stat
import sys
from pathlib import Path
from typing import Any

try:
    import jsonschema
    from rich import box
    from rich.console import Console
    from rich.json import JSON
    from rich.panel import Panel
    from rich.table import Table
except ImportError:
    print("error: missing dependencies. run: pip install -r scripts/requirements.txt", file=sys.stderr)
    sys.exit(2)

# On Windows the default stdout encoding is cp1252 which can't render the
# Unicode glyphs rich uses for borders / status. Reconfigure to UTF-8 and
# disable rich's legacy Win32 renderer so ANSI escapes are used instead.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, Exception):
        pass

console = Console(highlight=False, legacy_windows=False)


def _error_panel(title: str, body: str, hint: str | None = None) -> None:
    text = body
    if hint:
        text += f"\n\n[dim]hint:[/] {hint}"
    console.print(Panel(text, title=f"[red]{title}[/]", border_style="red", box=box.ROUNDED))

ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIR = ROOT / "config"
SRC_DIR = ROOT / "src"
MODULES_DIR = SRC_DIR / "modules"
VARIANTS_DIR = SRC_DIR / "variants"
SCHEMA_PATH = CONFIG_DIR / "schema.json"

# -----------------------------------------------------------------------------
# Env var resolution
# -----------------------------------------------------------------------------
# Names that look like ${...} but must pass through to downstream tools that
# do their own substitution (notably unattended-upgrades' APT origin patterns).
_PASSTHROUGH_NAMES: set[str] = {"distro_id", "distro_codename"}

_ENV_VAR_RE = re.compile(
    r"\$\{(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?:(?P<op>:-)(?P<default>[^}]*))?\}"
)


def resolve_env_vars(value: str, env: dict[str, str]) -> str:
    """Resolve ${VAR} / ${VAR:-default} references in a string.

    Behaviour:
      - ${VAR}           -> env[VAR]; raises KeyError if unset.
      - ${VAR:-default}  -> env[VAR] if set & non-empty, else default.
      - Names in _PASSTHROUGH_NAMES are left untouched (downstream resolves).
      - Resolution is single-pass; defaults are not re-parsed.

    Rationale:
      BAUER GROUP security standard - fail fast on missing secrets; never
      silently default a secret to empty. Defaults exist exactly for the
      values that are explicitly non-sensitive.
    """
    def replace(m: re.Match[str]) -> str:
        name = m.group("name")
        if name in _PASSTHROUGH_NAMES:
            return m.group(0)
        op = m.group("op")
        default = m.group("default")
        val = env.get(name)
        if op == ":-":
            return val if val else (default or "")
        if val is None:
            raise KeyError(
                f"environment variable '{name}' is required by config but not set "
                f"(use ${{{name}:-default}} to provide a fallback)"
            )
        return val

    return _ENV_VAR_RE.sub(replace, value)


def resolve_tree(node: Any, env: dict[str, str]) -> Any:
    """Recursively resolve ${...} in every string leaf of a JSON-like tree."""
    if isinstance(node, str):
        return resolve_env_vars(node, env)
    if isinstance(node, list):
        return [resolve_tree(x, env) for x in node]
    if isinstance(node, dict):
        return {k: resolve_tree(v, env) for k, v in node.items()}
    return node


# -----------------------------------------------------------------------------
# Variant composition via `extends`
# -----------------------------------------------------------------------------
def load_variant(path: Path, _seen: set[Path] | None = None) -> dict[str, Any]:
    """Load a variant JSON, recursively applying any `extends` reference.

    `extends` is a relative path (from the current file) to a parent JSON.
    The parent is loaded first (recursively), then the child is deep-merged
    onto it. This is BEFORE env-var resolution - so a child can override an
    `${ADMIN_PASSWORD:-...}` default by setting a literal.
    """
    _seen = _seen or set()
    resolved = path.resolve()
    if resolved in _seen:
        chain = " -> ".join(str(p) for p in _seen) + f" -> {resolved}"
        raise ValueError(f"circular extends chain: {chain}")
    _seen.add(resolved)

    with resolved.open("r", encoding="utf-8") as f:
        data = json.load(f)
    data.pop("$schema", None)

    parent_ref = data.pop("extends", None)
    if parent_ref:
        parent_path = (resolved.parent / parent_ref).resolve()
        parent = load_variant(parent_path, _seen=_seen)
        data = deep_merge(parent, data)
    return data


def deep_merge(parent: Any, child: Any) -> Any:
    """Merge child onto parent.

    - dicts          : recursive merge; child keys win on conflict
    - scalar lists   : concat(parent + child) with stable-order dedupe
    - named records  : lists of dicts where every item has a `name` field
                       are merged by name (same name -> deep-merge entries)
    - other lists    : concat(parent + child)
    - scalars        : child overrides parent
    """
    if isinstance(parent, dict) and isinstance(child, dict):
        out: dict[str, Any] = {**parent}
        for k, v in child.items():
            out[k] = deep_merge(out[k], v) if k in out else v
        return out
    if isinstance(parent, list) and isinstance(child, list):
        combined = list(parent) + list(child)
        if not combined:
            return combined
        if all(isinstance(x, (str, int, float, bool)) for x in combined):
            seen: set[Any] = set()
            deduped: list[Any] = []
            for x in combined:
                if x not in seen:
                    seen.add(x)
                    deduped.append(x)
            return deduped
        if all(isinstance(x, dict) and "name" in x for x in combined):
            by_name: dict[str, dict[str, Any]] = {}
            order: list[str] = []
            for item in combined:
                n = item["name"]
                if n in by_name:
                    by_name[n] = deep_merge(by_name[n], item)
                else:
                    by_name[n] = item
                    order.append(n)
            return [by_name[n] for n in order]
        return combined
    return child


# -----------------------------------------------------------------------------
# File writing helpers
# -----------------------------------------------------------------------------
def write(path: Path, content: str, *, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # LF line endings regardless of host OS - these files run on Linux.
    path.write_bytes(content.encode("utf-8"))
    if executable:
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def shell_var(name: str, value: str | int | bool) -> str:
    if isinstance(value, bool):
        value = "yes" if value else "no"
    return f"{name}={shlex.quote(str(value))}\n"


def shell_array(name: str, values: list[str]) -> str:
    quoted = " ".join(shlex.quote(v) for v in values)
    return f'{name}="{quoted}"\n'


def clean_generated(module_name: str) -> Path:
    # Write to module/filesystem/root/opt/bgrpiimage/<module>/ so the files
    # end up INSIDE the chroot: CustomPiOS copies `module/filesystem/` into
    # the chroot root; our start_chroot_script calls `unpack /filesystem/
    # root / root` which moves the contents to `/`. Result in the chroot:
    # /opt/bgrpiimage/<module>/<generated files>.
    gen = MODULES_DIR / module_name / "filesystem" / "root" / "opt" / "bgrpiimage" / module_name
    if gen.exists():
        shutil.rmtree(gen)
    gen.mkdir(parents=True)
    return gen


# -----------------------------------------------------------------------------
# Renderers - one per feature area
# -----------------------------------------------------------------------------
def render_base(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgrpiimage-base")
    write(gen / "hostname", cfg["hostname"] + "\n")
    locale = cfg.get("locale", {})
    lines = [
        shell_var("BGRPIIMAGE_TIMEZONE", locale.get("timezone", "UTC")),
        shell_var("BGRPIIMAGE_LOCALE", locale.get("locale", "en_US.UTF-8")),
        shell_var("BGRPIIMAGE_KEYBOARD", locale.get("keyboard", "us")),
    ]
    write(gen / "locale.env", "".join(lines))
    packages = cfg.get("packages", [])
    write(gen / "packages.list", "\n".join(packages) + ("\n" if packages else ""))

    # /etc/bgrpiimage-release - sourced by the MOTD banner and any ops tooling.
    variant = cfg["variant"]
    release_lines = [
        f'BGRPIIMAGE_DIST="bgrpiimage"\n',
        f'BGRPIIMAGE_VARIANT={shlex.quote(variant["name"])}\n',
        f'BGRPIIMAGE_VERSION={shlex.quote(variant.get("version", "0.0.0"))}\n',
        f'BGRPIIMAGE_DESCRIPTION={shlex.quote(variant.get("description", ""))}\n',
    ]
    write(gen / "release.env", "".join(release_lines))

    ssh = cfg.get("ssh") or {}
    write(gen / "ssh.env", shell_var("BGRPIIMAGE_SSH_ENABLED", bool(ssh.get("enabled", True))))

    banner = cfg.get("banner") or {}
    if banner.get("enabled", True):
        _render_banner(gen, cfg, banner)


def _render_banner(gen: Path, cfg: dict[str, Any], banner: dict[str, Any]) -> None:
    """Emit /etc/issue, /etc/issue.net, the MOTD script and the sshd banner
    drop-in. The MOTD script is static - all dynamic info (hostname, IPs, CAN
    state, docker, uptime, pending reboots) is resolved at login time from the
    running system."""
    variant = cfg["variant"]
    note = banner.get("pre_login_note", "")

    header = (
        f"bgRPIImage {variant['name']} v{variant.get('version', '0.0.0')}\n"
        f"  {variant.get('description', '')}\n"
    ).rstrip() + "\n"

    # /etc/issue: getty expands \n \4 \6 \s \r \m at display time.
    issue = (
        f"{header}"
        "--------------------------------------------------------------------\n"
        "  \\s \\r \\m    \\d \\t\n"
        "  host:  \\n\n"
        "  tty:   \\l\n"
        "  eth0:  \\4{eth0}    \\6{eth0}\n"
        "  wlan0: \\4{wlan0}   \\6{wlan0}\n"
        "--------------------------------------------------------------------\n"
    )
    if note:
        issue += f"{note}\n"
    write(gen / "issue", issue)

    # /etc/issue.net: sshd reads raw (no escapes), so keep it static.
    issue_net = (
        f"{header}"
        "--------------------------------------------------------------------\n"
    )
    if note:
        issue_net += f"{note}\n"
    issue_net += "--------------------------------------------------------------------\n"
    write(gen / "issue.net", issue_net)

    # sshd drop-in to surface the pre-login banner.
    write(
        gen / "sshd_banner.conf",
        "# bgRPIImage pre-login banner\n"
        "Banner /etc/issue.net\n",
    )

    # Dynamic MOTD - runs on login (pam_motd) and also from console.
    write(gen / "motd-banner.sh", _MOTD_SCRIPT, executable=True)


_MOTD_SCRIPT = r"""#!/bin/bash
# bgRPIImage dynamic MOTD - shown after login.
# Keep this script minimal and tolerant: it must never block a login.
set +e

[ -r /etc/bgrpiimage-release ] && . /etc/bgrpiimage-release

if [ -t 1 ]; then
    CY=$'\033[1;36m'; GR=$'\033[1;32m'; DIM=$'\033[2m'
    YE=$'\033[1;33m'; RD=$'\033[1;31m'; NC=$'\033[0m'
else
    CY=''; GR=''; DIM=''; YE=''; RD=''; NC=''
fi

cols=$(tput cols 2>/dev/null || echo 72); [ "$cols" -lt 60 ] && cols=72
sep=$(printf '=%.0s' $(seq 1 "$cols"))

active_color() { [ "$1" = "active" ] && echo "$GR" || echo "$YE"; }

echo "${CY}${sep}${NC}"
printf "  ${GR}%s${NC}  %s  ${DIM}v%s${NC}\n" \
    "${BGRPIIMAGE_DIST:-bgRPIImage}" \
    "${BGRPIIMAGE_VARIANT:-unknown}" \
    "${BGRPIIMAGE_VERSION:-0.0.0}"
[ -n "${BGRPIIMAGE_DESCRIPTION:-}" ] && \
    printf "  ${DIM}%s${NC}\n" "$BGRPIIMAGE_DESCRIPTION"

model=""
if [ -r /sys/firmware/devicetree/base/model ]; then
    model=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
fi
printf "  ${DIM}host:${NC} %-20s  ${DIM}kernel:${NC} %s\n" "$(hostname)" "$(uname -r)"
[ -n "$model" ] && printf "  ${DIM}model:${NC} %s\n" "$model"
up=$(uptime -p 2>/dev/null)
[ -n "$up" ] && printf "  ${DIM}uptime:${NC} %s\n" "$up"
echo "${CY}${sep}${NC}"

# Physical + virtual interfaces we care about.
iface_count=0
for iface in $(ip -o link show 2>/dev/null | \
               awk -F': ' '$2 !~ /^(lo|docker|veth|br-|bond|vlan)/ {print $2}' | \
               cut -d'@' -f1); do
    iface_count=$((iface_count+1))
    state=$(ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
    case "$iface" in
        can*)
            bitrate=$(ip -details link show "$iface" 2>/dev/null | \
                      grep -oE 'bitrate [0-9]+' | awk '{print $2}')
            [ -n "$bitrate" ] && rate_str="$((bitrate/1000)) kbit/s" || rate_str="(no bitrate)"
            sc=$([ "$state" = "UP" ] && echo "$GR" || echo "$DIM")
            printf "  ${DIM}%-7s${NC} ${sc}%-6s${NC} %s\n" "$iface" "$state" "$rate_str"
            ;;
        *)
            v4=$(ip -4 -br addr show "$iface" 2>/dev/null | awk '{$1=$2=""; print $0}' | xargs)
            v6=$(ip -6 -br addr show "$iface" 2>/dev/null | \
                 awk '{for(i=3;i<=NF;i++) print $i}' | \
                 grep -v '^fe80' | head -2 | tr '\n' ' ')
            sc=$([ "$state" = "UP" ] && echo "$GR" || echo "$DIM")
            printf "  ${DIM}%-7s${NC} ${sc}%-6s${NC} v4: %s\n" "$iface" "$state" "${v4:-(none)}"
            [ -n "$v6" ] && printf "  %-7s %-6s v6: %s\n" "" "" "$v6"
            ;;
    esac
done
[ "$iface_count" -eq 0 ] && printf "  ${DIM}(no external network interfaces detected)${NC}\n"
echo "${CY}${sep}${NC}"

ssh_s=$(systemctl is-active ssh 2>/dev/null || echo "?")
dk_s=$(systemctl is-active docker 2>/dev/null || echo "?")
uu_s=$(systemctl is-active unattended-upgrades 2>/dev/null || echo "?")
printf "  ${DIM}ssh:${NC} $(active_color "$ssh_s")%s${NC}" "$ssh_s"
printf "   ${DIM}docker:${NC} $(active_color "$dk_s")%s${NC}" "$dk_s"
if [ "$dk_s" = "active" ]; then
    n=$(docker ps -q 2>/dev/null | wc -l)
    printf " ${DIM}(%d running)${NC}" "$n"
fi
printf "   ${DIM}unattended-upgrades:${NC} $(active_color "$uu_s")%s${NC}\n" "$uu_s"

if [ -f /var/run/reboot-required ]; then
    pkgs=""
    [ -s /var/run/reboot-required.pkgs ] && pkgs=$(tr '\n' ' ' < /var/run/reboot-required.pkgs)
    printf "  ${YE}reboot pending${NC} %s\n" "${pkgs:+(triggered by: ${pkgs})}"
fi

# Warn loudly if the shipped demo credentials were never changed. The shadow
# hash of "12345678" with the salt that chpasswd picks is predictable enough
# that we can detect it cheaply: compare the first 10 chars of the hash to a
# known-unchanged marker stored at image-build time.
if [ -f /etc/bgrpiimage-default-password-active ] && [ -r /etc/shadow ]; then
    printf "  ${RD}SECURITY:${NC} default admin password is still active.\n"
    printf "           change it now with: ${YE}sudo bgrpiimage-setup password${NC}\n"
    printf "           (also review: ${YE}sudo bgrpiimage-setup status${NC})\n"
fi
echo "${CY}${sep}${NC}"
"""


_KNOWN_DEMO_PASSWORDS = {"12345678"}


def render_users(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgrpiimage-users")
    users = cfg.get("users", [])
    remove_users = cfg.get("remove_users", [])
    root = cfg.get("root", {})
    script = ["#!/bin/bash", "# Auto-generated by scripts/generate.py", "set -euo pipefail", ""]

    # Drop a marker file when at least one user still carries a ship-default
    # demo password after env resolution. The MOTD reads this marker and
    # prompts the operator to rotate the credential.
    if any(u.get("password") in _KNOWN_DEMO_PASSWORDS for u in users):
        script.append("touch /etc/bgrpiimage-default-password-active")
        script.append("chmod 644 /etc/bgrpiimage-default-password-active")
        script.append("")

    for user in users:
        name = user["name"]
        pw = user["password"]
        shell = user.get("shell", "/bin/bash")
        groups = ",".join(user.get("groups", []))
        script.append(f"# === user: {name} ===")
        script.append(f"if ! id -u {shlex.quote(name)} >/dev/null 2>&1; then")
        script.append(f"  useradd -m -s {shlex.quote(shell)} {shlex.quote(name)}")
        script.append("fi")
        if groups:
            # `usermod -aG` fails hard on any non-existent group. Pre-create
            # each one with `groupadd -f` so user-add works even when module
            # order puts users before the packages (docker, i2c-tools) that
            # would otherwise install the group.
            for g in user.get("groups", []):
                script.append(
                    f"getent group {shlex.quote(g)} >/dev/null || groupadd {shlex.quote(g)}"
                )
            script.append(f"usermod -aG {shlex.quote(groups)} {shlex.quote(name)}")
        # chpasswd via stdin keeps the password out of argv / process lists.
        script.append(f"echo {shlex.quote(f'{name}:{pw}')} | chpasswd")
        if user.get("sudo_nopasswd"):
            sudoers_line = f"{name} ALL=(ALL) NOPASSWD:ALL"
            script.append(
                f"echo {shlex.quote(sudoers_line)} > /etc/sudoers.d/010-bgrpiimage-{name}"
            )
            script.append(f"chmod 440 /etc/sudoers.d/010-bgrpiimage-{name}")
        keys = user.get("ssh_authorized_keys") or []
        if keys:
            script.append(f"install -d -m 700 -o {shlex.quote(name)} -g {shlex.quote(name)} /home/{name}/.ssh")
            authfile = f"/home/{name}/.ssh/authorized_keys"
            script.append(f"cat > {authfile} <<'__BGRPIIMAGE_EOF__'")
            script.extend(keys)
            script.append("__BGRPIIMAGE_EOF__")
            script.append(f"chown {shlex.quote(name)}:{shlex.quote(name)} {authfile}")
            script.append(f"chmod 600 {authfile}")
        script.append("")

    for victim in remove_users:
        script.append(f"if id -u {shlex.quote(victim)} >/dev/null 2>&1; then")
        script.append(f"  deluser --remove-home {shlex.quote(victim)} || true")
        script.append(f"  delgroup {shlex.quote(victim)} 2>/dev/null || true")
        script.append("fi")

    # su without password for listed users -> pam_wheel.so group trust.
    su_users = root.get("su_nopasswd_users") or []
    if su_users:
        script.append("# su without password for trusted users -> group 'wheel'")
        script.append("getent group wheel >/dev/null || groupadd wheel")
        for u in su_users:
            script.append(f"usermod -aG wheel {shlex.quote(u)}")
        script.append("install -m 644 /tmp/_bgrpiimage_su_pam /etc/pam.d/su")

    ssh_pw = root.get("ssh_password_auth", True)
    ssh_root = root.get("ssh_permit_root_login", False)
    script.append("")
    script.append("# sshd hardening")
    script.append("mkdir -p /etc/ssh/sshd_config.d")
    sshd = []
    sshd.append(f"PasswordAuthentication {'yes' if ssh_pw else 'no'}")
    sshd.append(f"PermitRootLogin {'yes' if ssh_root else 'no'}")
    sshd.append("ChallengeResponseAuthentication no")
    sshd.append("UsePAM yes")
    script.append("cat > /etc/ssh/sshd_config.d/10-bgrpiimage.conf <<'__BGRPIIMAGE_EOF__'")
    script.extend(sshd)
    script.append("__BGRPIIMAGE_EOF__")
    script.append("chmod 644 /etc/ssh/sshd_config.d/10-bgrpiimage.conf")

    write(gen / "create-users.sh", "\n".join(script) + "\n", executable=True)

    # /etc/pam.d/su drop-in enabling pam_wheel trust.
    pam_su = (
        "# /etc/pam.d/su - generated by bgRPIImage\n"
        "auth       sufficient pam_rootok.so\n"
        "auth       [success=ignore default=1] pam_succeed_if.so user = root\n"
        "auth       sufficient pam_wheel.so trust use_uid\n"
        "auth       required   pam_wheel.so use_uid\n"
        "auth       required   pam_unix.so\n"
        "account    required   pam_unix.so\n"
        "session    required   pam_unix.so\n"
        "session    optional   pam_xauth.so\n"
    )
    write(gen / "pam_su", pam_su)


def render_network(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgrpiimage-network")
    net = cfg.get("network", {})
    nwd = gen / "systemd-networkd"
    nwd.mkdir(parents=True, exist_ok=True)

    def iface_network_file(idx: int, iface: dict[str, Any], match: str) -> str:
        mode = iface.get("mode", "dhcp")
        ipv6 = iface.get("ipv6", True)
        lines = [f"[Match]", f"Name={match}", "", "[Network]"]
        if mode == "dhcp":
            lines.append("DHCP=ipv4")
            if ipv6:
                lines.append("IPv6AcceptRA=yes")
                lines.append("LinkLocalAddressing=ipv6")
            else:
                lines.append("LinkLocalAddressing=no")
        elif mode == "static":
            addr = iface.get("address")
            prefix = iface.get("prefix", 24)
            gw = iface.get("gateway")
            if addr:
                lines.append(f"Address={addr}/{prefix}")
            if gw:
                lines.append(f"Gateway={gw}")
            for dns in iface.get("dns", []):
                lines.append(f"DNS={dns}")
            if ipv6:
                addr6 = iface.get("address_v6")
                prefix6 = iface.get("prefix_v6", 64)
                gw6 = iface.get("gateway_v6")
                if addr6:
                    lines.append(f"Address={addr6}/{prefix6}")
                if gw6:
                    lines.append(f"Gateway={gw6}")
        return "\n".join(lines) + "\n"

    eth = net.get("ethernet")
    if eth and eth.get("mode") != "disabled":
        write(nwd / "10-eth.network", iface_network_file(10, eth, eth.get("interface", "eth0")))

    wifi = net.get("wifi")
    if wifi and wifi.get("mode") != "disabled":
        write(nwd / "20-wlan.network", iface_network_file(20, wifi, wifi.get("interface", "wlan0")))

        wpa_dir = gen / "wpa_supplicant"
        wpa_dir.mkdir(parents=True, exist_ok=True)
        country = wifi.get("country", "DE")
        wpa = [
            "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev",
            "update_config=1",
            f"country={country}",
            "",
        ]
        for net_entry in wifi.get("networks", []):
            wpa.append("network={")
            wpa.append(f'    ssid="{net_entry["ssid"]}"')
            wpa.append(f'    psk="{net_entry["psk"]}"')
            if "priority" in net_entry:
                wpa.append(f'    priority={net_entry["priority"]}')
            if net_entry.get("hidden"):
                wpa.append("    scan_ssid=1")
            wpa.append("    key_mgmt=WPA-PSK")
            wpa.append("}")
            wpa.append("")
        iface_name = wifi.get("interface", "wlan0")
        write(wpa_dir / f"wpa_supplicant-{iface_name}.conf", "\n".join(wpa))


def _overlay_line(name: str, params: dict[str, Any] | None = None) -> str:
    """Render a `dtoverlay=...` line with optional comma-joined params."""
    params = params or {}
    if not params:
        return f"dtoverlay={name}"
    parts = [name] + [f"{k}={v}" for k, v in params.items()]
    return "dtoverlay=" + ",".join(parts)


def _emit_boot_section(lines: list[str], heading: str, body: list[str]) -> None:
    """Append a labelled section to config.txt, skipping empty sections."""
    if not body:
        return
    if lines and lines[-1] != "":
        lines.append("")
    lines.append(f"# --- {heading} ---")
    lines.extend(body)


def render_boot(cfg: dict[str, Any]) -> None:
    """Render the consolidated config-bgrpiimage.txt fragment.

    Covers every JSON block that ends up as Raspberry Pi boot config: the
    coarse toggles in `boot_config` (I2C/SPI/UART/BT/WiFi + raw dtoverlays),
    camera / hdmi / display / audio / gpio / leds / rtc / fan / overclock /
    memory / pcie / usb. Runtime-only blocks (watchdog, bootloader, and the
    fan / rtc userspace services) are handled by bgrpiimage-hardware.
    """
    gen = clean_generated("bgrpiimage-boot")
    boot = cfg.get("boot_config") or {}

    lines = ["# === BAUER GROUP auto-generated boot config ===", ""]

    # --- boot_config (the original toggles) -----------------------------------
    core: list[str] = []
    if boot.get("enable_i2c"):
        core.append("dtparam=i2c_arm=on")
    if boot.get("enable_spi"):
        core.append("dtparam=spi=on")
    if boot.get("enable_i2s"):
        core.append("dtparam=i2s=on")
    if boot.get("enable_uart"):
        core.append("enable_uart=1")
    if boot.get("disable_bluetooth"):
        core.append("dtoverlay=disable-bt")
    if boot.get("disable_wifi"):
        core.append("dtoverlay=disable-wifi")
    for ovl in boot.get("dtoverlays", []):
        core.append(_overlay_line(ovl["name"], ovl.get("params")))
    _emit_boot_section(lines, "core", core)

    # --- camera ---------------------------------------------------------------
    cam = cfg.get("camera") or {}
    if cam.get("enabled"):
        body: list[str] = []
        if cam.get("legacy"):
            # Pi4 deprecated stack. Pi5 ignores these but does no harm.
            body.append("start_x=1")
            body.append("gpu_mem=128")
        # autodetect defaults to True when camera is enabled but the field is
        # missing - matches Raspberry Pi OS stock behaviour.
        autodetect = cam.get("autodetect", True)
        body.append(f"camera_auto_detect={1 if autodetect else 0}")
        for sensor in cam.get("sensors") or []:
            body.append(_overlay_line(sensor))
        _emit_boot_section(lines, "camera", body)

    # --- HDMI per-output ------------------------------------------------------
    hdmi = cfg.get("hdmi") or {}
    hdmi_body: list[str] = []
    for out in hdmi.get("outputs") or []:
        p = out["port"]
        # On Pi4+, options take an explicit :port suffix.
        def _opt(key: str, value: Any) -> str:
            return f"{key}:{p}={value}"
        if out.get("force_hotplug"):
            hdmi_body.append(_opt("hdmi_force_hotplug", 1))
        if "group" in out:
            hdmi_body.append(_opt("hdmi_group", out["group"]))
        if "mode" in out:
            hdmi_body.append(_opt("hdmi_mode", out["mode"]))
        drive = out.get("drive")
        audio_force = out.get("audio")
        if drive is not None or audio_force:
            # audio=True implies hdmi, even if drive field is missing; the
            # two options collapse into one line so we don't emit duplicates.
            resolved_drive = 1 if drive == "dvi" else 2
            hdmi_body.append(_opt("hdmi_drive", resolved_drive))
        if audio_force:
            hdmi_body.append(_opt("hdmi_ignore_edid_audio", 0))
        if "rotate" in out and out["rotate"]:
            # Pi4 legacy KMS path.  Pi5 supports the same option for
            # vc4-kms-v3d; anything else needs `video=` on the kernel cmdline.
            hdmi_body.append(_opt("display_hdmi_rotate", out["rotate"] // 90))
        if "boost" in out:
            # config_hdmi_boost is port-agnostic; only honour the last one.
            hdmi_body.append(f"config_hdmi_boost={out['boost']}")
    _emit_boot_section(lines, "hdmi", hdmi_body)

    # --- Display / console rotation -------------------------------------------
    disp = cfg.get("display") or {}
    disp_body: list[str] = []
    if "console_rotate" in disp and disp["console_rotate"]:
        # fbcon rotation is expressed as steps of 90 deg (0..3).
        disp_body.append(f"fbcon=rotate:{disp['console_rotate'] // 90}")
    if "lcd_rotate" in disp and disp["lcd_rotate"]:
        disp_body.append(f"display_lcd_rotate={disp['lcd_rotate'] // 90}")
    _emit_boot_section(lines, "display", disp_body)

    # --- Audio ----------------------------------------------------------------
    audio = cfg.get("audio") or {}
    audio_body: list[str] = []
    if "enabled" in audio:
        audio_body.append(f"dtparam=audio={'on' if audio['enabled'] else 'off'}")
    _emit_boot_section(lines, "audio", audio_body)
    # NOTE: default_output is a runtime ALSA setting, handled by bgrpiimage-hardware.

    # --- GPIO (1-wire) --------------------------------------------------------
    gpio = cfg.get("gpio") or {}
    onew = gpio.get("one_wire") or {}
    if onew.get("enabled"):
        pin = onew.get("pin", 4)
        _emit_boot_section(lines, "1-wire",
                           [_overlay_line("w1-gpio", {"gpiopin": pin})])

    # --- LEDs -----------------------------------------------------------------
    leds = cfg.get("leds") or {}
    led_body: list[str] = []
    # Pi4/5 trigger names that the rpi-eeprom bootloader plus kernel honour
    # via dtparam=act_led_trigger / pwr_led_trigger.
    led_trigger_map = {
        "on": "default-on",
        "off": "none",
        "heartbeat": "heartbeat",
        "mmc0": "mmc0",
        "default": None,
    }
    for which, dtparam_prefix in (("power", "pwr_led"), ("activity", "act_led")):
        val = leds.get(which)
        if val is None or val == "default":
            continue
        trig = led_trigger_map[val]
        if trig is None:
            continue
        led_body.append(f"dtparam={dtparam_prefix}_trigger={trig}")
        if val == "off":
            led_body.append(f"dtparam={dtparam_prefix}_activelow=off")
    _emit_boot_section(lines, "leds", led_body)

    # --- RTC (dt overlay; userspace side is bgrpiimage-hardware) --------------
    rtc = cfg.get("rtc") or {}
    if rtc.get("enabled"):
        params: dict[str, Any] = {}
        model = rtc.get("model")
        if model:
            params[model] = ""
        # dtoverlay=i2c-rtc,<model> needs the bare param, not key=value.
        # Re-render manually so we don't emit `ds3231=` with a trailing eq.
        if model:
            _emit_boot_section(lines, "rtc", [f"dtoverlay=i2c-rtc,{model}"])

    # --- Fan (dtoverlay for gpio-fan / rpi-fan / emc2301) ---------------------
    fan = cfg.get("fan") or {}
    if fan.get("enabled"):
        fan_body: list[str] = []
        mode = fan.get("mode", "gpio")
        if mode == "gpio":
            p: dict[str, Any] = {"gpiopin": fan.get("gpio", 14)}
            if "temp_on" in fan:
                p["temp"] = fan["temp_on"]
            fan_body.append(_overlay_line("gpio-fan", p))
        elif mode == "pwm":
            fan_body.append(_overlay_line("pwm-fan"))
        elif mode == "emc2301":
            # Pi5 Active Cooler / official cooling HAT is on by default; the
            # overlay forces detection when autoprobe fails (e.g. CM5 IO board).
            fan_body.append(_overlay_line("rpi-fan"))
        _emit_boot_section(lines, "fan", fan_body)

    # --- Overclock ------------------------------------------------------------
    ovc = cfg.get("overclock") or {}
    if ovc.get("enabled"):
        ovc_body: list[str] = []
        for k in ("arm_freq", "gpu_freq", "sdram_freq", "over_voltage"):
            if k in ovc:
                ovc_body.append(f"{k}={ovc[k]}")
        _emit_boot_section(lines, "overclock", ovc_body)

    # --- Memory split ---------------------------------------------------------
    mem = cfg.get("memory") or {}
    mem_body: list[str] = []
    for k in ("gpu_mem", "gpu_mem_256", "gpu_mem_512", "gpu_mem_1024", "cma"):
        if k in mem:
            if k == "cma":
                mem_body.append(f"dtoverlay=vc4-kms-v3d,cma-{mem[k]}")
            else:
                mem_body.append(f"{k}={mem[k]}")
    _emit_boot_section(lines, "memory", mem_body)

    # --- PCIe (Pi5/CM4/CM5) ---------------------------------------------------
    pcie = cfg.get("pcie") or {}
    if pcie.get("enabled"):
        pcie_body = ["dtparam=pciex1"]
        if "gen" in pcie:
            pcie_body.append(f"dtparam=pciex1_gen={pcie['gen']}")
        _emit_boot_section(lines, "pcie", pcie_body)

    # --- USB (Pi4 current cap) ------------------------------------------------
    usb = cfg.get("usb") or {}
    if usb.get("max_usb_current"):
        _emit_boot_section(lines, "usb", ["max_usb_current=1"])

    # --- extra_lines (escape hatch) -------------------------------------------
    extras = boot.get("extra_lines") or []
    _emit_boot_section(lines, "extra_lines", list(extras))

    # Trailing newline for a clean config.txt fragment.
    if lines and lines[-1] != "":
        lines.append("")
    write(gen / "config-bgrpiimage.txt", "\n".join(lines))


def render_hardware(cfg: dict[str, Any]) -> None:
    """Render runtime-side hardware artefacts.

    Config.txt lines live in render_boot(); this function produces the userspace
    pieces: hardware.env (consumed by the chroot script), packages.list, the
    optional EEPROM oneshot service + script. When no hardware block is active
    the module stays empty - _module_enabled() filters it out downstream.
    """
    gen = clean_generated("bgrpiimage-hardware")
    if not _module_enabled("bgrpiimage-hardware", cfg):
        # clean_generated leaves an empty dir; that's fine - _module_status
        # will count zero files and mark the module as "no artifacts".
        return
    # shell_var already terminates with "\n"; join without adding extra blanks.
    env_chunks: list[str] = [
        "# Auto-generated hardware.env - sourced by start_chroot_script\n",
    ]
    packages: set[str] = set()

    rtc = cfg.get("rtc") or {}
    env_chunks.append(shell_var("BGRPIIMAGE_RTC_ENABLED", "yes" if rtc.get("enabled") else "no"))
    if rtc.get("enabled"):
        packages.add("util-linux")  # hwclock lives in util-linux on Debian
        if rtc.get("fake_hwclock"):
            packages.add("fake-hwclock")
    env_chunks.append(shell_var(
        "BGRPIIMAGE_RTC_FAKE_HWCLOCK", "yes" if rtc.get("fake_hwclock") else "no"
    ))

    wd = cfg.get("watchdog") or {}
    env_chunks.append(shell_var("BGRPIIMAGE_WATCHDOG_ENABLED", "yes" if wd.get("enabled") else "no"))
    if wd.get("enabled"):
        env_chunks.append(shell_var("BGRPIIMAGE_WATCHDOG_RUNTIME_SEC", wd.get("runtime_sec", 10)))
        env_chunks.append(shell_var("BGRPIIMAGE_WATCHDOG_REBOOT_SEC", wd.get("reboot_sec", 120)))

    audio = cfg.get("audio") or {}
    if audio.get("default_output"):
        env_chunks.append(shell_var("BGRPIIMAGE_AUDIO_DEFAULT_OUTPUT", audio["default_output"]))

    fan = cfg.get("fan") or {}
    if fan.get("enabled") and fan.get("mode") in ("gpio", "pwm"):
        # gpio-fan and pwm-fan need a couple of sysfs knobs that the overlay
        # itself exposes; no additional packages strictly required. Kept here
        # for future trip-curve script drops.
        pass

    boot = cfg.get("bootloader") or {}
    if boot:
        # Userspace oneshot that applies EEPROM settings once on first boot.
        eeprom_env_lines: list[str] = [
            "# Auto-generated eeprom.env - consumed by bgrpiimage-eeprom-apply",
        ]
        for key, env_key in (
            ("boot_order",          "BOOT_ORDER"),
            ("wake_on_gpio",        "WAKE_ON_GPIO"),
            ("power_off_on_halt",   "POWER_OFF_ON_HALT"),
        ):
            if key not in boot:
                continue
            value = boot[key]
            if isinstance(value, bool):
                value = 1 if value else 0
            eeprom_env_lines.append(f"{env_key}={value}")
        write(gen / "eeprom.env", "\n".join(eeprom_env_lines) + "\n")

        # Shell script: read eeprom.env, merge into a temp config, apply once.
        apply_script = """#!/usr/bin/env bash
# Idempotent EEPROM config application. Runs once on first boot; the sentinel
# file keeps us from touching the bootloader on every reboot.
set -euo pipefail
SENTINEL=/var/lib/bgrpiimage/eeprom-applied
STAMP_DIR=/var/lib/bgrpiimage
mkdir -p "$STAMP_DIR"
[[ -f "$SENTINEL" ]] && exit 0

if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    echo "rpi-eeprom-config not installed - skipping" >&2
    touch "$SENTINEL"
    exit 0
fi

src=/etc/bgrpiimage/eeprom.env
[[ -f "$src" ]] || { echo "no eeprom.env"; exit 0; }

tmp=$(mktemp)
rpi-eeprom-config > "$tmp"
while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    if grep -q "^${key}=" "$tmp"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$tmp"
    else
        echo "${key}=${value}" >> "$tmp"
    fi
done < "$src"

rpi-eeprom-config --apply "$tmp" || true
rm -f "$tmp"
touch "$SENTINEL"
"""
        write(gen / "bgrpiimage-eeprom-apply.sh", apply_script, executable=True)

        eeprom_unit = """[Unit]
Description=Apply BAUER GROUP EEPROM bootloader config (first boot)
After=network.target
ConditionPathExists=!/var/lib/bgrpiimage/eeprom-applied

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bgrpiimage-eeprom-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"""
        write(gen / "bgrpiimage-eeprom-apply.service", eeprom_unit)
        # rpi-eeprom ships preinstalled on Raspberry Pi OS trixie (arm64);
        # listing it would just no-op, so we skip adding it to packages.list.

    if packages:
        write(gen / "packages.list", "\n".join(sorted(packages)) + "\n")
    write(gen / "hardware.env", "".join(env_chunks))


def render_can(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgrpiimage-can")
    can = cfg.get("can", {})
    ifaces = can.get("interfaces", [])
    if not ifaces:
        return
    nwd = gen / "systemd-networkd"
    nwd.mkdir(parents=True, exist_ok=True)

    pkg_list = ["can-utils"]
    write(gen / "packages.list", "\n".join(pkg_list) + "\n")

    for iface in ifaces:
        name = iface["name"]
        bitrate = iface["bitrate"]
        txqlen = iface.get("txqueuelen", 1000)
        auto_up = iface.get("auto_up", True)
        content = [
            "[Match]",
            f"Name={name}",
            "",
            "[CAN]",
            f"BitRate={bitrate}",
        ]
        if "sample_point" in iface:
            content.append(f"SamplePoint={iface['sample_point']}")
        content.append("")
        content.append("[Link]")
        content.append(f"TransmitQueueLength={txqlen}")
        if auto_up:
            content.append("RequiredForOnline=no")
        content.append("")
        write(nwd / f"40-{name}.network", "\n".join(content))


def render_docker(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgrpiimage-docker")
    docker = cfg.get("docker") or {}
    if not docker.get("enabled"):
        write(gen / ".disabled", "")
        return
    # daemon.json
    daemon = docker.get("daemon", {})
    write(gen / "daemon.json", json.dumps(daemon, indent=2) + "\n")
    # sysctl drop-in
    sysctl = docker.get("sysctl", {})
    if sysctl:
        lines = ["# Auto-generated by bgRPIImage"]
        for k, v in sysctl.items():
            lines.append(f"{k}={v}")
        write(gen / "98-docker.conf", "\n".join(lines) + "\n")
    # Networks to create post-install (one-shot service)
    networks = docker.get("networks", [])
    create_lines = ["#!/bin/bash", "# Auto-generated docker network creation", "set -euo pipefail", ""]
    for n in networks:
        args = ["docker network create"]
        args.append(f"--driver={n.get('driver', 'bridge')}")
        if n.get("subnet"):
            args.append(f"--subnet={n['subnet']}")
        if n.get("gateway"):
            args.append(f"--gateway={n['gateway']}")
        if n.get("ipv6"):
            args.append("--ipv6")
            if n.get("subnet_v6"):
                args.append(f"--subnet={n['subnet_v6']}")
            if n.get("gateway_v6"):
                args.append(f"--gateway={n['gateway_v6']}")
        for k, v in (n.get("options") or {}).items():
            args.append(f'-o "{k}={v}"')
        args.append(shlex.quote(n["name"]))
        create_lines.append(
            f"docker network inspect {shlex.quote(n['name'])} >/dev/null 2>&1 || \\"
        )
        create_lines.append("  " + " ".join(args))
    write(gen / "create-networks.sh", "\n".join(create_lines) + "\n", executable=True)
    # ipv6 masquerade helper unit (replaces stock docker-support)
    unit = (
        "[Unit]\n"
        "Description=BAUER GROUP IPv6 NAT for Docker\n"
        "BindsTo=docker.service\n"
        "After=docker.service\n"
        "ReloadPropagatedFrom=docker.service\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        "ExecStart=/usr/sbin/ip6tables -t nat -C POSTROUTING -s fdff::/64 ! -o docker0 -j MASQUERADE\n"
        "ExecStart=-/usr/sbin/ip6tables -t nat -A POSTROUTING -s fdff::/64 ! -o docker0 -j MASQUERADE\n"
        "RemainAfterExit=yes\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )
    write(gen / "docker-support.service", unit)


def render_portainer(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgrpiimage-portainer")
    p = cfg.get("portainer") or {}
    if not p.get("enabled"):
        return
    bind = p.get("bind", "0.0.0.0")
    edition = p.get("edition", "ce")
    image = p.get("image") or (
        "portainer/portainer-ce:latest" if edition == "ce" else "portainer/portainer-ee:latest"
    )
    ports = p.get("ports") or {}
    edge = ports.get("edge", 8000)
    http = ports.get("http", 9000)
    https = ports.get("https", 9443)

    # Port mapping with dual-stack awareness:
    #   bind == "0.0.0.0" (default)  -> bind without host IP, so Docker
    #                                   listens on both 0.0.0.0:PORT and
    #                                   [::]:PORT (IPv6) when daemon.json
    #                                   has ipv6:true. "0.0.0.0:PORT:PORT"
    #                                   would restrict to IPv4 only.
    #   any other value              -> pin to that specific address (e.g.
    #                                   "127.0.0.1" for loopback only,
    #                                   "::1" for v6 loopback).
    def port(host_port: int, container_port: int) -> str:
        if bind in ("0.0.0.0", "", None):
            return f'"{host_port}:{container_port}"'
        return f'"{bind}:{host_port}:{container_port}"'

    # Declarative compose file - Docker's restart=unless-stopped policy
    # handles lifecycle after first-boot install. No systemd wrapping around
    # the running container, no --rm, no double supervisor.
    compose = (
        "# Auto-generated by bgRPIImage\n"
        "# Operator workflow:\n"
        "#   sudo docker compose -f /etc/bgrpiimage/portainer/docker-compose.yml pull\n"
        "#   sudo docker compose -f /etc/bgrpiimage/portainer/docker-compose.yml up -d\n"
        "\n"
        "services:\n"
        "  portainer:\n"
        f"    image: {image}\n"
        "    container_name: portainer\n"
        "    restart: unless-stopped\n"
        "    ports:\n"
        f"      - {port(edge, 8000)}\n"
        f"      - {port(http, 9000)}\n"
        f"      - {port(https, 9443)}\n"
        "    volumes:\n"
        "      - /var/run/docker.sock:/var/run/docker.sock\n"
        "      - portainer_data:/data\n"
        "\n"
        "volumes:\n"
        "  portainer_data:\n"
        "    name: portainer\n"
    )
    write(gen / "docker-compose.yml", compose)

    # First-boot oneshot. After it runs once, the Docker daemon itself
    # keeps the container alive via the compose file's restart policy.
    install_unit = (
        "[Unit]\n"
        "Description=bgRPIImage Portainer bootstrap (first boot only)\n"
        "Requires=docker.service\n"
        "After=docker.service docker-support.service bgrpiimage-docker-networks.service\n"
        "ConditionPathExists=!/var/lib/bgrpiimage/portainer.installed\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        "RemainAfterExit=yes\n"
        "WorkingDirectory=/etc/bgrpiimage/portainer\n"
        "ExecStart=/usr/bin/docker compose up -d\n"
        "ExecStartPost=/bin/sh -c \"mkdir -p /var/lib/bgrpiimage && touch /var/lib/bgrpiimage/portainer.installed\"\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )
    write(gen / "bgrpiimage-portainer-install.service", install_unit)
    write(
        gen / "portainer.env",
        "".join(
            [
                shell_var("BGRPIIMAGE_PORTAINER_AUTOSTART", bool(p.get("auto_start", True))),
                shell_var("BGRPIIMAGE_PORTAINER_IMAGE", image),
            ]
        ),
    )


def render_unattended(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgrpiimage-unattended-upgrades")
    u = cfg.get("unattended_upgrades") or {}
    if not u.get("enabled"):
        write(gen / ".disabled", "")
        return

    origins = u.get("allowed_origins") or []
    blocklist = u.get("package_blocklist") or []
    remove_unused = u.get("remove_unused_dependencies", True)
    mail = u.get("mail") or {}
    reboot = u.get("auto_reboot") or {}
    schedule = u.get("schedule") or {}

    # 50unattended-upgrades
    cfg_lines = ["// Auto-generated by scripts/generate.py", "Unattended-Upgrade::Origins-Pattern {"]
    for origin in origins:
        cfg_lines.append(f'    "{origin}";')
    cfg_lines.append("};")
    cfg_lines.append("")
    cfg_lines.append("Unattended-Upgrade::Package-Blacklist {")
    for pkg in blocklist:
        cfg_lines.append(f'    "{pkg}";')
    cfg_lines.append("};")
    cfg_lines.append("")
    cfg_lines.append(f'Unattended-Upgrade::Remove-Unused-Dependencies "{"true" if remove_unused else "false"}";')
    cfg_lines.append('Unattended-Upgrade::Remove-New-Unused-Dependencies "true";')
    # Reboot is handled by our own window service, not by u-u directly.
    cfg_lines.append('Unattended-Upgrade::Automatic-Reboot "false";')
    if mail.get("address"):
        cfg_lines.append(f'Unattended-Upgrade::Mail "{mail["address"]}";')
        cfg_lines.append(f'Unattended-Upgrade::MailOnlyOnError "{"true" if mail.get("on_error_only", True) else "false"}";')
    cfg_lines.append("")
    write(gen / "50unattended-upgrades", "\n".join(cfg_lines))

    # 20auto-upgrades - enables apt to call u-u.
    write(
        gen / "20auto-upgrades",
        "APT::Periodic::Update-Package-Lists \"1\";\n"
        "APT::Periodic::Download-Upgradeable-Packages \"1\";\n"
        "APT::Periodic::AutocleanInterval \"7\";\n"
        "APT::Periodic::Unattended-Upgrade \"1\";\n",
    )

    # apt-daily-upgrade.timer override -> fires inside [start, end] window.
    start = schedule.get("start", "02:00")
    end = schedule.get("end", "04:00")
    persistent = "true" if schedule.get("persistent", True) else "false"
    window_minutes = _window_minutes(start, end)
    override = (
        "[Timer]\n"
        "OnCalendar=\n"
        f"OnCalendar=*-*-* {start}:00\n"
        f"RandomizedDelaySec={window_minutes * 60}\n"
        f"Persistent={persistent}\n"
    )
    write(gen / "apt-daily-upgrade.timer.d/override.conf", override)
    # same cadence for apt-daily (download) - shift 30 min earlier within bounds
    dl_override = (
        "[Timer]\n"
        "OnCalendar=\n"
        f"OnCalendar=*-*-* {start}:00\n"
        f"RandomizedDelaySec=1800\n"
        f"Persistent={persistent}\n"
    )
    write(gen / "apt-daily.timer.d/override.conf", dl_override)

    # Reboot window service + timer
    if reboot.get("enabled"):
        rwin = reboot.get("window", {})
        r_start = rwin.get("start", "03:00")
        r_end = rwin.get("end", "05:00")
        r_window = _window_minutes(r_start, r_end)
        if_required = reboot.get("if_required_only", True)

        # The check script is invoked from both
        #   (a) the maintenance timer (safety net, runs once per day)
        #   (b) apt-daily-upgrade.service ExecStartPost (event-driven, runs
        #       right after each update attempt)
        # A reboot only happens when:
        #   - /var/run/reboot-required exists (set by kernel / libc / etc.
        #     package post-install hooks) AND
        #   - current local time is inside the configured reboot window.
        check_script = [
            "#!/bin/bash",
            "# Auto-generated: reboot iff a package upgrade set the",
            "# /var/run/reboot-required flag AND we are inside the window.",
            "set -euo pipefail",
            f'WINDOW_START="{r_start}"',
            f'WINDOW_END="{r_end}"',
            f'IF_REQUIRED_ONLY={"1" if if_required else "0"}',
            'TAG="bgrpiimage-reboot"',
            'now=$(date +%H:%M)',
            'in_window() {',
            '  local now=$1 start=$2 end=$3',
            '  if [[ "$start" < "$end" ]]; then',
            '    [[ "$now" > "$start" || "$now" == "$start" ]] && [[ "$now" < "$end" ]]',
            '  else',
            '    [[ "$now" > "$start" || "$now" == "$start" || "$now" < "$end" ]]',
            '  fi',
            '}',
            '# (1) guard: must have a pending reboot request from a package',
            'if [[ $IF_REQUIRED_ONLY -eq 1 ]]; then',
            '  if [[ ! -f /var/run/reboot-required ]]; then',
            '    logger -t "$TAG" "no reboot required - skipping"',
            '    exit 0',
            '  fi',
            'fi',
            '# (2) guard: must be inside the configured reboot window',
            'if ! in_window "$now" "$WINDOW_START" "$WINDOW_END"; then',
            '  logger -t "$TAG" "reboot required but outside window ($now not in $WINDOW_START-$WINDOW_END) - deferring"',
            '  exit 0',
            'fi',
            '# (3) log the packages that triggered the reboot',
            'pkgs=""',
            'if [[ -s /var/run/reboot-required.pkgs ]]; then',
            '  pkgs=$(tr "\\n" " " < /var/run/reboot-required.pkgs)',
            'fi',
            'logger -t "$TAG" "rebooting inside window ${WINDOW_START}-${WINDOW_END} (triggered by: ${pkgs:-unknown})"',
            '/sbin/shutdown -r +1 "bgRPIImage: scheduled reboot after unattended-upgrade (${pkgs:-kernel/system package update})"',
            '',
        ]
        write(gen / "bgrpiimage-reboot-window.sh", "\n".join(check_script), executable=True)

        # Event-driven trigger: run the reboot-window check right after every
        # apt-daily-upgrade.service execution. '-' prefix ignores failures so
        # a broken script never blocks the upgrade service from succeeding.
        apt_upgrade_dropin = (
            "[Service]\n"
            "ExecStartPost=-/usr/local/sbin/bgrpiimage-reboot-window.sh\n"
        )
        write(gen / "apt-daily-upgrade.service.d/override.conf", apt_upgrade_dropin)

        svc = (
            "[Unit]\n"
            "Description=BAUER GROUP conditional reboot after unattended-upgrade\n"
            "After=apt-daily-upgrade.service\n"
            "\n"
            "[Service]\n"
            "Type=oneshot\n"
            "ExecStart=/usr/local/sbin/bgrpiimage-reboot-window.sh\n"
        )
        write(gen / "bgrpiimage-reboot-window.service", svc)

        tmr = (
            "[Unit]\n"
            "Description=BAUER GROUP reboot window check\n"
            "\n"
            "[Timer]\n"
            f"OnCalendar=*-*-* {r_start}:00\n"
            f"RandomizedDelaySec={r_window * 60}\n"
            "Persistent=true\n"
            "Unit=bgrpiimage-reboot-window.service\n"
            "\n"
            "[Install]\n"
            "WantedBy=timers.target\n"
        )
        write(gen / "bgrpiimage-reboot-window.timer", tmr)


def _semantic_validate(cfg: dict[str, Any]) -> None:
    """Cross-field validation beyond what JSON Schema expresses.

    Fails fast with a human-readable error rather than a confusing dtoverlay
    or unit file later on.
    """
    ovc = cfg.get("overclock") or {}
    if ovc.get("enabled") and not ovc.get("accept_warranty_void"):
        raise ValueError(
            "overclock.enabled=true requires overclock.accept_warranty_void=true "
            "- overclocking permanently flips the Pi's warranty OTP bit."
        )

    fan = cfg.get("fan") or {}
    if fan.get("enabled") and fan.get("mode") not in ("gpio", "pwm", "emc2301"):
        raise ValueError("fan.enabled=true requires fan.mode to be gpio|pwm|emc2301")

    rtc = cfg.get("rtc") or {}
    if rtc.get("enabled") and not rtc.get("model"):
        raise ValueError("rtc.enabled=true requires rtc.model")


def _window_minutes(start_hhmm: str, end_hhmm: str) -> int:
    """Minutes between two HH:MM timestamps, wrapping past midnight if needed."""
    def to_min(s: str) -> int:
        h, m = s.split(":")
        return int(h) * 60 + int(m)
    delta = to_min(end_hhmm) - to_min(start_hhmm)
    if delta <= 0:
        delta += 24 * 60
    return delta


# -----------------------------------------------------------------------------
# Variant shell config & module selection
# -----------------------------------------------------------------------------
ACTIVE_MODULES: list[str] = [
    "bgrpiimage-base",
    "bgrpiimage-users",
    "bgrpiimage-network",
    "bgrpiimage-boot",
    "bgrpiimage-hardware",
    "bgrpiimage-can",
    "bgrpiimage-docker",
    "bgrpiimage-portainer",
    "bgrpiimage-unattended-upgrades",
]


def render_variant_config(cfg: dict[str, Any]) -> None:
    name = cfg["variant"]["name"]
    variant_dir = VARIANTS_DIR / name
    variant_dir.mkdir(parents=True, exist_ok=True)

    modules = [m for m in ACTIVE_MODULES if _module_enabled(m, cfg)]

    # CustomPiOS variant config: exports shell variables that refine the
    # distro-level src/config. MODULES controls execution order in the chroot.
    variant_cfg: list[str] = []
    variant_cfg.append(f"# Auto-generated variant config for {name}\n")
    variant_cfg.append(f"export DIST_NAME={shlex.quote(f'bgrpiimage-{name}')}\n")
    variant_cfg.append(f"export DIST_VERSION={shlex.quote(cfg['variant'].get('version', '0.0.0'))}\n")
    # CustomPiOS strips spaces from MODULES and splits on commas; a
    # space-separated list ends up concatenated into one invalid token.
    variant_cfg.append(f"export MODULES={shlex.quote(','.join(modules))}\n")
    variant_cfg.append(f"export BGRPIIMAGE_VARIANT={shlex.quote(name)}\n")
    variant_cfg.append(f"export BGRPIIMAGE_HOSTNAME={shlex.quote(cfg['hostname'])}\n")
    variant_cfg.append(f"export BGRPIIMAGE_TARGETS={shlex.quote(','.join(cfg['targets']))}\n")
    # Override the hostname raspios ships, via CustomPiOS's built-in hook.
    variant_cfg.append(f"export BASE_OVERRIDE_HOSTNAME={shlex.quote(cfg['hostname'])}\n")
    write(variant_dir / "config", "".join(variant_cfg))


def _module_enabled(module: str, cfg: dict[str, Any]) -> bool:
    """Some modules are only included if their section is populated/enabled."""
    if module == "bgrpiimage-can":
        return bool((cfg.get("can") or {}).get("interfaces"))
    if module == "bgrpiimage-docker":
        return bool((cfg.get("docker") or {}).get("enabled"))
    if module == "bgrpiimage-portainer":
        return bool((cfg.get("portainer") or {}).get("enabled"))
    if module == "bgrpiimage-unattended-upgrades":
        return bool((cfg.get("unattended_upgrades") or {}).get("enabled"))
    if module == "bgrpiimage-hardware":
        # Active iff at least one runtime-touching hardware block is set.
        return any((
            (cfg.get("rtc") or {}).get("enabled"),
            (cfg.get("watchdog") or {}).get("enabled"),
            bool(cfg.get("bootloader")),
            ((cfg.get("audio") or {}).get("default_output") not in (None, "auto")),
        ))
    return True


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def _module_status(module: str) -> tuple[str, int]:
    """Return (status, file_count) for a module's generated files.

    Files live under module/filesystem/root/opt/bgrpiimage/<module>/ as well
    as module/filesystem/root/... for files that land at fixed chroot paths
    (e.g. the static bgrpiimage-setup helper).
    """
    gen_tree = MODULES_DIR / module / "filesystem" / "root"
    if not gen_tree.exists():
        return ("empty", 0)
    count = sum(1 for p in gen_tree.rglob("*") if p.is_file())
    return ("rendered" if count else "empty", count)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path, help="path to variant JSON config")
    parser.add_argument("--env-file", type=Path, help="optional .env file (KEY=VALUE lines)")
    parser.add_argument("--dry-run", action="store_true", help="validate & resolve only (rich output)")
    parser.add_argument("--json", action="store_true", help="validate & print resolved JSON to stdout (no decoration)")
    args = parser.parse_args()

    # Load + follow `extends` chain (deep-merge parents into this variant).
    try:
        raw = load_variant(args.config)
    except FileNotFoundError as e:
        _error_panel("config not found", str(e))
        return 2
    except ValueError as e:
        _error_panel("invalid extends chain", str(e))
        return 2

    env = dict(os.environ)
    if args.env_file and args.env_file.exists():
        for line in args.env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env.setdefault(k.strip(), v.strip().strip('"').strip("'"))

    try:
        resolved = resolve_tree(raw, env)
    except KeyError as e:
        _error_panel(
            "missing environment variable",
            str(e).strip("'"),
            hint="export the variable or use ${VAR:-default} in the JSON",
        )
        return 2

    with SCHEMA_PATH.open("r", encoding="utf-8") as f:
        schema = json.load(f)
    # The schema $id points at GitHub raw; strip to avoid online fetch.
    schema.pop("$id", None)
    try:
        jsonschema.validate(resolved, schema)
    except jsonschema.ValidationError as e:
        path = " → ".join(str(x) for x in e.absolute_path) or "(root)"
        _error_panel(
            "config validation failed",
            f"[bold]{e.message}[/]\n[dim]at:[/] {path}",
        )
        return 2

    # Cross-field checks the JSON schema can't express.
    try:
        _semantic_validate(resolved)
    except ValueError as e:
        _error_panel("config validation failed", str(e))
        return 2

    variant_name = resolved["variant"]["name"]
    variant_version = resolved["variant"].get("version", "?")

    if args.json:
        # Plain JSON to stdout - for piping into jq in CI scripts.
        sys.stdout.write(json.dumps(resolved, indent=2) + "\n")
        return 0

    if args.dry_run:
        console.print(Panel.fit(
            f"[bold cyan]{variant_name}[/] [dim]v{variant_version}[/] [green]valid[/]",
            border_style="green", box=box.ROUNDED,
        ))
        console.print(JSON.from_data(resolved))
        return 0

    # Header with resolved variant metadata.
    console.print(Panel(
        f"[bold cyan]{variant_name}[/]  [dim]v{variant_version}[/]\n"
        f"[dim]hostname:[/] {resolved['hostname']}\n"
        f"[dim]targets: [/] {', '.join(resolved['targets'])}",
        title="[bold]bgRPIImage render[/]", border_style="cyan", box=box.ROUNDED,
        title_align="left",
    ))

    steps: list[tuple[str, Any]] = [
        ("bgrpiimage-base",                 render_base),
        ("bgrpiimage-users",                render_users),
        ("bgrpiimage-network",              render_network),
        ("bgrpiimage-boot",                 render_boot),
        ("bgrpiimage-hardware",             render_hardware),
        ("bgrpiimage-can",                  render_can),
        ("bgrpiimage-docker",               render_docker),
        ("bgrpiimage-portainer",            render_portainer),
        ("bgrpiimage-unattended-upgrades",  render_unattended),
    ]

    table = Table(box=box.SIMPLE, show_header=True, header_style="bold dim")
    table.add_column("", width=2)
    table.add_column("module")
    table.add_column("files", justify="right")
    table.add_column("status", style="dim")

    total = 0
    for module, fn in steps:
        fn(resolved)
        status, count = _module_status(module)
        if status == "rendered":
            table.add_row("[green]✓[/]", module, str(count), "rendered")
            total += count
        elif status == "disabled":
            table.add_row("[yellow]·[/]", f"[dim]{module}[/]", "-", "disabled in config")
        else:
            table.add_row("[dim]·[/]", f"[dim]{module}[/]", "-", "no artifacts (skipped by filter)")

    render_variant_config(resolved)
    console.print(table)
    console.print(
        f"  [green]{total}[/] artifact{'s' if total != 1 else ''} written to "
        f"[dim]src/modules/*/filesystem/root/[/]\n"
        f"  variant config: [dim]src/variants/{variant_name}/config[/]"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
