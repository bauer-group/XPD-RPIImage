# 🧱 Architecture

How XPD-RPIImage turns a ~1 KB JSON into a bootable ~650 MB `.img.xz`.

---

## 🪜 The four stages

```text
  ┌───────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
  │ 1. Declaration │──▶│ 2. Generation │──▶│ 3. Assembly  │──▶│ 4. Delivery  │
  │  (JSON config) │   │  (Python)     │   │  (CustomPiOS) │   │ (.img / CI)  │
  └───────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
```
### 1. Declaration — `config/variants/*.json`

Each variant is a single JSON file validated against
[`config/schema.json`](../config/schema.json). It declares **what** the image
should contain — users, packages, networks, boot overlays, services — not
**how** to install them.

Composition via `extends`:

```json
{ "extends": "./base.json",
  "variant": { "name": "canbus-plattform" },
  "packages": ["can-utils"],          ← concat with base.packages
  "users":    [{ "name": "admin", "groups": ["dialout", "spi"] }]  ← merged by name
}
```
Secrets via env-var references:

```json
"password": "${ADMIN_PASSWORD:-12345678}"
```
Details: [`configuration.md`](configuration.md).

### 2. Generation — `scripts/generate.py`

Python 3.14 utility. For every variant:

1. **Loads** the JSON, follows the `extends` chain (recursively).
2. **Deep-merges** parent + child (objects recurse, scalar arrays concat with
   dedupe, named-record arrays merge by `name`).
3. **Resolves** `${VAR}` references against `os.environ` + optional `--env-file`.
4. **Validates** the resolved object against `config/schema.json`.
5. **Renders** artifacts into `src/modules/<module>/files/_generated/`.
6. **Writes** the per-variant CustomPiOS shell config to
   `src/variants/<name>/config` (module list, DIST_VERSION, hostname…).

Output breakdown:

| Module | Generated artifacts |
| --- | --- |
| `bgrpiimage-base` | `hostname`, `locale.env`, `packages.list`, `release.env`, `ssh.env`, `issue`, `issue.net`, `sshd_banner.conf`, `motd-banner.sh` |
| `bgrpiimage-users` | `create-users.sh`, `pam_su` |
| `bgrpiimage-network` | `systemd-networkd/10-eth.network`, `20-wlan.network`, `wpa_supplicant/wpa_supplicant-wlan0.conf` |
| `bgrpiimage-boot` | `config-bgRPIImage.txt` (dtparam + dtoverlay snippet) |
| `bgrpiimage-can` | `systemd-networkd/40-can0.network`, `40-can1.network`, `packages.list` |
| `bgrpiimage-docker` | `daemon.json`, `98-docker.conf` (sysctl), `docker-support.service`, `create-networks.sh` |
| `bgrpiimage-portainer` | `portainer.service`, `portainer.env` |
| `bgrpiimage-unattended-upgrades` | `50unattended-upgrades`, `20auto-upgrades`, timer overrides, reboot-window service+timer+script |

Modules whose feature is disabled in the JSON get a `.disabled` marker and
are skipped by their `filter` script at build time.

### 3. Assembly — CustomPiOS chroot

[CustomPiOS][custompios] is cloned into `./CustomPiOS/` by
`scripts/bootstrap.sh` (gitignored; pin via `CUSTOMPIOS_REF`). The build
container (`guysoft/custompios:devel`) runs:

1. Downloads the base arm64 Raspberry Pi OS image.
2. Mounts it via `kpartx` + loop device, resizes root filesystem.
3. Binds our `src/` tree into the chroot.
4. For each module in `MODULES=…`, if the module's `filter` exits 0:
   - Runs `start_chroot_script` under `qemu-aarch64-static`.
   - Module copies its `files/_generated/*` to the appropriate location,
     enables systemd units, installs packages.
5. Unmounts, compresses resulting image.

Key file: `src/modules/<name>/start_chroot_script` — each one is short and
boring: `install -m` files into `/etc/...`, call `systemctl enable`, done.
The interesting logic is in the generator.

### 4. Delivery

Local: `dist/bgrpiimage-<variant>-v<version>.img.xz` + `.sha256`.

CI: see [`ci-cd.md`](ci-cd.md). In short:

- every push/PR → Actions artifact (14-day TTL), SHA-suffixed filename
- every tag → GitHub Release asset (permanent), clean version-only filename

---

## 🔑 Why Python renders, not Jinja2 / shell templates

The generator does three jobs a template engine does not:

- **Schema validation** via `jsonschema` — catches typos before build.
- **`extends` resolution** — recursive load, `name`-keyed deep-merge.
- **Env-var substitution with fail-fast** — missing secret raises
  `KeyError`, never silently produces an empty password.

Each of these is cheap in Python, awkward in a template layer.

Modules themselves stay template-free: a module's `start_chroot_script` is
~15 lines of `install -m 644 "$GEN/X" /etc/X` — the hard work is already
done by the generator.

---

## 🔄 Extending the system

### Add a new variant
→ [`variants.md`](variants.md). Usually a 10-line JSON file.

### Add a new feature area (e.g. WireGuard VPN)

1. Add an optional section to [`config/schema.json`](../config/schema.json).
2. Add a `render_wireguard()` function to [`scripts/generate.py`](../scripts/generate.py).
3. Append the module name to `ACTIVE_MODULES` + update `_module_enabled()`.
4. Create `src/modules/bgrpiimage-wireguard/` with `config`, `filter`,
   `start_chroot_script`.
5. Set defaults in `config/variants/base.json`.

The existing modules are the template. No framework indirection.

---

## 🐳 Why two docker containers for a build?

```text
  host (any OS with Docker)
    │
    ├── docker run bgrpiimage-tools        ← dev container
    │     python + make + jq + docker CLI     (not privileged)
    │     │
    │     └── docker run --privileged \    ← sibling container
    │           guysoft/custompios             (needs loop devices)
    │
    └── /var/run/docker.sock ← bind-mounted into tools, so sibling launches on host
```
Two reasons:

- **Privilege containment**: the dev container has *no* `--privileged`, only
  the actual image build sibling does.
- **Host dependency isolation**: Python version, `jq`, `xz`, CustomPiOS
  tooling — none of it has to exist on the user's laptop.

Details: [`tools-container.md`](tools-container.md).

[custompios]: https://github.com/guysoft/CustomPiOS
