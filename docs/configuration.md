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
| `base_image` | object | ✅ | Upstream `.img.xz` URL + SHA-256 + arch. **Must be a Raspberry Pi OS Lite image** — the schema rejects a `raspios_arm64` / `raspios_full_arm64` URL, because the Desktop edition costs ~3 GiB of rootfs and overflows an 8 GB CM4 eMMC. Bump `url` and `sha256` together or the build aborts on the checksum check. |
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
| `boot_config` | object | — | `/boot/firmware/config.txt` low-level toggles and raw `dtoverlays`. |
| `camera` | object | — | CSI camera: `autodetect` + explicit sensor overlays. See [`hardware.md`](hardware.md). |
| `hdmi` | object | — | Per-output HDMI config: group, mode, rotation, audio forcing. |
| `display` | object | — | Console + DSI-LCD rotation. |
| `audio` | object | — | Onboard audio toggle + default ALSA sink. |
| `gpio` | object | — | `one_wire` (DS18B20 etc.). |
| `rtc` | object | — | I2C RTC HAT (DS3231 / PCF8523 / PCF85063) + `fake_hwclock` fallback. |
| `fan` | object | — | Active cooling (`gpio` / `pwm` / `emc2301`). |
| `leds` | object | — | Power + activity LED trigger (on/off/heartbeat/mmc0). |
| `overclock` | object | — | `arm_freq`, `gpu_freq`, `over_voltage`, `sdram_freq`. Requires `accept_warranty_void: true`. |
| `memory` | object | — | `gpu_mem` split + `cma` size. |
| `pcie` | object | — | Pi5 / CM4/5 PCIe slot (gen, NVMe boot). |
| `usb` | object | — | `max_usb_current` (Pi4 USB-C 3A). |
| `bootloader` | object | — | Pi5/CM5 EEPROM (boot order, wake-on-GPIO, power-off-on-halt). |
| `watchdog` | object | — | Hardware watchdog (`bcm2835-wdt`) with systemd kick. |
| `can` | object | — | SocketCAN interfaces (when a CAN HAT is present). |
| `docker` | object | — | Docker CE install + daemon.json. |
| `portainer` | object | — | Portainer CE systemd service. |
| `unattended_upgrades` | object | — | Auto-updates with maintenance + reboot windows. |

> Details, example snippets and caveats for all hardware blocks live in
> [`hardware.md`](hardware.md).

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
  `/home/<name>/.ssh/authorized_keys` with mode 600. Without it the image
  ships no `~/.ssh` at all.
- If the resolved password is a known default (`12345678`), the account is
  created with `chage -d 0` — it ships **expired**, and the first console or
  SSH login forces a change before granting a session. Raspberry Pi OS's own
  first-boot wizard is disabled at build time, so the console really does show
  a login prompt and this is the only thing that asks for a new password.
- The build also writes `/etc/bgrpiimage-default-password-active`, recording
  `<user>:<first 12 chars of the crypt hash>` **after** the accounts are
  created. The MOTD compares the live hash against it, so the warning clears
  itself the moment the credential is actually rotated. (It used to test
  `sp_lstchg == 0`, which could never be true by the time `pam_motd` runs —
  PAM's account phase has already forced the change.)
- `generate.py` also prints a `SECURITY:` warning at render time. Set
  `ADMIN_PASSWORD` to ship a real credential with no forced rotation.
- `remove_users` accounts are deleted **before** the new ones are created, so
  the first declared user takes UID 1000 rather than 1001.

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
    { "ssid": "MyNetwork", "psk": "${WIFI_PSK}",
      "priority": 10, "hidden": false }
  ]
}
```

> **WiFi ships disabled** (`network.wifi.mode: "disabled"`), and no image
> carries a default PSK. With `mode: "disabled"` neither `20-wlan.network` nor
> a `wpa_supplicant` config is generated, so `wlan0` stays **unmanaged** by
> networkd and cannot hold up `systemd-networkd-wait-online`. Set `mode` to
> `dhcp`/`static` and add `networks[]` to bake WiFi into an image, or enable it
> per device with `sudo bgrpiimage-setup wifi enable <SSID>`.
>
> `country` is still used even when WiFi is off: it becomes the
> `ieee80211_regdom` pinned in `/etc/modprobe.d/zz-bgrpiimage-rfkill.conf`.

`systemd-networkd` replaces `NetworkManager` / `dhcpcd` at build time — one
unit per interface. `wpa_supplicant@<iface>` is enabled for each generated
config.

Every generated `.network` also gets a `[Link] RequiredForOnline=`: `degraded`
(systemd's own default) for wired interfaces, and `no` for wireless **and for
CAN**. There is no config key for it. A link that cannot come up must never
gate `network-online.target`, because `docker.service` waits on that target and
the Portainer first-boot install waits on Docker — and a CAN interface with no
bus attached, or a wireless link that cannot associate, is a normal state, not
a fault.

---

## 🔧 `boot_config`

Everything written ends up between fenced markers in
`/boot/firmware/config.txt`:

```text
# >>> bgrpiimage AUTO-GENERATED >>>

[all]

core_freq_fixed=1
dtparam=spi=on
dtoverlay=mcp2515-can1,oscillator=16000000,interrupt=25,spimaxfrequency=8000000
dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=23,spimaxfrequency=8000000

# <<< bgrpiimage AUTO-GENERATED <<<
```

| Key | Effect |
| --- | --- |
| `core_freq_fixed: true` | `core_freq_fixed=1` — stops the core clock scaling (see below) |
| `enable_i2c: true` | `dtparam=i2c_arm=on` |
| `enable_spi: true` | `dtparam=spi=on` |
| `enable_i2s: true` | `dtparam=i2s=on` |
| `enable_uart: true` | `enable_uart=1` |
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
    { "name": "can0", "bitrate": 500000, "auto_up": true, "txqueuelen": 1024, "restart_ms": 100 },
    { "name": "can1", "bitrate": 500000, "auto_up": true, "txqueuelen": 1024, "restart_ms": 100 }
  ]
}
```

Writes two files per interface, because systemd splits ownership of them:

| File | Read by | Carries |
| ---- | ------- | ------- |
| `/etc/systemd/network/40-can<N>.network` | `systemd-networkd` | `[CAN] BitRate=`, `SamplePoint=`, `RestartSec=`, `RequiredForOnline=` |
| `/etc/systemd/network/70-can<N>.link` | `systemd-udevd` | `[Link] TransmitQueueLength=` |

`can-utils` is added to the package list automatically.

> **`TransmitQueueLength` is not a `.network` key.** Both file types have a
> section literally named `[Link]`, but with disjoint key sets — networkd parses
> the key, logs it as unknown, discards it and carries on, so the interface
> keeps the CAN core default of `10` while everything else in the file works.
> The `[Match]` keys differ too: `.network` matches on `Name=`, `.link` has no
> `Name=` and spells it `OriginalName=`.
>
> udev applies `.link` files only on a netdev *add* event, so `systemctl restart
> systemd-networkd` will not pick up a change — reboot, or use
> `bgrpiimage-setup can txqueuelen can0 <N>`, which writes the file *and* sets
> the live link. Check the result with `bgrpiimage-setup can status` (the `txq`
> column) or `ip -d link show can0`.

> **`restart_ms` is bus-off auto-recovery, and its unit is mandatory.** It
> renders as `[CAN] RestartSec=<n>ms`. systemd parses `RestartSec=` in
> *seconds* by default, so a bare `100` would mean 100 s — the generator always
> writes the `ms` suffix. Both the kernel and systemd default this to **off**,
> which is what `ip -details link show` reports as `restart-ms 0`: a controller
> that goes bus-off then stays there until someone cycles the link by hand. On
> the MCP2515 it is worse than a stalled recovery — the driver puts the chip to
> *sleep*, so it is physically off the bus. Set `restart_ms: 0` only if the
> application does its own bus-off handling; the key is then omitted entirely
> rather than written as `RestartSec=0`, which systemd would read as "leave the
> current value alone" rather than "off".

The renderer cross-checks this block against `boot_config.dtoverlays`: every
`can<N>` needs a matching `mcp2515-can<N>` overlay, and each overlay needs its
own `params.interrupt`. Both defaults would otherwise land on GPIO 25. See
[`hardware.md`](hardware.md#-can-waveshare-17912-dual-mcp2515) for why the
emitted overlay order is reversed.

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
  "image": "portainer/portainer-ce:2.45.0",
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
