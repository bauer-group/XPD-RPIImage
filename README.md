# 📦 XPD-RPIImage

> BAUER GROUP custom Raspberry Pi OS base images for embedded workloads.

Declarative, reproducible, CI-built Raspberry Pi OS images for production and
development devices. Config lives in JSON, generation is driven by Python,
actual image baking runs on top of [CustomPiOS][custompios].

Supported hardware:

| Target | Status |
|---|---|
| Raspberry Pi Zero 2 W | ✅ |
| Raspberry Pi 4 | ✅ |
| Raspberry Pi 5 | ✅ |
| Compute Module 4 (CM4) | ✅ |
| Compute Module 5 (CM5) | ✅ |

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
  - Portainer CE systemd unit (auto-starts on first boot)
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

Output lands in `dist/bgRPIImage-<variant>-v<version>.img.xz`.

### Option 3 — GitHub Actions

Push to `main` or open a PR → automatic build with SHA-stamped artifact
(see [`docs/ci-cd.md`](docs/ci-cd.md)). Tag with `v*.*.*` → automatic release
with permanent download assets.

---

## 📦 Variants

| Variant | Description | Hostname | Extras |
|---|---|---|---|
| [`base`](config/variants/base.json) | Generic Raspberry Pi image, Docker-ready, no application-specific hardware. | `bg-rpi` | — |
| [`canbus-plattform`](config/variants/canbus-plattform.json) | Base + Waveshare 17912 dual isolated CAN HAT (MCP2515 on SPI). | `bg-canbus` | `can0` + `can1` at 500 kbit/s, `can-utils`, dialout/gpio/i2c/spi groups |

Adding a new variant is a 10-line JSON file — see
[`docs/variants.md`](docs/variants.md).

---

## 🧱 Architecture

```
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
                                            │ dist/bgRPIImage-…img.xz  │
                                            └──────────────────────────┘
```

More detail: [`docs/architecture.md`](docs/architecture.md).

---

## 📚 Documentation

| Topic | File |
|---|---|
| Architecture + build pipeline | [docs/architecture.md](docs/architecture.md) |
| JSON config reference + env resolver | [docs/configuration.md](docs/configuration.md) |
| Creating a new variant (`extends` chain) | [docs/variants.md](docs/variants.md) |
| Dockerised tools container | [docs/tools-container.md](docs/tools-container.md) |
| GitHub Actions CI/CD | [docs/ci-cd.md](docs/ci-cd.md) |
| Login banner + unattended updates | [docs/banner-and-updates.md](docs/banner-and-updates.md) |

---

## 🔐 Secrets & defaults

The bundled JSON ships **demo credentials** (`ADMIN_PASSWORD=12345678`,
`WIFI_PSK=12345678`) as `${VAR:-default}` references. For anything beyond a
lab rebuild:

1. Copy `.env.example` → `.env`, set real values.
2. Rebuild: `./tools/run.sh build <variant> --env-file ./.env`.
3. Never commit `.env` (already gitignored).

In CI, set `ADMIN_PASSWORD` and `WIFI_PSK` as repository secrets — the
workflow passes them through automatically.

---

## 🛠️ Project layout

```
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
│   ├── modules/                           # bgRPIImage-{base,users,network,boot,
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
