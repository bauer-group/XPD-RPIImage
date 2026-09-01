# 🧱 Architecture

How XPD-RPIImage turns a ~1 KB JSON into a bootable `.img.xz` of roughly 0.9 GB
(~5 GB uncompressed), starting from Raspberry Pi OS Lite arm64.

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
5. **Renders** artifacts into
   `src/modules/<module>/filesystem/root/opt/bgrpiimage/<module>/`.
6. **Writes** the per-variant CustomPiOS shell config to
   `src/variants/<name>/config` (module list, DIST_VERSION, hostname…).

Output breakdown:

| Module | Generated artifacts |
| --- | --- |
| `bgrpiimage-base` | `hostname`, `locale.env`, `packages.list`, `release.env`, `ssh.env`, `issue`, `issue.net`, `sshd_banner.conf`, `motd-banner.sh` |
| `bgrpiimage-users` | `create-users.sh`, `pam_su` |
| `bgrpiimage-network` | `systemd-networkd/10-eth.network`, `20-wlan.network`, `wpa_supplicant/wpa_supplicant-wlan0.conf` |
| `bgrpiimage-boot` | `config-bgrpiimage.txt` (dtparam + dtoverlay snippet) |
| `bgrpiimage-hardware` | `hardware.env`, `packages.list`, `eeprom.env`, EEPROM apply script + oneshot unit — only when RTC, watchdog, bootloader or a non-`auto` audio sink is configured |
| `bgrpiimage-can` | `systemd-networkd/40-can0.network`, `40-can1.network`, `packages.list` |
| `bgrpiimage-docker` | `daemon.json`, `98-docker.conf` (sysctl), `docker-support.service`, `create-networks.sh` |
| `bgrpiimage-portainer` | `docker-compose.yml`, `bgrpiimage-portainer-install.service` (oneshot), `portainer.env` |
| `bgrpiimage-unattended-upgrades` | `50unattended-upgrades`, `20auto-upgrades`, timer overrides, reboot-window service+timer+script |

Modules whose feature is disabled in the JSON are omitted from the generated
`MODULES=` list in `src/variants/<variant>/config`, so CustomPiOS never
executes them. (A `.disabled` marker file is also written into the module's
generated tree, but nothing reads it — it is vestigial.)

### 3. Assembly — CustomPiOS chroot

[CustomPiOS][custompios] is cloned into `./CustomPiOS/` by
`scripts/bootstrap.sh` (gitignored). The revision is pinned by **full commit
SHA** — upstream's tags are lightweight and can be force-moved, so a SHA is the
stronger pin. The default lives in `scripts/bootstrap.sh` and CI overrides it
via `CUSTOMPIOS_REF` in `build.yml`; bootstrap verifies the checked-out HEAD
matches and fails the build if it does not. Current pin: CustomPiOS 2.0.0
(`d293309aac2f606c609645b441962c8f02b6e8c3`), which requires the
`python3-git` / `python3-yaml` host packages. Two execution paths:

- **Native** (CI runner, bare Linux host): `BGRPI_NATIVE_BUILD=yes` — build
  runs directly, needs `qemu-user-static` + `kpartx` + `xz-utils` +
  `python3-git` + `python3-yaml` on the host.
- **Dockerised** (macOS/Windows dev): `ghcr.io/guysoft/custompios:sha-d293309`
  as a privileged sibling container. The repo reaches it at a path the daemon
  can resolve — inherited from the tools container via
  `--volumes-from $BGRPI_TOOLS_CONTAINER`, or bind-mounted at its own path when
  `scripts/build.sh` runs directly on a Linux host.
  (Upstream moved off Docker Hub; `guysoft/custompios` there is unmaintained.)
  Only the bind-mounted checkout executes — the container supplies OS deps.

First `scripts/build.sh` fetches the base `.img.xz` into `src/image-cache/`,
verifies it against `base_image.sha256` from the variant JSON (a mismatch
aborts the build), extracts the `.img` and records its hash in a `.verified`
stamp that is re-checked on every warm-cache run. CustomPiOS is handed the
ready `.img` via `BASE_ZIP_IMG` — it never downloads anything itself.

Then CustomPiOS:

1. Copies the prepared image into the workspace.
2. Mounts it via `kpartx` + loop device, resizes root filesystem.
3. Binds our `src/` tree into the chroot.
4. For each module in `MODULES=…` (disabled modules are already absent
   from that list):
   - Runs `start_chroot_script` under `qemu-aarch64-static`.
   - Module unpacks its `filesystem/root/` tree to the appropriate location,
     enables systemd units, installs packages.
5. Unmounts, compresses resulting image.

Key file: `src/modules/<name>/start_chroot_script` — each one is short and
boring: `install -m` files into `/etc/...`, call `systemctl enable`, done.
The interesting logic is in the generator.

### 4. Delivery

Local: `dist/bgrpiimage-<variant>-v<version>.img.xz`. The `.sha256` and
`.manifest.json` sidecars are produced by CI, not by `scripts/build.sh` — run
`sha256sum` yourself if you need one locally.

CI: see [`ci-cd.md`](ci-cd.md). In short:

- every push/PR → Actions artifact (`retention-days: 3`), SHA-suffixed filename
- every tag → GitHub Release asset (permanent), clean version-only filename

---

## 🔑 Why Python renders, not Jinja2 / shell templates

The generator does three jobs a template engine does not:

- **Schema validation** via `jsonschema` — catches typos before build.
- **`extends` resolution** — recursive load, `name`-keyed deep-merge.
- **Env-var substitution with fail-fast** — a bare `${VAR}` that is unset
  raises `KeyError`. Note the `${VAR:-default}` form deliberately opts out of
  this: the shipped variants use `${ADMIN_PASSWORD:-12345678}` so a first
  boot works out of the box. That path is not silent — the generator prints a
  `SECURITY:` warning at build time and the image carries
  `/etc/bgrpiimage-default-password-active`, which the MOTD reports on every
  login until the credential is rotated.

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
4. Register the renderer in the `steps` list in `main()` — `ACTIVE_MODULES`
   only controls the generated `MODULES=` list; `steps` is what actually calls
   `render_wireguard()`. A module in one but not the other silently renders
   nothing.
5. Create `src/modules/bgrpiimage-wireguard/` with `config` and
   `start_chroot_script`.
6. Set defaults in `config/variants/base.json`.

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
    │           ghcr.io/guysoft/custompios     (needs loop devices)
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
