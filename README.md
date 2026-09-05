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

Base OS: Raspberry Pi OS **Lite** arm64 (trixie, 2026-06-18) — headless, no
desktop. These are appliance images: SSH, Docker CE and Portainer, no GUI.
The Desktop edition is not interchangeable here — it adds ~3 GiB of rootfs and
pushes the image past what a nominally 8 GB CM4 eMMC can hold (see
[docs/flash.md](docs/flash.md#storage-requirements)).

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

## 💾 Flash an image in 30 seconds

You need **Raspberry Pi Imager v2.0.3 or later** — earlier versions don't
persist a custom repository between launches.

**One-click:**

[Open BAUER GROUP repository in Raspberry Pi Imager](rpi-imager://open?repo=https://bauer-group.github.io/XPD-RPIImage/rpi-imager.json)

Imager opens with our catalog pre-loaded and asks for confirmation. After
that, every future release shows up automatically — including **Compute
Module eMMC flashing** via the built-in `rpiboot`.

**Manual setup:**

1. Open **Raspberry Pi Imager → ⚙ Settings → Custom repository**
2. Paste `https://bauer-group.github.io/XPD-RPIImage/rpi-imager.json`
3. Close the dialog. Imager reloads the OS list automatically — our
   variants appear under **CHOOSE OS → BAUER GROUP**.

Landing page with direct downloads + full checksums:
<https://bauer-group.github.io/XPD-RPIImage/>

Full flashing guide (SD, USB-SSD, CM4/CM5 via rpiboot, balenaEtcher, manual
`dd`): [docs/flash.md](docs/flash.md).

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
make validate                              # schema-check every variant
make build VARIANT=canbus-plattform        # build the image

# .env is picked up automatically when it sits at the repo root.
# From elsewhere, pass it explicitly: make build ENV_FILE=path/to/.env
```

Output lands in `dist/bgrpiimage-<variant>-v<version>.img.xz`.

### Option 3 — GitHub Actions

Push to `main` or open a PR → automatic build with SHA-stamped artifact
(see [`docs/ci-cd.md`](docs/ci-cd.md)).

A conventional commit on `main` → semantic-release cuts `vX.Y.Z` and the
GitHub Release, then dispatches the image build on that tag so the `.img.xz`,
`.sha256` and `.manifest.json` assets are attached automatically.

The dispatch is a separate job using a PAT: the tag itself is pushed with
`GITHUB_TOKEN`, and GitHub never triggers a workflow from a `GITHUB_TOKEN`
event, so `build.yml`'s tag trigger alone would never fire. If the PAT is ever
missing, the release job fails loudly and the assets can be attached by hand:

```bash
gh workflow run build.yml --ref vX.Y.Z
```

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
  │ config/variants/*.json │──▶│ scripts/generate.py │──▶│ src/modules/*/filesystem/ │
  │  (declarative, JSON)  │     │  (validate + merge │     │  root/opt/bgrpiimage/    │
  └─────────────────────┘     │   + env resolve)   │     │   (inputs for CustomPiOS)│
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
| **Flashing** (RPi Imager catalog, CM4/CM5 eMMC, Etcher, dd) | [docs/flash.md](docs/flash.md) |
| JSON config reference + env resolver | [docs/configuration.md](docs/configuration.md) |
| **Hardware reference** (camera, HDMI, RTC, fan, watchdog, overclock, …) | [docs/hardware.md](docs/hardware.md) |
| Creating a new variant (`extends` chain) | [docs/variants.md](docs/variants.md) |
| **Post-flash setup (password · WiFi · IP)** | [docs/post-flash-setup.md](docs/post-flash-setup.md) |
| Dockerised tools container | [docs/tools-container.md](docs/tools-container.md) |
| GitHub Actions CI/CD | [docs/ci-cd.md](docs/ci-cd.md) |
| Login banner + unattended updates | [docs/banner-and-updates.md](docs/banner-and-updates.md) |

---

## 🔐 Secrets & defaults

> ⚠️ **Default credential shipped by this image:** `admin` → `12345678`
>
> This is a **published default**, on purpose: the images are public, so a
> discoverable credential is what makes them usable at all. It ships
> **expired** (`chage -d 0`) — the first login, console or SSH, forces you to
> set a new one before you get a session, so it cannot silently stay in place,
> and the MOTD keeps reminding you until it has actually been rotated.
>
> **No WiFi PSK ships any more.** WiFi is disabled by default; enable it per
> device with `bgrpiimage-setup wifi enable`, or bake a network into the
> variant JSON.

> ⚠️ **Upgrading the `canbus-plattform` variant from v0.5.0 or older:** which
> physical CAN connector is `can0` changes. `can0` is now the CS0 chip (screw
> terminal CAN0); probe order previously gave that name to the CS1 chip.
> Details and the migration check in
> [`docs/hardware.md`](docs/hardware.md#-can-waveshare-17912-dual-mcp2515).

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
sudo bgrpiimage-setup wifi enable "MyNet" "s3cret"   # unblock radio + join
sudo bgrpiimage-setup wifi status                    # rfkill / regdom / link
sudo bgrpiimage-setup wifi disable                   # tear down, drop the PSK
sudo bgrpiimage-setup can status                     # chip select, IRQ, bitrate
sudo bgrpiimage-setup can bitrate can0 250000        # change a CAN bitrate
sudo bgrpiimage-setup can txqueuelen can0 1024       # change a CAN tx queue
sudo bgrpiimage-setup ip eth0 dhcp                   # back to DHCP
sudo bgrpiimage-setup ip eth0 static 10.0.0.5/24 10.0.0.1 1.1.1.1
sudo bgrpiimage-setup status                         # overview
```

> The helper ships **inside the image**, so its subcommands are those of the
> version you flashed — `can` needs v0.6.0, `can txqueuelen` v0.6.1. An
> `unknown command` here means the image predates the docs, not a broken
> install; `sudo bgrpiimage-setup status` prints the version. See
> [`post-flash-setup.md`](docs/post-flash-setup.md#-the-bgrpiimage-setup-helper).

Interactive shells get the usual list shortcuts (`ll`, `la`, `l`) for every
account including `root`, from `/etc/profile.d/50-bgrpiimage-shell.sh`.

All IP changes land as `/etc/systemd/network/05-bgrpiimage-<iface>.network`
— the `05-` prefix sorts before the shipped `10-eth.network` /
`20-wlan.network`, and systemd-networkd applies only the first matching file,
so ours wins. The defaults are left in place, so reverting is just deleting
the file.

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
│   ├── modules/                           # bgrpiimage-{base,users,network,boot,
│   │                                      #              hardware,can,docker,portainer,
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
