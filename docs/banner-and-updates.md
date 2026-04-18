# 🖼️ Banner + 🔄 unattended updates

Two user-visible operational features of every image. Both are configured in
the JSON and toggled by `banner.enabled` / `unattended_upgrades.enabled`.

---

## 🖼️ Login banner

Three distinct surfaces, three mechanisms:

| Surface | File | Rendered by | Content |
| --- | --- | --- | --- |
| Console (HDMI / tty) **pre-login** | `/etc/issue` | getty (expands `\n`, `\4`, `\6`, `\s`, `\r`, `\m`) | Variant, version, live hostname, IPv4/IPv6 of `eth0` + `wlan0` |
| SSH **pre-login** | `/etc/issue.net` + `sshd_config.d` `Banner` directive | sshd (reads raw, no escape expansion) | Variant, version, description, legal note |
| All sessions **post-login** | `/etc/update-motd.d/10-bgrpiimage` (executable) | `pam_motd.so` on login | Fully dynamic — see below |

### Post-login MOTD preview

```text
====================================================================
  bgRPIImage  canbus-plattform  v0.1.0
  BAUER GROUP CANbus plattform - base image + Waveshare 17912 ...
  host: bg-canbus                 kernel: 6.6.x-v8+
  model: Raspberry Pi Compute Module 4 Rev 1.0
  uptime: up 2 days, 4 hours
====================================================================
  eth0    UP     v4: 10.0.0.42/24
                 v6: 2001:db8::42/64
  wlan0   UP     v4: 10.0.1.50/24
  can0    UP     500 kbit/s
  can1    UP     500 kbit/s
====================================================================
  ssh: active   docker: active (7 running)   unattended-upgrades: active
  reboot pending (triggered by: linux-image-6.6.x libc6)    ← only if pending
====================================================================
```
Source: [`scripts/generate.py`](../scripts/generate.py) → `_MOTD_SCRIPT`.

### Why three different layers?

- **Console**: getty is the only thing running before login on a physical
  monitor. It expands `\n`, `\4`, `\6` itself — no need for our code to
  re-render issue on boot.
- **SSH pre-login**: sshd reads `/etc/issue.net` raw; no escape expansion.
  Anything dynamic would require a sshd `ForceCommand` trick, which we
  deliberately avoid.
- **MOTD**: fires after auth, so it can run arbitrary commands (`ip`,
  `systemctl`, `docker ps`). Always fresh, always accurate.

### Release metadata sourced by the MOTD

`/etc/bgrpiimage-release` is written at image build time:

```sh
BGRPIIMAGE_DIST="bgrpiimage"
BGRPIIMAGE_VARIANT="canbus-plattform"
BGRPIIMAGE_VERSION="0.1.0"
BGRPIIMAGE_DESCRIPTION="BAUER GROUP CANbus plattform - ..."
```
Any future ops tooling (Ansible facts, monitoring agents) can source this
instead of parsing `/etc/os-release`.

---

## 🔄 Unattended upgrades

### What's installed

- `unattended-upgrades`, `apt-listchanges` packages
- `/etc/apt/apt.conf.d/50unattended-upgrades` — origin patterns + blocklist
- `/etc/apt/apt.conf.d/20auto-upgrades` — enables periodic timer
- `apt-daily.timer` / `apt-daily-upgrade.timer` systemd drop-ins →
  shift download + install into the configured `schedule.{start, end}` window
  via `RandomizedDelaySec`
- `bgrpiimage-reboot-window.{service,timer}` → daily safety-net check
- `apt-daily-upgrade.service.d/override.conf` → event-driven
  `ExecStartPost=-/usr/local/sbin/bgrpiimage-reboot-window.sh`

### Reboot decision tree

```text
  apt-daily-upgrade.service succeeded
          │
          ▼  (ExecStartPost drop-in, event-driven)
  bgrpiimage-reboot-window.sh
          │
          ├── /var/run/reboot-required NOT present  ──▶ log "no reboot required", exit
          ├── current time outside window          ──▶ log "deferring", exit
          └── both conditions met                  ──▶ log triggering packages,
                                                        shutdown -r +1
```
Three guard layers make sure a reboot only happens when truly necessary:

1. **Package trigger** — `/var/run/reboot-required` is created **only** by
   package post-install hooks of things like `linux-image-*`, `libc6`, `systemd`.
   No package needing it → no flag → no reboot.
2. **Window** — hard `[HH:MM, HH:MM]` boundary. Rebooting the CAN gateway
   at 14:30 because a kernel update landed at lunch would be disruptive.
3. **Logging** — the triggering package list is pulled from
   `/var/run/reboot-required.pkgs` and written to `journald` + `wall`. Full
   audit trail for "why did my fleet reboot last night".

### Redundancy: timer + event trigger

Same script fires from two places:

| Trigger | When | Purpose |
| --- | --- | --- |
| `apt-daily-upgrade.service` `ExecStartPost=` | right after every update attempt | Fast reaction — reboots within seconds of a successful update if in window |
| `bgrpiimage-reboot-window.timer` | daily calendar event inside the reboot window | Safety net — catches devices that were offline or whose update service failed during the event |

If the device was off during the update window and boots later, the
persistent timer catches up next time it fires.

### Example config

```json
"unattended_upgrades": {
  "enabled": true,
  "allowed_origins": [
    "origin=Debian,codename=${distro_codename},label=Debian",
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security",
    "origin=Raspbian,codename=${distro_codename},label=Raspbian",
    "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation"
  ],
  "package_blocklist": [],
  "remove_unused_dependencies": true,
  "schedule":    { "start": "02:00", "end": "04:00", "persistent": true },
  "auto_reboot": { "enabled": true,
                   "if_required_only": true,
                   "window": { "start": "03:00", "end": "05:00" } },
  "mail": { "address": "", "on_error_only": true }
}
```
`${distro_codename}` is a **passthrough** — our env resolver leaves it alone
so APT can substitute it at runtime (with `trixie`, `bookworm`, …).

### Disabling reboots entirely

```json
"auto_reboot": { "enabled": false }
```
→ Reboot service/timer are not installed. `/var/run/reboot-required` will
still appear on the device after a kernel update, and the MOTD will surface
it, but no automatic reboot happens. Ops takes over.

### Why not the stock `Automatic-Reboot` directive?

`unattended-upgrades` supports `Unattended-Upgrade::Automatic-Reboot-Time`
but only as a **single timestamp**, not a window. We disable it
(`Automatic-Reboot "false";`) and implement a proper window via our own
systemd timer with `RandomizedDelaySec` so reboots spread across a fleet
instead of all hitting the same second.
