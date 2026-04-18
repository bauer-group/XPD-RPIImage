#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
BAUER GROUP XPD-RPIImage - variant config renderer.

Reads a JSON variant config, resolves ${ENV} references, validates against
schema.json, and renders all artifacts into the CustomPiOS module tree at
src/modules/<module>/files/_generated/ plus the variant shell config at
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
except ImportError:
    print("error: jsonschema not installed. run: pip install -r scripts/requirements.txt", file=sys.stderr)
    sys.exit(2)

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
    gen = MODULES_DIR / module_name / "files" / "_generated"
    if gen.exists():
        shutil.rmtree(gen)
    gen.mkdir(parents=True)
    return gen


# -----------------------------------------------------------------------------
# Renderers - one per feature area
# -----------------------------------------------------------------------------
def render_base(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgRPIImage-base")
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


def render_users(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgRPIImage-users")
    users = cfg.get("users", [])
    remove_users = cfg.get("remove_users", [])
    root = cfg.get("root", {})
    script = ["#!/bin/bash", "# Auto-generated by scripts/generate.py", "set -euo pipefail", ""]

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
            script.append(f"usermod -aG {shlex.quote(groups)} {shlex.quote(name)}")
        # chpasswd via stdin keeps the password out of argv / process lists.
        script.append(f"echo {shlex.quote(f'{name}:{pw}')} | chpasswd")
        if user.get("sudo_nopasswd"):
            sudoers_line = f"{name} ALL=(ALL) NOPASSWD:ALL"
            script.append(
                f"echo {shlex.quote(sudoers_line)} > /etc/sudoers.d/010-bgRPIImage-{name}"
            )
            script.append(f"chmod 440 /etc/sudoers.d/010-bgRPIImage-{name}")
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
        script.append("install -m 644 /tmp/_bgRPIImage_su_pam /etc/pam.d/su")

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
    script.append("cat > /etc/ssh/sshd_config.d/10-bgRPIImage.conf <<'__BGRPIIMAGE_EOF__'")
    script.extend(sshd)
    script.append("__BGRPIIMAGE_EOF__")
    script.append("chmod 644 /etc/ssh/sshd_config.d/10-bgRPIImage.conf")

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
    gen = clean_generated("bgRPIImage-network")
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


def render_boot(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgRPIImage-boot")
    boot = cfg.get("boot_config", {})
    lines = ["# === BAUER GROUP auto-generated boot config ===", ""]
    if boot.get("enable_i2c"):
        lines.append("dtparam=i2c_arm=on")
    if boot.get("enable_spi"):
        lines.append("dtparam=spi=on")
    if boot.get("enable_i2s"):
        lines.append("dtparam=i2s=on")
    if boot.get("enable_uart"):
        lines.append("enable_uart=1")
    if boot.get("disable_bluetooth"):
        lines.append("dtoverlay=disable-bt")
    if boot.get("disable_wifi"):
        lines.append("dtoverlay=disable-wifi")
    for ovl in boot.get("dtoverlays", []):
        params = ovl.get("params") or {}
        if params:
            parts = [ovl["name"]] + [f"{k}={v}" for k, v in params.items()]
            lines.append("dtoverlay=" + ",".join(parts))
        else:
            lines.append(f"dtoverlay={ovl['name']}")
    for extra in boot.get("extra_lines", []):
        lines.append(extra)
    lines.append("")
    write(gen / "config-bgRPIImage.txt", "\n".join(lines))


def render_can(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgRPIImage-can")
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
    gen = clean_generated("bgRPIImage-docker")
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
    gen = clean_generated("bgRPIImage-portainer")
    p = cfg.get("portainer") or {}
    if not p.get("enabled"):
        write(gen / ".disabled", "")
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

    port_args = [
        f"-p {bind}:{edge}:8000",
        f"-p {bind}:{http}:9000",
        f"-p {bind}:{https}:9443",
    ]
    # systemd ExecStart allows line continuation with trailing backslash; build
    # the multi-line value as real newlines so the unit parses correctly.
    exec_lines = [
        "/usr/bin/docker run --rm --name portainer --pull=always",
        *(f"  {a}" for a in port_args),
        "  -v /var/run/docker.sock:/var/run/docker.sock",
        "  -v portainer:/data",
        f"  {image}",
    ]
    exec_start = "ExecStart=" + " \\\n".join(exec_lines) + "\n"

    unit = (
        "[Unit]\n"
        "Description=Portainer (BAUER GROUP managed)\n"
        "Requires=docker.service\n"
        "After=docker.service docker-support.service\n"
        "\n"
        "[Service]\n"
        "Type=simple\n"
        "Restart=always\n"
        "RestartSec=10\n"
        "ExecStartPre=-/usr/bin/docker rm -f portainer\n"
        "ExecStartPre=/usr/bin/docker volume create portainer\n"
        + exec_start +
        "ExecStop=/usr/bin/docker stop portainer\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )
    write(gen / "portainer.service", unit)
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
    gen = clean_generated("bgRPIImage-unattended-upgrades")
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
            'TAG="bgRPIImage-reboot"',
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
        write(gen / "bgRPIImage-reboot-window.sh", "\n".join(check_script), executable=True)

        # Event-driven trigger: run the reboot-window check right after every
        # apt-daily-upgrade.service execution. '-' prefix ignores failures so
        # a broken script never blocks the upgrade service from succeeding.
        apt_upgrade_dropin = (
            "[Service]\n"
            "ExecStartPost=-/usr/local/sbin/bgRPIImage-reboot-window.sh\n"
        )
        write(gen / "apt-daily-upgrade.service.d/override.conf", apt_upgrade_dropin)

        svc = (
            "[Unit]\n"
            "Description=BAUER GROUP conditional reboot after unattended-upgrade\n"
            "After=apt-daily-upgrade.service\n"
            "\n"
            "[Service]\n"
            "Type=oneshot\n"
            "ExecStart=/usr/local/sbin/bgRPIImage-reboot-window.sh\n"
        )
        write(gen / "bgRPIImage-reboot-window.service", svc)

        tmr = (
            "[Unit]\n"
            "Description=BAUER GROUP reboot window check\n"
            "\n"
            "[Timer]\n"
            f"OnCalendar=*-*-* {r_start}:00\n"
            f"RandomizedDelaySec={r_window * 60}\n"
            "Persistent=true\n"
            "Unit=bgRPIImage-reboot-window.service\n"
            "\n"
            "[Install]\n"
            "WantedBy=timers.target\n"
        )
        write(gen / "bgRPIImage-reboot-window.timer", tmr)


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
    "bgRPIImage-base",
    "bgRPIImage-users",
    "bgRPIImage-network",
    "bgRPIImage-boot",
    "bgRPIImage-can",
    "bgRPIImage-docker",
    "bgRPIImage-portainer",
    "bgRPIImage-unattended-upgrades",
]


def render_variant_config(cfg: dict[str, Any]) -> None:
    name = cfg["variant"]["name"]
    variant_dir = VARIANTS_DIR / name
    image_dir = variant_dir / "image"
    variant_dir.mkdir(parents=True, exist_ok=True)
    image_dir.mkdir(parents=True, exist_ok=True)

    modules = [m for m in ACTIVE_MODULES if _module_enabled(m, cfg)]

    variant_cfg = []
    variant_cfg.append(f"# Auto-generated variant config for {name}\n")
    variant_cfg.append(shell_var("DIST_NAME", f"bgRPIImage-{name}"))
    variant_cfg.append(shell_var("DIST_VERSION", cfg["variant"].get("version", "0.0.0")))
    variant_cfg.append(shell_var("MODULES", " ".join(modules)))
    variant_cfg.append(shell_var("BGRPIIMAGE_VARIANT", name))
    variant_cfg.append(shell_var("BGRPIIMAGE_HOSTNAME", cfg["hostname"]))
    write(variant_dir / "config", "".join(variant_cfg))

    # Image-level config: points to the base image.
    base = cfg["base_image"]
    image_lines = [
        shell_var("BASE_ZIP_IMG", base["url"].rsplit("/", 1)[-1]),
        shell_var("BASE_IMAGE_ENLARGEROOT", "2000"),
        shell_var("BASE_IMAGE_RESIZEROOT", "200"),
        shell_var("BASE_IMAGE_URL", base["url"]),
        shell_var("BASE_IMAGE_SHA256", base.get("sha256", "")),
        shell_var("BGRPIIMAGE_TARGETS", ",".join(cfg["targets"])),
    ]
    write(image_dir / "config", "".join(image_lines))


def _module_enabled(module: str, cfg: dict[str, Any]) -> bool:
    """Some modules are only included if their section is populated/enabled."""
    if module == "bgRPIImage-can":
        return bool((cfg.get("can") or {}).get("interfaces"))
    if module == "bgRPIImage-docker":
        return bool((cfg.get("docker") or {}).get("enabled"))
    if module == "bgRPIImage-portainer":
        return bool((cfg.get("portainer") or {}).get("enabled"))
    if module == "bgRPIImage-unattended-upgrades":
        return bool((cfg.get("unattended_upgrades") or {}).get("enabled"))
    return True


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path, help="path to variant JSON config")
    parser.add_argument("--env-file", type=Path, help="optional .env file (KEY=VALUE lines)")
    parser.add_argument("--dry-run", action="store_true", help="validate & resolve only")
    args = parser.parse_args()

    # Load + follow `extends` chain (deep-merge parents into this variant).
    raw = load_variant(args.config)

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
        print(f"error: {e}", file=sys.stderr)
        return 2

    with SCHEMA_PATH.open("r", encoding="utf-8") as f:
        schema = json.load(f)
    # The schema $id points at GitHub raw; strip to avoid online fetch.
    schema.pop("$id", None)
    try:
        jsonschema.validate(resolved, schema)
    except jsonschema.ValidationError as e:
        print(f"error: config does not match schema:\n  {e.message}\n  at: {list(e.absolute_path)}", file=sys.stderr)
        return 2

    if args.dry_run:
        print(json.dumps(resolved, indent=2))
        return 0

    render_base(resolved)
    render_users(resolved)
    render_network(resolved)
    render_boot(resolved)
    render_can(resolved)
    render_docker(resolved)
    render_portainer(resolved)
    render_unattended(resolved)
    render_variant_config(resolved)

    print(f"ok: rendered variant '{resolved['variant']['name']}' into src/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
