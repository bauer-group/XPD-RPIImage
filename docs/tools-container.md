# 🐳 Tools container

Portable dev/build runtime for XPD-RPIImage. Runs on any host with Docker —
no local Python, qemu, kpartx or CustomPiOS clone required.

---

## 🎯 What it does

```
  host (Linux / macOS / Windows with Docker Desktop)
    │
    ├── docker run bgrpiimage-tools          ← dev shell  (not privileged)
    │     │   python 3.14, make, jq, git, xz, docker CLI
    │     │
    │     ├── python scripts/generate.py     ← validate / render
    │     │
    │     └── bash scripts/build.sh          ← launches…
    │            │
    │            └── docker run --privileged \   ← SIBLING container
    │                  guysoft/custompios:devel     (has loop devices, qemu)
    │                    │
    │                    └── chroot + unpack → dist/*.img.xz
    │
    └── /var/run/docker.sock  ← bind-mounted INTO tools container
                                 so the sibling is launched on the host Docker
```

The tools container itself is **not** privileged. Only the sibling
`guysoft/custompios` container gets `--privileged`, and only while it is
mounting / chrooting the base image.

---

## 🚀 Usage

### Linux / macOS / WSL

```bash
./tools/run.sh validate                          # all variants, --dry-run
./tools/run.sh validate canbus-plattform         # one variant
./tools/run.sh render   canbus-plattform         # generate module artifacts
./tools/run.sh build    canbus-plattform         # full image build
./tools/run.sh shell                             # interactive bash
./tools/run.sh clean                             # wipe generated + dist
./tools/run.sh validate -b                       # rebuild tools image first
```

### Windows CMD

```cmd
tools\run.cmd validate
tools\run.cmd build canbus-plattform
tools\run.cmd build canbus-plattform --env-file ..\.env
tools\run.cmd shell --build
```

### Windows PowerShell

```powershell
.\tools\run.ps1 validate
.\tools\run.ps1 build   -Variant canbus-plattform
.\tools\run.ps1 build   -Variant canbus-plattform -EnvFile ..\.env
.\tools\run.ps1 shell   -Build
```

---

## ⚙️ Commands

| Command | Action |
|---|---|
| `validate [variant]` | Schema-check + env resolve (dry-run, no file writes). |
| `render <variant>` | Generate module artifacts under `src/modules/*/files/_generated/`. |
| `build <variant>` | Full image build. Produces `dist/bgRPIImage-<variant>-v<version>.img.xz`. |
| `shell` | Drop into bash inside the tools container. |
| `clean` | Wipe generated files + `src/workspace/` + `dist/`. |
| `help` | Show help. |

All commands take:

| Flag | Purpose |
|---|---|
| `--build` / `-b` / `-Build` | Rebuild the tools image before running (pick up `requirements.txt` changes). |
| `--env-file <path>` / `-EnvFile <path>` | Pass a `.env` file to the generator and `build.sh`. |

---

## 🖥️ Host requirements

| OS | Requirements |
|---|---|
| Linux | Docker engine 20.10+, loop device support (native). |
| macOS | Docker Desktop 4.x with VirtioFS and Rosetta for arm64 images. |
| Windows 11 | Docker Desktop WSL2 backend. |

**Disk**: plan ~8 GB free during a build (base image + chroot rootfs + compressed output).

---

## 🧩 How it's built

[`tools/Dockerfile`](../tools/Dockerfile) starts from `python:3.14-slim-trixie`
(matching our Raspberry Pi OS trixie base) and adds:

- `bash`, `make`, `jq`, `git`, `curl`, `xz-utils` — build driver essentials.
- `docker-ce-cli` + `docker-compose-plugin` — to launch sibling containers.
- Python deps from `scripts/requirements.txt` (mirrored into
  `tools/requirements.txt` by the launchers).
- A friendly `(bgRPIImage-tools)` bash prompt so you know where you are.

The image is tagged `bgrpiimage-tools` locally. Override with
`BGRPIIMAGE_TOOLS_IMAGE=...` env before invoking the launcher.

---

## 🔧 Troubleshooting

### "permission denied: /var/run/docker.sock"

Your user must be in the `docker` group on the host (Linux). On Docker
Desktop (macOS / Windows) this is handled automatically.

### "cannot create overlay mount" / loop device errors

Only seen on hosts without loop device support. Use Docker Desktop (which
runs a Linux VM) or a real Linux host. WSL2 works.

### "Git Bash interprets /workspace as C:\Program Files\Git\workspace"

`run.sh` already sets `MSYS_NO_PATHCONV=1` and `MSYS2_ARG_CONV_EXCL='*'`
to disable MSYS path translation. If you bypass `run.sh`, set those yourself.

### Builds are slow

- First build clones CustomPiOS (~10 MB, once).
- First `--build` of the tools image pulls ~800 MB of Python + apt.
- Subsequent image builds reuse the `guysoft/custompios` layer cache.

Expected wall-clock on an 8-core laptop with SSD: 25–45 minutes per variant.
