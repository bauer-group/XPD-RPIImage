# ⚙️ Configuration reference

Every variant JSON is validated against
[`config/schema.json`](../config/schema.json). This doc describes each section
with defaults and examples. Source of truth is always the schema.

---

## 📋 Top-level keys

| Key | Type | Required | Purpose |
| --- | --- | --- | --- |
| `$schema` | string | optional | IDE hint — stripped before validation. |
| `extends` | string | optional | Relative path to parent variant JSON. See [`variants.md`](variants.md). |
| `variant` | object | ✅ | Variant metadata (name, description, version). |
| `base_image` | object | ✅ | Upstream `.img.xz` URL + SHA-256 + arch. |
| `targets` | array[enum] | ✅ | Hardware targets: `rpi4`, `rpi5`, `cm4`, `cm5`. (Pi Zero 2 W dropped — 512 MB RAM is insufficient for Docker + Portainer.) |
| `hostname` | string | ✅ | DNS-compatible hostname (lowercase, `[a-z0-9-]`). |
| `locale` | object | — | Timezone, keyboard, locale. |
| `users` | array | ✅ | One or more accounts. |
| `remove_users` | array | — | Users to delete (e.g. `["pi"]`). |
| `root` | object | — | SSH and `su` policy. |
| `ssh` | object | — | `{ enabled: true }` — enables ssh.service. |
| `banner` | object | — | Pre- and post-login banners (see below). |
| `packages` | array | — | APT packages to install. Concatenated with parent. |
| `network` | object | — | `ethernet` + `wifi` configuration. |
| `boot_config` | object | — | `/boot/firmware/config.txt` additions. |
| `can` | object | — | SocketCAN interfaces (when a CAN HAT is present). |
| `docker` | object | — | Docker CE install + daemon.json. |
| `portainer` | object | — | Portainer CE systemd service. |
| `unattended_upgrades` | object | — | Auto-updates with maintenance + reboot windows. |

---

## 🔑 Environment variable references

Any string value may contain `${VAR}` or `${VAR:-default}`:

```json
"password": "${ADMIN_PASSWORD:-12345678}",
"psk":      "${WIFI_PSK}"
```

Resolution is single-pass, case-sensitive, and happens **before** schema
validation (so env values must satisfy the schema's constraints).

| Form | Behavior |
| --- | --- |
| `${VAR}` | Required. Missing value → `KeyError`, build fails. |
| `${VAR:-default}` | Optional. Uses default when `VAR` is unset or empty. |

### Passthrough names

Two identifiers are **not** resolved — they pass through verbatim because
downstream tools use the same syntax:

- `${distro_id}`, `${distro_codename}` — substituted by unattended-upgrades
  / APT at runtime.

The resolver's skip list lives at the top of [`scripts/generate.py`](../scripts/generate.py).

### CI precedence

In GitHub Actions the secrets `ADMIN_PASSWORD` and `WIFI_PSK` are injected
as env vars; they override the `${VAR:-default}` fallback when set.

---

## 🧑 `users[]`

```json
{
  "name": "admin",
  "password": "${ADMIN_PASSWORD:-12345678}",
  "groups": ["sudo", "docker"],
  "shell": "/bin/bash",
  "sudo_nopasswd": true,
  "ssh_authorized_keys": ["ssh-ed25519 AAAA... admin@workstation"]
}
```

- `name` acts as the merge key when `extends` combines `users` arrays.
- `sudo_nopasswd: true` writes `/etc/sudoers.d/010-bgrpiimage-<name>` with
  `NOPASSWD:ALL`.
- `ssh_authorized_keys` is optional; listed keys go into
  `/home/<name>/.ssh/authorized_keys` with mode 600.

---

## 🔒 `root`

```json
{
  "su_nopasswd_users": ["admin"],
  "ssh_password_auth": true,
  "ssh_permit_root_login": false
}
```

- `su_nopasswd_users` → added to the `wheel` group and `pam_wheel.so trust`
  is installed so listed users can `su` / `sudo su -` without a password.
- `ssh_password_auth` and `ssh_permit_root_login` are written to
  `/etc/ssh/sshd_config.d/10-bgrpiimage.conf`.

---

## 🌐 `network.ethernet` / `network.wifi`

Each interface entry:

```json
{
  "interface": "eth0",
  "mode": "dhcp",            // or "static" / "disabled"
  "ipv6": true,
  "address": "192.168.1.10", // static only
  "prefix": 24,
  "gateway": "192.168.1.1",
  "dns": ["1.1.1.1", "2606:4700:4700::1111"]
}
```

`wifi` additionally takes:

```json
{
  "country": "DE",
  "networks": [
    { "ssid": "IOT @ BAUER-GROUP", "psk": "${WIFI_PSK:-12345678}",
      "priority": 10, "hidden": false }
  ]
}
```

`systemd-networkd` replaces `NetworkManager` / `dhcpcd` at build time — one
unit per interface. `wpa_supplicant@wlan0` is enabled automatically.

---

## 🔧 `boot_config`

Everything written ends up between fenced markers in
`/boot/firmware/config.txt`:

```text
# >>> bgrpiimage AUTO-GENERATED >>>

dtparam=spi=on
dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=25

# <<< bgrpiimage AUTO-GENERATED <<<
```

| Key | Effect |
| --- | --- |
| `enable_i2c: true` | `dtparam=i2c_arm=on` |
| `enable_spi: true` | `dtparam=spi=on` |
| `enable_i2s: true` | `dtparam=i2s=on` |
| `enable_uart: true` | `enable_uart=1` |
| `disable_bluetooth` | `dtoverlay=disable-bt` |
| `disable_wifi` | `dtoverlay=disable-wifi` |
| `dtoverlays[]` | `dtoverlay=<name>[,k=v,k=v]` per entry |
| `extra_lines[]` | Raw lines appended verbatim |

`dtoverlays` is an array of `{name, params}` objects — merged **by name**
when a child variant extends a parent.

---

## 🚌 `can`

```json
{
  "interfaces": [
    { "name": "can0", "bitrate": 500000, "auto_up": true, "txqueuelen": 65535 },
    { "name": "can1", "bitrate": 500000, "auto_up": true, "txqueuelen": 65535 }
  ]
}
```

Writes `/etc/systemd/network/40-can<N>.network`. `can-utils` is added to the
package list automatically.

---

## 🐳 `docker`

```json
{
  "enabled": true,
  "daemon": { "bip": "10.10.0.1/17", "ipv6": true, ... },
  "sysctl": { "vm.max_map_count": 4194304 },
  "networks": [ ... ]    // optional; docker network create on first boot
}
```

The `daemon` object is written verbatim to `/etc/docker/daemon.json`, so any
Docker daemon setting is allowed.

`networks[]` entries are materialised via a `bgrpiimage-docker-networks.service`
that runs once on first boot and marks itself done via a sentinel file.

---

## 🎛 `portainer`

```json
{
  "enabled": true,
  "edition": "ce",                // "ce" | "ee"
  "bind": "0.0.0.0",              // or 127.0.0.1 for loopback-only
  "image": "portainer/portainer-ce:latest",
  "ports": { "edge": 8000, "http": 9000, "https": 9443 },
  "auto_start": true
}
```

Installed **Docker-native** with `restart: unless-stopped` — the Docker
daemon brings the container back up on every boot. We only ship:

- `/etc/bgrpiimage/portainer/docker-compose.yml` (declarative config)
- `bgrpiimage-portainer-install.service` (oneshot, first-boot only)

The oneshot runs `docker compose up -d` once, drops a sentinel in
`/var/lib/bgrpiimage/portainer.installed` and then stays out of the way.
After first boot, Docker itself handles the lifecycle — `systemctl status`
is irrelevant for Portainer.

Update / reconfigure workflow:

```bash
sudo vim /etc/bgrpiimage/portainer/docker-compose.yml    # edit
sudo docker compose -f /etc/bgrpiimage/portainer/docker-compose.yml pull
sudo docker compose -f /etc/bgrpiimage/portainer/docker-compose.yml up -d
```

---

## 🔄 `unattended_upgrades`

```json
{
  "enabled": true,
  "allowed_origins": [
    "origin=Debian,codename=${distro_codename},label=Debian",
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security"
  ],
  "package_blocklist": [],
  "remove_unused_dependencies": true,
  "schedule": {
    "start": "02:00",        // download + install window start (HH:MM)
    "end":   "04:00",        //                             end
    "persistent": true       // run on next boot if missed
  },
  "auto_reboot": {
    "enabled": true,
    "if_required_only": true, // skip if /var/run/reboot-required absent
    "window": { "start": "03:00", "end": "05:00" }
  },
  "mail": { "address": "", "on_error_only": true }
}
```

See [`banner-and-updates.md`](banner-and-updates.md) for the full reboot
decision tree.

---

## 🖼️ `banner`

```json
{
  "enabled": true,
  "pre_login_note": "Authorised users only. All access is logged."
}
```

Generates three files:

- `/etc/issue` — console pre-login (getty expands `\n`, `\4`, `\6` live)
- `/etc/issue.net` — SSH pre-login (static, referenced via sshd `Banner` directive)
- `/etc/update-motd.d/10-bgrpiimage` — dynamic post-login MOTD

Output preview: [`banner-and-updates.md`](banner-and-updates.md).

---

## 🧪 Validating your config

```bash
# dry-run: schema check + env resolution + merge (no file writes)

python scripts/generate.py config/variants/your-variant.json --dry-run

# raw JSON of the fully resolved config (for piping into jq)

python scripts/generate.py config/variants/your-variant.json --json

# full render: writes files into src/

python scripts/generate.py config/variants/your-variant.json
```

Or via the tools container: `./tools/run.sh validate your-variant`.
