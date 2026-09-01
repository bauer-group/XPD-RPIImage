# 🐳 Tools container

Portable dev/build runtime for XPD-RPIImage. Runs on any host with Docker —
no local Python, qemu, kpartx or CustomPiOS clone required.

---

## 🎯 What it does

```text
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
    │                  ghcr.io/guysoft/custompios:sha-d293309  (loop devices, qemu)
    │                    │
    │                    └── chroot + unpack → dist/*.img.xz
    │
    └── /var/run/docker.sock  ← bind-mounted INTO tools container
                                 so the sibling is launched on the host Docker
```

The tools container itself is **not** privileged. Only the sibling
`guysoft/custompios` container gets `--privileged`, and only while it is
mounting / chrooting the base image.

### How the sibling sees the project

The sibling is created by the **host** Docker daemon, so any `--volume` source
is resolved by the daemon — not by the tools container. Handing it our own
`/workspace` would be wrong: that path does not exist on the host, and Docker
would silently create an empty directory and mount that, leaving `/distro`
empty and the build failing later for no visible reason. Handing it the host
path instead does not work either on Windows, where a Linux Docker client
cannot use `C:\...` as a bind source at all.

So the launchers give the tools container a name and pass it through as
`BGRPI_TOOLS_CONTAINER`, and [`scripts/build.sh`](../scripts/build.sh) starts
the sibling with `--volumes-from "$BGRPI_TOOLS_CONTAINER"`. The sibling
inherits exactly the mounts the daemon already created, at the same paths — so
nothing has to be translated and the behaviour is identical on Windows, macOS
and Linux.

Outside the tools container (a plain Linux host), `build.sh` bind-mounts the
project at its own path instead, so the paths it passes are valid either way.
Running `scripts/build.sh` directly from Git Bash on Windows is refused with an
explicit message: the daemon cannot resolve an MSYS `/c/...` path, and the
tools container is the supported route.

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
| --- | --- |
| `validate [variant]` | Schema-check + env resolve (dry-run, no file writes). |
| `render <variant>` | Generate module artifacts under `src/modules/*/files/_generated/`. |
| `build <variant>` | Full image build. Produces `dist/bgrpiimage-<variant>-v<version>.img.xz`. |
| `shell` | Drop into bash inside the tools container. |
| `clean` | Wipe generated files + `src/workspace/` + `dist/`. |
| `help` | Show help. |

All commands take:

| Flag | Purpose |
| --- | --- |
| `--build` / `-b` / `-Build` | Rebuild the tools image before running (pick up `requirements.txt` changes). |
| `--env-file <path>` / `-EnvFile <path>` | Pass a `.env` file to the generator and `build.sh`. |

---

## 🖥️ Host requirements

| OS | Requirements |
| --- | --- |
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
- A friendly `(bgrpiimage-tools)` bash prompt so you know where you are.

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
