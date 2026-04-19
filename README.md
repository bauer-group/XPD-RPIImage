# 📦 BAUER GROUP custom Raspberry Pi OS base images

Declarative, reproducible, CI-built Raspberry Pi OS images for production and
development devices. Config lives in JSON, generation is driven by Python,
actual image baking runs on top of [CustomPiOS][custompios].

Supported hardware:

| Target | Status |
| --- | --- |
| Raspberry Pi 4 | ✅ |
| Raspberry Pi 5 | ✅ |
| Compute Module 4 (CM4) | ✅ |
| Compute Module 5 (CM5) | ✅ |
| Raspberry Pi Zero 2 W | ❌ not supported — 512 MB RAM is insufficient for Docker CE + Portainer + base services |

Base OS: Raspberry Pi OS arm64 (trixie, 2026-04-13).

---

## ✨ Features

- **Declarative config** in JSON, validated against a strict schema.
- **Variant composition** via `extends` — a child variant deep-merges onto a
  base, arrays of `{name: ...}` records merge by name.
- **Env-var resolver** for secrets (`${VAR}` / `${VAR:-default}`), fail-fast
  on missing required values.
- **Dockerised dev/build runtime** — no host Python/qemu dependencies required;
  Linux · macOS · Windows (WSL / CMD / PowerShell).
- **CI-ready** image builds on GitHub Actions with matrix over all variants,
  artifact + release asset output, full metadata summary per run.
- **Baked-in**:
  - SSH enabled with hardened `sshd_config.d` (no root login, no challenge-response)
  - Docker CE + compose plugin, IPv6 NAT, sensible daemon.json
  - Portainer CE via docker-compose (`restart: unless-stopped`), installed
    by a first-boot oneshot — Docker daemon handles lifecycle from then on
  - Unattended upgrades with **configurable maintenance + reboot windows**,
    event-driven via `apt-daily-upgrade.service` post-hook
  - Dynamic MOTD banner showing variant, version, kernel, all interfaces
    with IPv4/IPv6, CAN state + bitrate, service health, pending reboots
  - Admin user with sudo NOPASSWD, `su` without password via `pam_wheel`

---

## 🚀 Quick start

### Option 1 — dockerised tools (recommended, zero host deps)

```bash
# Linux / macOS / WSL

./tools/run.sh validate                    # validate every variant JSON
./tools/run.sh render canbus-plattform     # generate module artifacts
./tools/run.sh build  canbus-plattform     # full image build (privileged)

# Windows CMD

tools\run.cmd build canbus-plattform

# Windows PowerShell

.\tools\run.ps1 build -Variant canbus-plattform
```

See [`docs/tools-container.md`](docs/tools-container.md) for launcher reference.

### Option 2 — local (needs Python 3.14 + Docker)

```bash
cp .env.example .env

# edit .env - set ADMIN_PASSWORD and WIFI_PSK

make deps                                  # pip install requirements
make validate                              # schema-check all variants
make build VARIANT=canbus-plattform        # build the image
```

Output lands in `dist/bgrpiimage-<variant>-v<version>.img.xz`.

### Option 3 — GitHub Actions

Push to `main` or open a PR → automatic build with SHA-stamped artifact
(see [`docs/ci-cd.md`](docs/ci-cd.md)). Tag with `v*.*.*` → automatic release
with permanent download assets.

---

## 📦 Variants

| Variant | Description | Hostname | Extras |
| --- | --- | --- | --- |
| [`base`](config/variants/base.json) | Generic Raspberry Pi image, Docker-ready, no application-specific hardware. | `bg-rpi` | — |
| [`canbus-plattform`](config/variants/canbus-plattform.json) | Base + Waveshare 17912 dual isolated CAN HAT (MCP2515 on SPI). | `bg-canbus` | `can0` + `can1` at 500 kbit/s, `can-utils`, dialout/gpio/i2c/spi groups |

Adding a new variant is a 10-line JSON file — see
[`docs/variants.md`](docs/variants.md).

---

## 🧱 Architecture

```text
  ┌─────────────────────┐     ┌───────────────────┐     ┌────────────────────┐
  │ config/variants/*.json │──▶│ scripts/generate.py │──▶│ src/modules/*/files/  │
  │  (declarative, JSON)  │     │  (validate + merge │     │  _generated/ (inputs │
  └─────────────────────┘     │   + env resolve)   │     │   for CustomPiOS)    │
                              └───────────────────┘     └────────────┬───────┘
                                                                      │
                                                                      ▼
                                                ┌─────────────────────────┐
                                                │ guysoft/custompios       │
                                                │ (privileged build in    │
                                                │  docker or GH runner)    │
                                                └───────────┬─────────────┘
                                                            │
                                                            ▼
                                            ┌──────────────────────────┐
                                            │ dist/bgrpiimage-…img.xz  │
                                            └──────────────────────────┘
```

More detail: [`docs/architecture.md`](docs/architecture.md).

---

## 📚 Documentation

| Topic | File |
| --- | --- |
| Architecture + build pipeline | [docs/architecture.md](docs/architecture.md) |
| JSON config reference + env resolver | [docs/configuration.md](docs/configuration.md) |
| **Hardware reference** (camera, HDMI, RTC, fan, watchdog, overclock, …) | [docs/hardware.md](docs/hardware.md) |
| Creating a new variant (`extends` chain) | [docs/variants.md](docs/variants.md) |
| **Post-flash setup (password · WiFi · IP)** | [docs/post-flash-setup.md](docs/post-flash-setup.md) |
| Dockerised tools container | [docs/tools-container.md](docs/tools-container.md) |
| GitHub Actions CI/CD | [docs/ci-cd.md](docs/ci-cd.md) |
| Login banner + unattended updates | [docs/banner-and-updates.md](docs/banner-and-updates.md) |

---

## 🔐 Secrets & defaults

> ⚠️ **Default credentials shipped by this image:**
>
> - `admin` user password → `12345678`
> - WiFi PSK for `IOT @ BAUER-GROUP` → `12345678`
>
> These are **demo credentials** baked in via `${VAR:-default}` references.
> A fresh flash of an untouched image is only safe inside an isolated lab.
> On first boot the login banner screams about it and the MOTD keeps
> reminding you until you rotate the admin password.

### Change credentials at build time (preferred for production)

Bake real values into the image during the build:

1. Copy `.env.example` → `.env`, set real values.
2. Rebuild: `./tools/run.sh build <variant> --env-file ./.env`.
3. Never commit `.env` (already gitignored).

In CI, set `ADMIN_PASSWORD` and `WIFI_PSK` as repository secrets — the
workflow passes them through automatically.

### Change credentials / network on the device (post-flash)

Every image ships `/usr/local/sbin/bgrpiimage-setup` — a one-stop helper
for the routine post-flash changes:

```bash
sudo bgrpiimage-setup password                       # rotate admin pw
sudo bgrpiimage-setup password alice                 # rotate another user
sudo bgrpiimage-setup wifi "MyNet" "s3cret" DE       # join a WiFi
sudo bgrpiimage-setup wifi --disable                 # tear down wlan0
sudo bgrpiimage-setup ip eth0 dhcp                   # back to DHCP
sudo bgrpiimage-setup ip eth0 static 10.0.0.5/24 10.0.0.1 1.1.1.1
sudo bgrpiimage-setup status                         # overview
```

All IP changes land as `/etc/systemd/network/50-bgrpiimage-<iface>.network`
drop-ins (our file prefix wins over the image-defaults), so they survive
upgrades and are trivial to revert by deleting the drop-in.

See [`docs/post-flash-setup.md`](docs/post-flash-setup.md) for the full
subcommand reference.

---

## 🛠️ Project layout

```text
.
├── config/
│   ├── schema.json                        # JSON schema for variant config
│   └── variants/
│       ├── base.json                      # generic base variant
│       └── canbus-plattform.json          # extends base + CAN additions
├── scripts/
│   ├── generate.py                        # JSON → CustomPiOS module files
│   ├── bootstrap.sh                       # clones CustomPiOS into ./CustomPiOS
│   ├── build.sh                           # full image build (privileged docker)
│   └── requirements.txt
├── src/                                   # CustomPiOS distro
│   ├── config                             # distro-level config
│   ├── image/config                       # image-level (base URL etc.)
│   ├── modules/                           # bgrpiimage-{base,users,network,boot,
│   │                                      #              can,docker,portainer,
│   │                                      #              unattended-upgrades}
│   └── variants/                          # per-variant shell config (generated)
├── tools/                                 # portable dev/build runtime
│   ├── Dockerfile
│   ├── run.sh / run.cmd / run.ps1
├── .github/workflows/build.yml            # CI pipeline
├── Makefile                               # local convenience targets
└── docs/
```

---

## 📜 License

MIT — see [LICENSE](LICENSE).

[custompios]: https://github.com/guysoft/CustomPiOS
