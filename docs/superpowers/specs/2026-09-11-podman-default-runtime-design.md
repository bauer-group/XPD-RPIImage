# Podman as the default container runtime

Status: approved design, ready for implementation planning
Date: 2026-09-11

## Goal

Make Podman with Docker CLI emulation the default container runtime of the
bgRPIImage base image, deploy Portainer CE `:lts` on top of it via Quadlet,
and keep the existing Docker stack as a supported non-default option.

No migration path for already-flashed devices is required. The change is
image-build-only, consistent with how `bgrpiimage-docker` and
`bgrpiimage-portainer` already behave.

## Non-goals

- Migrating a running device from Docker to Podman.
- Touching the **build-host** Docker. `tools/Dockerfile`, `scripts/build.sh`,
  the CustomPiOS sibling-container pattern and `docs/tools-container.md`
  describe the machine that builds the image, not the image. They stay as
  they are. Two different things that are both called "Docker".
- Rootless Podman. Portainer's socket support is documented for rootful only.
- Porting `create-networks.sh` / `bgrpiimage-docker-networks.service`. The
  script renders as a 72-byte empty header on every shipped image because no
  variant has ever defined `docker.networks`. It is not carried over to
  Podman. The Docker path keeps it unchanged.

## Verified platform facts

Every fact below was confirmed against the version Debian trixie actually
ships, not against upstream `main` or `docs.podman.io/en/latest` — those are
ahead of trixie and produced several false leads during research.

| Fact | Source |
| --- | --- |
| trixie ships podman `5.4.2+ds1-2`, with `podman-docker` from the same source package | packages.debian.org/trixie/podman |
| Raspberry Pi OS trixie boots a pure cgroup v2 unified hierarchy — Quadlet's hard requirement is met | podman-systemd.unit(5) v5.4.2 line 95 |
| Quadlet applies `[Install]` itself during generation, "in the same way `systemctl enable` does when run later" | podman-systemd.unit(5) v5.4.2 |
| `.container` services get **no** `Restart=` from Quadlet; only `ConvertPod` emits one | pkg/systemd/quadlet/quadlet.go v5.4.2 |
| No dedicated privileged key exists in `[Container]` at v5.4.2 | grep `privileg` over quadlet.5 → only `NoNewPrivileges` |
| `AutoUpdate` is in `supportedContainerKeys` but **not** in `supportedImageKeys` | pkg/systemd/quadlet/quadlet.go v5.4.2 |
| `podman-auto-update.service` carries `ExecStartPost=podman image prune -f` | contrib/systemd/system/podman-auto-update.service.in v5.4.2 |
| `podman-auto-update.timer` is `OnCalendar=daily`, `RandomizedDelaySec=900`, `Persistent=true`, `WantedBy=timers.target` | contrib/systemd/system/podman-auto-update.timer v5.4.2 |
| Debian ships all podman units **disabled** (`dh_installsystemd --no-enable --no-start`) | sources.debian.org podman 5.4.2+ds1-2 debian/rules |
| `podman-docker` ships `/usr/lib/tmpfiles.d/podman-docker.conf` = `L+ %t/docker.sock - - - - %t/podman/podman.sock` | contrib/systemd/system/podman-docker.conf v5.4.2 |
| `podman.socket` is `ListenStream=%t/podman/podman.sock`, `SocketMode=0660`, no SocketUser/Group → root:root | contrib/systemd/system/podman.socket v5.4.2 |
| `containers.conf` has **no** key that enables IPv6 on the default network | containers.conf template, containers-common v0.62.2 |
| netavark performs NAT66 itself for any `ipv6_enabled` bridge | netavark 1.14 |
| Portainer's documented Podman install is rootful + `--privileged` + socket bound to `/var/run/docker.sock` | docs.portainer.io/start/install-ce/server/podman/linux |
| `portainer/portainer-ce:lts` currently resolves to 2.45.0 | Docker Hub registry API, 2026-09-11 |

### Known risks, accepted

1. **Portainer's support matrix names Podman 5.5.1 as the minimum**; trixie
   ships 5.4.2. The combination is empirically working on the owner's device
   but sits below the documented floor. This is the most likely source of a
   future "it broke and we changed nothing".
2. **Portainer's DB migration is one-way.** Portainer's own docs: a database
   written by a newer version will not start on an older one, and rollback
   requires restoring a backup. This is why auto-update gets a pre-update
   backup (below) rather than relying on Podman's rollback alone.
3. **Rollback only catches "container never started".** See the auto-update
   section.

## Architecture

`bgrpiimage-docker` is left untouched. A sibling module `bgrpiimage-podman`
is added. `_module_enabled()` activates exactly one of the two; a semantic
validator rejects a config that enables both.

Three lists in `scripts/generate.py` must move together or the module
silently renders without being built:

- `ACTIVE_MODULES` (chroot execution order, feeds `MODULES=`)
- `_module_enabled()` (the single gate, also read by `bundle.py`)
- the `steps` dispatch table

## Config contract

`config/schema.json` is `additionalProperties: false` at the top level and
inside `docker`/`portainer`, so every new key must be declared.

```jsonc
"docker":  { "enabled": false, /* everything else unchanged */ },

"podman": {
  "enabled": true,
  "docker_emulation": true,
  "sysctl": { "vm.max_map_count": 4194304 },
  "network": {
    "default_subnet": "10.10.0.0/17",
    "default_subnet_pools": [{ "base": "10.10.128.0/17", "size": 24 }],
    "ipv6": true,
    "subnet_v6": "fdff:0::/64"
  },
  "journald": { "system_max_use": "200M", "system_max_file_size": "20M" },
  "auto_update": {
    "enabled": true,
    "schedule": { "start": "05:30", "randomized_delay": "30m" }
  }
},

"portainer": {
  "enabled": true,
  "edition": "ce",
  "bind": "0.0.0.0",
  "image": "docker.io/portainer/portainer-ce:lts",
  "ports": { "edge": 8000, "http": 9000, "https": 9443 },
  "auto_start": true,
  "auto_update": true,
  "backup_before_update": { "enabled": true, "keep": 5 }
}
```

`bind` keeps the dual-stack semantics it already has in the Docker path
(`generate.py:1660-1668`) and maps onto `PublishPort`, which takes the same
`[IP:]host:container` syntax as `podman run --publish`:

- `0.0.0.0` (default) → `PublishPort=9443:9443`, host IP omitted so the
  listener covers both `0.0.0.0:PORT` and `[::]:PORT`. Writing
  `0.0.0.0:9443:9443` would restrict it to IPv4.
- anything else → `PublishPort=127.0.0.1:9443:9443`, pinned to that address.

`vm.max_map_count` moves with the runtime deliberately. It lives only inside
the `docker` block today, so flipping `docker.enabled` to `false` would
otherwise delete a runtime-agnostic kernel setting from the image with no
warning and no test covering it.

The Portainer image reference becomes **fully qualified**. Podman resolves
unqualified names through `unqualified-search-registries`, which this image
does not ship; more importantly `AutoUpdate=registry` requires a fully
qualified reference.

### Semantic validation

`_semantic_validate()` gains:

- `docker.enabled` and `podman.enabled` are mutually exclusive.
- `portainer.auto_update` requires `podman.auto_update.enabled` — the label
  is inert without the timer.
- `portainer.auto_update` is incompatible with a digest-pinned
  `portainer.image` (the remote digest can never differ, so it never fires).
- `podman.auto_update.schedule.start` must fall outside the
  `unattended_upgrades` upgrade window and outside the reboot window.

## The `bgrpiimage-podman` module

### Packages

Explicit, because `bg_apt_install` hardcodes `--no-install-recommends`
(`apply-lib.sh:343`):

```
podman podman-docker containers-common netavark aardvark-dns nftables uidmap catatonit
```

`nftables` is the trap: netavark only *Recommends* it but uses it as its
compiled-in default firewall driver. Without naming it explicitly the image
builds clean and container networking comes up with no firewall rules.

### Generated payload (`render_podman()`)

| Generated file | Installed to | Purpose |
| --- | --- | --- |
| `containers.conf` | `/etc/containers/containers.conf` | `default_subnet`, `default_subnet_pools`, `firewall_driver` |
| `podman-network.json` | `/etc/containers/networks/podman.json` | IPv6 on the default bridge |
| `98-podman.conf` | `/etc/sysctl.d/98-podman.conf` | `vm.max_map_count` |
| `99-bgrpiimage-containers.conf` | `/etc/systemd/journald.conf.d/` | `SystemMaxUse`, `SystemMaxFileSize` |
| `nodocker` | `/etc/containers/nodocker` | suppresses the emulation notice |
| `podman-auto-update.timer.d/override.conf` | `/etc/systemd/system/…` | schedule override |
| `podman.env` | `/etc/default/podman` | module knobs, mirrors `portainer.env` |

Units enabled in the chroot with plain `systemctl enable` — the pattern the
Docker module already proves works offline:

```
podman.socket
podman-restart.service
podman-auto-update.timer      # only when podman.auto_update.enabled
```

The **service** is deliberately not enabled: `podman-auto-update.service` is
`WantedBy=default.target` and would fire on every boot.

The Docker path's ip6tables MASQUERADE helper is **not** ported. netavark
does NAT66 itself; a second rule would be a duplicate.

`/run/docker.sock` needs no manual symlink — `podman-docker` ships the
tmpfiles drop-in that creates it.

### IPv6 on the default network — the one brittle piece

`containers.conf` has no key for this. The only declarative path is writing
`/etc/containers/networks/podman.json`, which netavark loads at first use.
Two hard requirements, both silent failures when violated:

- the filename must match the network name (`podman.json`), otherwise
  netavark skips it with only a log line;
- the `id` field must be present and 64 hex chars.

Reusing netavark's own constant id keeps `podman network inspect` output
identical to stock:

```
2f259bab93aaaaa2542ba43ef33eb990d0999ee1b9924b557b7be53c0b7a1bb9
```

JSON field names come from `libnetwork/types.Network` (containers-common
v0.62.2): `name`, `id`, `driver`, `network_interface`, `subnets[].subnet`,
`subnets[].gateway`, `ipv6_enabled`, `internal`, `dns_enabled`.

Because the fallback is silent (IPv4-only, warning in the log), the test
suite gets an explicit assertion on `ipv6_enabled`.

## Portainer via Quadlet

`render_portainer()` branches on the active runtime. The Docker path emits
today's `docker-compose.yml` plus the first-boot oneshot, unchanged. The
Podman path emits two files and **no oneshot unit at all**.

```ini
# /etc/containers/systemd/portainer.image
[Image]
Image=docker.io/portainer/portainer-ce:lts
```

```ini
# /etc/containers/systemd/portainer.container
[Unit]
Description=Portainer CE
Requires=podman.socket
After=podman.socket

[Container]
Image=portainer.image
ContainerName=portainer
AutoUpdate=registry
PublishPort=8000:8000
PublishPort=9000:9000
PublishPort=9443:9443
Volume=/run/podman/podman.sock:/var/run/docker.sock
Volume=portainer_data:/data
PodmanArgs=--privileged

[Service]
Restart=always
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
```

Four decisions encoded here that are easy to get wrong:

1. **`Restart=` sits in `[Service]`.** Quadlet emits no `Restart=` for
   `.container` units. `--restart=always` inside `PodmanArgs` would be
   ignored, because systemd owns the lifecycle.
2. **The `.image` unit moves the pull into its own oneshot** with its own
   `Requires=`/`After=` edge on `portainer-image.service`. Without it the
   first pull counts against the container unit's start timeout.
3. **`AutoUpdate=registry` goes only in `[Container]`.** It is not a valid
   `[Image]` key, and putting it there fails generation for both units.
4. **No `systemctl enable`** for `portainer.service`. Quadlet units are
   generated at boot, so they cannot be enabled in a chroot; the generator
   applies `[Install]` itself. The whole build step is a pure file drop.

`podman-restart.service` becomes unnecessary *for this container*, since
systemd starts it via `WantedBy=multi-user.target`. It stays enabled for
operator-created containers that use `--restart=always`.

No SELinux `:z`/`:Z` suffix on the volumes — Debian ships no SELinux policy.

## Auto-update

The label alone is not enough; three pieces make it safe.

### Schedule

The image already ships `apt-daily-upgrade` at 02:00–04:00 and a reboot
window at 03:00–05:00 that runs `shutdown -r +1` unconditionally when a
reboot is pending. Portainer's startup DB migration is one-way. An update
firing inside those windows can take a reboot mid-migration, and a
half-migrated `portainer.db` on an SD card needs a human on site.

The timer therefore fires **after both windows**, using the same drop-in
pattern the repo already uses for `apt-daily-upgrade.timer` — including the
empty `OnCalendar=` reset, which systemd requires to clear the shipped value:

```ini
# /etc/systemd/system/podman-auto-update.timer.d/override.conf
[Timer]
OnCalendar=
OnCalendar=*-*-* 05:30:00
RandomizedDelaySec=1800
Persistent=true
```

`Persistent=true` matches every other timer in this image. The alternative
would silently never run on a fleet that is powered off overnight.

### Rollback: what it actually covers

`--rollback` defaults to true, but only triggers when the systemd *restart*
fails. Quadlet's default `--sdnotify=conmon` signals READY as soon as the
container process spawns, so a Portainer that starts and then crashes counts
as a successful restart and is **not** rolled back.

The textbook fix is `Notify=healthy` plus a `HealthCmd=`. This design
deliberately does **not** ship one: it is unconfirmed whether the arm64
Portainer image contains `/bin/sh` or an HTTP client, and an unsatisfiable
healthcheck fails *every* start, not just updates. A broken update is an
annoyance; an image that never comes up is a truck roll.

Documented consequence: rollback covers "the new image will not start at
all". It does not cover "the new image starts and then misbehaves".

### Pre-update backup

Because the DB migration is one-way, auto-update without a backup is a
one-way door. The module ships a helper plus a service drop-in:

```ini
# /etc/systemd/system/podman-auto-update.service.d/10-backup.conf
[Service]
ExecStartPre=/usr/local/sbin/bgrpiimage-portainer-backup
```

`/usr/local/sbin/bgrpiimage-portainer-backup` exports the volume and prunes
old archives:

```sh
podman volume export portainer_data \
  | gzip -c > /var/backups/bgrpiimage/portainer-$(date +%Y%m%dT%H%M%S).tar.gz
```

Constraints the implementation must honour:

- `ExecStartPre=` failing aborts the unit, which would block updates forever
  once the disk fills. The helper exits 0 on a failed export and logs instead
  — a missing backup must not become a stuck fleet.
- It runs on **every** timer fire, not only when an update is available, so
  pruning to `portainer.backup_before_update.keep` archives is what bounds
  the growth. Retaining `keep` files is the whole disk budget.
- `/var/backups/bgrpiimage/` is created by the helper, not shipped as an
  empty directory.

The old *image* needs no cleanup of our own — `podman-auto-update.service`
already carries `ExecStartPost=podman image prune -f`.

## What is deliberately not built

**No `apply.sh` for `bgrpiimage-podman`.** `bgrpiimage-docker` and
`bgrpiimage-portainer` are deliberately absent from `BUNDLE_MODULES`
(`scripts/bundle.py:58`) — container-runtime config is reflash-only, and
`docs/post-flash-setup.md` documents that as intentional. Since no migration
of running devices is required, the Podman module stays consistent with that
and avoids the parity-test trap: `tests/test-apply-parity.sh` pins
`BASE_REF=v0.8.0`, where a brand-new module has no historical counterpart.

**The `docker` group stays in the user's group list.** Under rootful Podman
the socket is root-owned and there is no socket group, so the entry is inert.
Removing it would be cosmetic and unachievable in the field anyway —
`/etc/group` is on `BGRPI_DENY_GLOBS`, so no update can ever change group
membership on a flashed device.

## Test coverage

Following the conventions in `tests/`:

- `test-config-guards.sh`: docker/podman mutual exclusion; `portainer.auto_update`
  without `podman.auto_update.enabled` is rejected; auto-update schedule
  outside the upgrade and reboot windows; digest-pinned image plus
  auto-update is rejected.
- New assertions on the rendered payload: `AutoUpdate=registry` present in
  `[Container]` and absent from the `.image` unit; `Restart=always` in
  `[Service]` and not in `[Container]`; all three ports published; the
  network JSON has a 64-hex `id` and `ipv6_enabled: true`; `nftables` in the
  package list; the timer drop-in contains the empty `OnCalendar=` reset.
- Renderer parity: `bgrpiimage-podman` appears in `ACTIVE_MODULES`,
  `_module_enabled()` and the `steps` table, and is absent from
  `BUNDLE_MODULES`.

On-device smoke checks to document rather than automate:

```
podman inspect portainer --format '{{index .Config.Labels "io.containers.autoupdate"}}'   # registry
podman inspect portainer --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}'        # portainer.service
podman network inspect podman --format '{{.IPv6Enabled}}'                                 # true
podman auto-update --dry-run
systemctl list-timers podman-auto-update.timer
```

## Documentation surface

`README.md` plus `docs/configuration.md`, `docs/post-flash-setup.md`,
`docs/architecture.md`, `docs/banner-and-updates.md`, `docs/hardware.md`,
`docs/flash.md`. `docs/tools-container.md` and `docs/ci-cd.md` describe the
build host and stay as they are.

The base variant description in `config/variants/base.json` is customer-
visible text: it reaches the MOTD of every device via `release.env`, the
Raspberry Pi Imager OS list via `rpi-imager.json`, and the GitHub Pages
landing page. It changes from "Docker-ready" to:

> Podman-ready (Docker-compatible), Portainer preinstalled

`docs/hardware.md` argues for `runtime_sec=15` on the watchdog partly from
"a Docker host with container healthchecks" producing PID 1 fork storms.
The conclusion stands; the rationale needs rewording for a daemonless runtime.

## Open follow-ups, out of scope here

- The memory cgroup controller is off by default on Raspberry Pi OS (no
  `cgroup_enable=memory cgroup_memory=1` in `cmdline.txt`), so container
  memory limits are accepted and silently ignored. This is true today under
  Docker as well — a pre-existing property, not a regression. The repo does
  not manage `cmdline.txt` at all, and `apply-lib.sh` denies writing it.
- CI renders only `canbus-plattform` before the parity test runs, so local
  and CI parity coverage differ. Unrelated to this change.
