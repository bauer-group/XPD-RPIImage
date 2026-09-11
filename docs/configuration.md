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
| `targets` | array[enum] | ✅ | Hardware targets: `rpi4`, `rpi5`, `cm4`, `cm5`. (Pi Zero 2 W dropped — 512 MB RAM is insufficient for Podman + Portainer.) |
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
| `podman` | object | — | Podman runtime, Docker CLI emulation, container networking (default). |
| `docker` | object | — | Docker CE install + daemon.json (supported, non-default). |
| `portainer` | object | — | Portainer CE, deployed as Quadlet units under Podman or compose under Docker. |
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
gate `network-online.target`. Under Podman (the default) there is no
`docker.service`-shaped dependency to worry about — `podman.socket` is
socket-activated and Portainer's Quadlet unit orders itself `After=
podman.socket`, not `network-online.target`. Under the non-default Docker
runtime, `docker.service` does wait on that target and the Portainer
first-boot install waits on Docker in turn, so both queue behind it. Either
way, a CAN interface with no bus attached, or a wireless link that cannot
associate, is a normal state, not a fault — so it must not hold up boot.

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

`dtoverlays` is an array of `{name, id?, params}` objects — merged **by `id` when
present, otherwise by `name`**.

> **A boolean param renders as a bare token, not `k=true`.** The firmware treats
> overlay booleans as present-is-true / absent-is-false, which is why upstream
> writes `dtoverlay=mcp251xfd,spi0-0,interrupt=25`. So `"spi0-0": true` emits
> `spi0-0`, and `false` omits the key entirely — writing `k=false` would still
> make the parameter *present*.

The `id` key is what makes two entries of the *same* overlay survive the merge:

> **`id` exists for overlays loaded more than once.** `mcp2515` ships one overlay
> per channel (`mcp2515-can0`, `mcp2515-can1`), so `name` is a unique key. The
> MCP251XFD family ships **one** overlay for every channel and picks the chip
> with a `spi<n>-<m>` parameter — so a two-channel CAN FD HAT needs two entries
> both named `mcp251xfd`. Merged by name those collapse into a single overlay
> carrying *both* chip selects, with `interrupt` resolved last-wins: one CAN
> interface instead of two, bound to the other channel's INT GPIO. `id` is a
> merge key only and is never rendered.

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
| `/etc/systemd/network/40-can<N>.network` | `systemd-networkd` | `[CAN] BitRate=`, `SamplePoint=`, `FDMode=`, `DataBitRate=`, `RestartSec=`, `RequiredForOnline=` |
| `/etc/systemd/network/70-can<N>.link` | `systemd-udevd` | `[Link] TransmitQueueLength=` |

`can-utils` is added to the package list automatically.

### CAN FD

Adding `dbitrate` turns the interface into a CAN FD interface — the arbitration
phase keeps running at `bitrate`, the payload is sent at `dbitrate`:

```json
{ "name": "can0", "bitrate": 500000, "dbitrate": 2000000, "restart_ms": 100 }
```

```ini
[CAN]
BitRate=500000
FDMode=yes
DataBitRate=2000000
RestartSec=100ms
```

> **`FDMode=yes` and `DataBitRate=` are emitted together or not at all — and
> that is correctness, not tidiness.** `can_validate()` in
> `drivers/net/can/dev/netlink.c` refuses `IFLA_CAN_DATA_BITTIMING` without
> `CAN_CTRLMODE_FD` (and the reverse) with `-EOPNOTSUPP`, and that error rejects
> the **whole** `RTM_NEWLINK` message. So a `DataBitRate=` written without
> `FDMode=yes` does not merely skip the data phase — `BitRate=`, `SamplePoint=`
> and `RestartSec=` travel in the same message and are lost with it, leaving the
> link on whatever the driver powered up with. systemd will not catch it either:
> it has no coupling between the two keys, so the only trace is a netlink error
> in the journal.

The controller has to be able to do it, too:

> **`dbitrate` needs an FD controller.** The MCP2515 is Classic-CAN only, so
> `dbitrate` on a `mcp2515-*` board is refused at build time rather than
> producing an interface that fails to configure at boot.

`data_sample_point` is available but **should normally stay unset**, for the same
reason `sample_point` does: it describes the *bus*, which every node has to agree
on, not the board. Unset, `can_update_sample_point()` picks per bitrate — 75%
above 800 kbit/s, 80% above 500 kbit/s, 87.5% at or below. A 500 kbit/s
arbitration phase with a 2 Mbit/s data phase therefore lands on 87.5% / 75% with
nothing configured at all.

`fd_non_iso` selects the pre-standard Bosch frame format and exists only for
first-generation FD silicon. The two formats do **not** interoperate — a non-ISO
node on an ISO bus produces CRC errors, not silence.

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

`sample_point` is a property of the physical bus, not of one board, and every
node has to agree on it — see
[`hardware.md`](hardware.md#sample-point) for why there is deliberately no
`bgrpiimage-setup can sample-point` command and why the kernel-computed default
of 87.5% at 500 kbit/s is almost always the right answer.

> ⚠️ **The JSON field is in percent (`87.5`), and does not match what `ip`
> prints.** `ip -details link show` reports `sample-point 0.875` — the same
> value as a fraction. Writing `0.875` into the config is refused by schema
> validation, and that lower bound of `50` earns its place: `0.875` would
> otherwise render as `SamplePoint=0.9%`, which systemd accepts as 9 permille
> and the kernel then refuses outright, so the unit would boot with a CAN link
> that never came up. Failing in `make validate` beats failing in the field.

The renderer cross-checks this block against `boot_config.dtoverlays`. For
MCP2515 boards: every `can<N>` needs a matching `mcp2515-can<N>` overlay, and
each overlay needs its own `params.interrupt` — both defaults would otherwise
land on GPIO 25. See
[`hardware.md`](hardware.md#-can-waveshare-17912-dual-mcp2515) for why the
emitted overlay order is reversed.

For MCP251XFD boards the overlay carries no interface name, so the checks are
structural instead: one `mcp251xfd` overlay per declared interface, exactly one
`spi<n>-<m>` chip select each (and a real one — SPI0 has no third chip select),
a distinct `params.interrupt` each, and an `spi1-<N>cs`/`spi2-<N>cs` overlay
listed **before** any entry that uses that bus. A `speed` above the clamp the
driver applies for the given `oscillator` is *noted* rather than refused — the
driver's `min()` has already made it harmless, and upstream's own overlay
default exceeds it. Writing the MCP2515 spelling
`spimaxfrequency` is refused outright — `dtoverlay` drops parameter names it does
not recognise, so it would cost the setting and say nothing. See
[`hardware.md`](hardware.md#-can-fd-waveshare-17075-dual-mcp2518fd).

---

## 🦭 `podman`

Default container runtime — daemonless, rootful system service. Docker CLI
emulation means `docker ...` keeps working unchanged for anyone used to it;
under the hood every call goes to Podman.

```json
{
  "enabled": true,
  "docker_emulation": true,
  "sysctl": { "vm.max_map_count": 4194304 },
  "network": {
    "default_subnet": "10.10.0.0/17",
    "default_subnet_pools": [
      { "base": "10.10.128.0/17", "size": 24 }
    ],
    "ipv6": true,
    "subnet_v6": "fdff:0::/64",
    "firewall_driver": "nftables"
  },
  "journald": {
    "system_max_use": "200M",
    "system_max_file_size": "20M"
  },
  "auto_update": {
    "enabled": true,
    "schedule": {
      "start": "05:30",
      "randomized_delay_minutes": 30,
      "persistent": true
    }
  }
}
```

- `enabled` — installs `podman`, `podman-docker`, `containers-common`,
  `netavark`, `aardvark-dns`, `nftables`, `uidmap`, `catatonit`, and enables
  `podman.socket` + `podman-restart.service` (the latter brings back
  operator-created `--restart=always` containers after a reboot; Portainer's
  own Quadlet unit doesn't need it — it's `WantedBy=multi-user.target` and
  systemd starts it directly). Mutually exclusive with `docker.enabled` — a
  variant that sets both fails validation, because the two runtimes both own
  `/usr/bin/docker` and the container storage.
- `docker_emulation` — writes `/etc/containers/nodocker`, which is
  presence-only: it suppresses the "Emulate Docker CLI using podman" notice
  `podman-docker` otherwise prints on every `docker(1)` call. It does not
  toggle emulation itself off — the `docker` shim is always installed once
  Podman is `enabled`.
- `sysctl` — written to `/etc/sysctl.d/98-podman.conf`. Carries
  `vm.max_map_count`, which moved here from `docker.sysctl` when Podman
  became the default — it's a runtime-agnostic setting (any container
  workload that mmaps heavily needs it), not a Docker-specific one.
- `network` — feeds two generated files:
  - `default_subnet` / `default_subnet_pools` → the `[network]` section of
    `/etc/containers/containers.conf` (the IPv4 half of the address plan).
  - `ipv6` / `subnet_v6` → `/etc/containers/networks/podman.json`, netavark's
    definition of the built-in default network. IPv6 can't be declared in
    `containers.conf` — the network definition file is the only place it's
    settable.
  - `firewall_driver` — one of `iptables`, `nftables`, `none`, `firewalld`.
    Netavark's own compiled-in default is `nftables`, which is why this
    image installs the `nftables` package explicitly rather than leaving it
    an implicit `Recommends` — every install in this project runs with
    `--no-install-recommends`.
- `journald` — `system_max_use` / `system_max_file_size`, written to
  `/etc/systemd/journald.conf.d/99-bgrpiimage-containers.conf`. Podman logs
  containers to journald (Docker's `json-file` driver capped this image's
  container logs at 10m × 3 instead), so this cap now bounds the SD card's
  write/wear budget in place of a per-container log file limit.
- `auto_update` — `enabled` turns on `podman-auto-update.timer` (the
  service itself is left disabled; it's `WantedBy=default.target` and would
  otherwise fire on every boot). `schedule.start` /
  `randomized_delay_minutes` become a `[Timer]` drop-in that clears and
  replaces the stock `OnCalendar=`, so the daily default doesn't also fire
  alongside it. `schedule.persistent` catches up a run that was missed while
  the device was off. Only containers carrying the
  `io.containers.autoupdate=registry` label are affected — see
  `portainer.auto_update` below.

**Cross-field guards** (enforced by `scripts/generate.py`, not just the JSON
Schema):

- `docker.enabled` and `podman.enabled` cannot both be `true`.
- `portainer.auto_update: true` requires `podman.enabled: true` — the
  mechanism does nothing under Docker.
- `portainer.auto_update: true` requires `podman.auto_update.enabled: true`
  — without the timer, the `AutoUpdate=registry` label is inert.
- `portainer.auto_update: true` refuses a digest-pinned `portainer.image`
  (an `@sha256:...` reference can never resolve to a newer tag).
- `podman.auto_update.schedule` must not overlap the `unattended_upgrades`
  maintenance window (02:00-04:00 by default) or the `auto_reboot` window
  (03:00-05:00) — a scripted reboot mid-Portainer-database-migration is
  unrecoverable.

---

## 🐳 `docker`

Supported, **non-default** container runtime — set `docker.enabled: true`
(and leave `podman.enabled: false`) to use it instead of Podman.

```json
{
  "enabled": false,
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
  "image": "docker.io/portainer/portainer-ce:lts",
  "ports": { "edge": 8000, "http": 9000, "https": 9443 },
  "auto_start": true,
  "auto_update": true,
  "backup_before_update": { "enabled": true, "keep": 5 }
}
```

Deployment shape depends on the runtime:

- **Podman (default):** two Quadlet files at `/etc/containers/systemd/` —
  `portainer.image` (pulls `image`) and `portainer.container` (the unit
  itself; `Requires=`/`After=podman.socket`). systemd's Quadlet generator
  turns these into a real `portainer.service` at boot and applies its
  `[Install]` section itself — there is **no** `systemctl enable` step, no
  compose file, no first-boot oneshot, and no sentinel file.
- **Docker (non-default):** installed Docker-native with
  `restart: unless-stopped`. We ship
  `/etc/bgrpiimage/portainer/docker-compose.yml` (declarative config) and
  `bgrpiimage-portainer-install.service` (oneshot, first-boot only), which
  runs `docker compose up -d` once, drops a sentinel in
  `/var/lib/bgrpiimage/portainer.installed`, and stays out of the way. After
  that, Docker itself handles the lifecycle.

Operator workflow under Podman:

```bash
systemctl status portainer.service           # quadlet-generated unit
sudo systemctl restart portainer.service
sudo podman auto-update --dry-run             # what would change, no action
sudo podman auto-update                       # apply now, all labeled containers
```

- `auto_update` (boolean) — labels the Portainer container
  `io.containers.autoupdate=registry`, so `podman-auto-update.timer` picks
  it up once fired. Requires `podman.enabled` and
  `podman.auto_update.enabled`, and refuses a digest-pinned `image` — see
  the guards under the `podman` section above. Meaningless under Docker;
  update it there via the compose pull/up cycle instead.
- `backup_before_update.enabled` / `.keep` — when `auto_update` is on,
  `/usr/local/sbin/bgrpiimage-portainer-backup` runs as `ExecStartPre` of
  `podman-auto-update.service` on **every** timer fire (not only when an
  update is actually available), exporting the `portainer_data` volume to
  a timestamped archive under `/var/backups/bgrpiimage/` and pruning to the
  last `keep` archives. This exists because Portainer migrates its database
  one-way on startup — a `portainer.db` written by a newer version won't
  open on an older one, so Podman's own update mechanism can't undo a bad
  Portainer update by itself.

Under Docker, update / reconfigure workflow is unchanged:

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
