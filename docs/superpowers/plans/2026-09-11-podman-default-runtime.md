# Podman Default Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Podman with Docker CLI emulation the default container runtime of the bgRPIImage base image, run Portainer CE `:lts` on it via Quadlet with auto-update, and keep the Docker stack as a supported non-default option.

**Architecture:** A new CustomPiOS module `bgrpiimage-podman` is added as a sibling of the untouched `bgrpiimage-docker`. `scripts/generate.py` renders its payload from a new `podman` block in the variant JSON, and `_module_enabled()` activates exactly one of the two runtimes. Portainer's renderer branches on the active runtime: Docker keeps today's compose file, Podman gets two Quadlet unit files and no first-boot oneshot at all.

**Tech Stack:** Python 3 (`scripts/generate.py`, `jsonschema`, `rich`), bash (CustomPiOS module scripts, test harness), systemd units, Podman 5.4.2 Quadlet, Debian trixie / Raspberry Pi OS arm64.

**Spec:** `docs/superpowers/specs/2026-09-11-podman-default-runtime-design.md`

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec.

- Target is Debian trixie / Raspberry Pi OS arm64 with **podman 5.4.2+ds1-2**. Verify every Podman key against `v5.4.2`, never against upstream `main` or `docs.podman.io/en/latest` — they are ahead of trixie.
- **`AutoUpdate` is valid only in `[Container]`**, never in `[Image]`. In `[Image]` it aborts generation of that unit and of every unit that `Requires=` it.
- **`Restart=` belongs in `[Service]`**, never `[Container]`. Quadlet emits no `Restart=` for `.container` units.
- **No dedicated privileged key exists** at v5.4.2 — use `PodmanArgs=--privileged`.
- **Never `systemctl enable portainer.service`.** Quadlet applies `[Install]` itself during generation; the unit does not exist at build time.
- **Enable `podman-auto-update.timer`, never `podman-auto-update.service`** — the service is `WantedBy=default.target` and would fire on every boot.
- All package installs run under `--no-install-recommends`, so every dependency must be named explicitly.
- No SELinux `:z`/`:Z` volume suffixes — Debian ships no SELinux policy.
- Generated payload under `src/modules/*/filesystem/root/opt/bgrpiimage/` is **gitignored** (`.gitignore:14`). Never `git add` it.
- `bgrpiimage-podman` gets **no `apply.sh`** and is **not** added to `BUNDLE_MODULES`. Container runtime config is reflash-only.
- The build-host Docker (`tools/Dockerfile`, `scripts/build.sh`, `docs/tools-container.md`, `docs/ci-cd.md`) is **out of scope** and must not be touched.
- **Leave the `docker` group in `users[].groups`.** Under rootful Podman the socket is root-owned and there is no socket group, so the entry is inert — but removing it is cosmetic and unachievable in the field anyway: `/etc/group` is on `BGRPI_DENY_GLOBS` (`apply-lib.sh:143`), so no update can change group membership on a flashed device. Do not "tidy" it.
- Commit messages: Conventional Commits, **past tense**, English, lowercase subject, body mandatory for non-trivial commits. Never include AI attribution unless the repo owner has said otherwise for this session.

### Accepted risks (from the spec — do not "fix" these mid-implementation)

- **Portainer 2.45.0 LTS names Podman 5.5.1 as its minimum; trixie ships 5.4.2.** The combination is empirically working on the owner's hardware but sits below the documented support floor. Do not add a backport repo to work around it — that is a separate decision, not part of this plan.
- **Rollback only covers "the new image never started."** Quadlet's default `--sdnotify=conmon` signals READY as soon as the container process spawns, so a Portainer that starts and then dies counts as a successful restart. The textbook fix (`Notify=healthy` + `HealthCmd=`) is **deliberately not implemented**: it is unconfirmed whether the arm64 Portainer image contains `/bin/sh` or an HTTP client, and an unsatisfiable healthcheck fails every start, not just updates. Task 6's pre-update backup is the mitigation instead. Document the limitation; do not add a healthcheck on your own initiative.
- **The memory cgroup controller is off by default on Raspberry Pi OS**, so container memory limits are silently ignored. This is true under Docker today — a pre-existing property, not a regression. The repo does not manage `cmdline.txt` and `apply-lib.sh` denies writing it. Out of scope.

### Refinement against the spec

The spec wrote `podman.auto_update.schedule.randomized_delay: "30m"`. This plan uses **`randomized_delay_minutes: 30`** (integer) instead, so no duration-string parser is needed. It matches how `render_unattended()` already does this arithmetic (`RandomizedDelaySec={window_minutes * 60}`). Behaviour is identical.

---

### Task 1: Config contract — schema and base variant

**Files:**

- Modify: `config/schema.json` (top-level `properties`, plus the `portainer` object)
- Modify: `config/variants/base.json`

**Interfaces:**

- Consumes: nothing (first task).
- Produces: the `podman` config block and the extended `portainer` block that every later task reads. Key paths later tasks depend on, exactly:
  `podman.enabled`, `podman.docker_emulation`, `podman.sysctl`, `podman.network.default_subnet`, `podman.network.default_subnet_pools[].base`, `podman.network.default_subnet_pools[].size`, `podman.network.ipv6`, `podman.network.subnet_v6`, `podman.journald.system_max_use`, `podman.journald.system_max_file_size`, `podman.auto_update.enabled`, `podman.auto_update.schedule.start`, `podman.auto_update.schedule.randomized_delay_minutes`, `portainer.auto_update`, `portainer.backup_before_update.enabled`, `portainer.backup_before_update.keep`.

**Context you need:** `config/schema.json` is `"additionalProperties": false` at the top level and inside `docker`/`portainer`. Any key not declared is rejected at validation time, so the schema must be extended before any variant can use the new keys. `scripts/generate.py` validates with `jsonschema.validate(resolved, schema)`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-config-guards.sh`, immediately before the `# --- stdout discipline` comment block:

```bash
echo
echo "=== podman config contract ==="
contract_rc=0
if "$PY" - <<'PYEOF'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("gen", "scripts/generate.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
cfg = gen.load_variant(Path("config/variants/base.json"))

def need(path, want=None):
    cur = cfg
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            print(f"  FAIL  base.json is missing {path}")
            return False
        cur = cur[part]
    if want is not None and cur != want:
        print(f"  FAIL  {path} is {cur!r}, expected {want!r}")
        return False
    print(f"  PASS  {path}")
    return True

ok = True
ok &= need("podman.enabled", True)
ok &= need("podman.docker_emulation", True)
# NOT via need(): the literal key is "vm.max_map_count", and need() splits
# the path on "." so it would look for cfg["podman"]["sysctl"]["vm"]["max_map_count"].
_mm = cfg.get("podman", {}).get("sysctl", {}).get("vm.max_map_count")
print(("  PASS  " if _mm == 4194304 else "  FAIL  ") + "podman.sysctl.vm.max_map_count")
ok &= (_mm == 4194304)
ok &= need("podman.network.default_subnet", "10.10.0.0/17")
ok &= need("podman.network.ipv6", True)
ok &= need("podman.network.subnet_v6", "fdff:0::/64")
ok &= need("podman.journald.system_max_use", "200M")
ok &= need("podman.auto_update.enabled", True)
ok &= need("podman.auto_update.schedule.start", "05:30")
ok &= need("podman.auto_update.schedule.randomized_delay_minutes", 30)
ok &= need("docker.enabled", False)
ok &= need("portainer.image", "docker.io/portainer/portainer-ce:lts")
ok &= need("portainer.auto_update", True)
ok &= need("portainer.backup_before_update.enabled", True)
ok &= need("portainer.backup_before_update.keep", 5)
sys.exit(0 if ok else 1)
PYEOF
then :; else contract_rc=1; fi
```

Then change the final line of the file from:

```bash
[ "$guards_rc" -eq 0 ] && [ "$json_rc" -eq 0 ]
```

to:

```bash
[ "$guards_rc" -eq 0 ] && [ "$json_rc" -eq 0 ] && [ "$contract_rc" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-config-guards.sh`
Expected: the `=== podman config contract ===` block prints `FAIL base.json is missing podman.enabled` and the script exits non-zero.

- [ ] **Step 3: Add the `podman` block to the schema**

In `config/schema.json`, inside the top-level `"properties"` object, add immediately after the `"docker"` entry:

```json
"podman": {
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "enabled": { "type": "boolean" },
    "docker_emulation": { "type": "boolean" },
    "sysctl": {
      "type": "object",
      "additionalProperties": { "type": ["integer", "string"] }
    },
    "network": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "default_subnet": { "type": "string" },
        "default_subnet_pools": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["base", "size"],
            "properties": {
              "base": { "type": "string" },
              "size": { "type": "integer" }
            }
          }
        },
        "ipv6": { "type": "boolean" },
        "subnet_v6": { "type": "string" },
        "firewall_driver": {
          "type": "string",
          "enum": ["iptables", "nftables", "none", "firewalld"]
        }
      }
    },
    "journald": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "system_max_use": { "type": "string" },
        "system_max_file_size": { "type": "string" }
      }
    },
    "auto_update": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "enabled": { "type": "boolean" },
        "schedule": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "start": { "type": "string", "pattern": "^[0-2][0-9]:[0-5][0-9]$" },
            "randomized_delay_minutes": { "type": "integer", "minimum": 0 },
            "persistent": { "type": "boolean" }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 4: Extend the `portainer` schema object**

In `config/schema.json`, inside the `"portainer"` object's `"properties"`, add after `"auto_start"`:

```json
"auto_update": { "type": "boolean" },
"backup_before_update": {
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "enabled": { "type": "boolean" },
    "keep": { "type": "integer", "minimum": 1 }
  }
}
```

- [ ] **Step 5: Update `config/variants/base.json`**

Change `docker.enabled` from `true` to `false`. Leave the rest of the `docker` block exactly as it is — the Docker path stays supported.

Add a `podman` block immediately after the `docker` block:

```json
"podman": {
  "enabled": true,
  "docker_emulation": true,
  "sysctl": {
    "vm.max_map_count": 4194304
  },
  "network": {
    "default_subnet": "10.10.0.0/17",
    "default_subnet_pools": [
      { "base": "10.10.128.0/17", "size": 24 }
    ],
    "ipv6": true,
    "subnet_v6": "fdff:0::/64"
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
},
```

In the `portainer` block: change `"image"` from `"portainer/portainer-ce:2.45.0"` to `"docker.io/portainer/portainer-ce:lts"`, and add after `"auto_start": true`:

```json
"auto_update": true,
"backup_before_update": { "enabled": true, "keep": 5 }
```

Change `variant.description` from:

> `BAUER GROUP generic Raspberry Pi base image - Docker-ready, no application-specific hardware configured`

to:

> `BAUER GROUP generic Raspberry Pi base image - Podman-ready (Docker-compatible), Portainer preinstalled, no application-specific hardware configured`

This string is customer-visible: it reaches every device's MOTD through `release.env`, the Raspberry Pi Imager OS list through `rpi-imager.json`, and the GitHub Pages landing page.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test-config-guards.sh`
Expected: every line in `=== podman config contract ===` prints `PASS`, and the script exits 0.

- [ ] **Step 7: Verify all variants still validate**

Run: `make validate`
Expected: `ok: config/variants/base.json valid` plus the same for both canbus variants. A `jsonschema.ValidationError` here means a key was added to a variant but not to the schema.

- [ ] **Step 8: Commit**

```bash
git add config/schema.json config/variants/base.json tests/test-config-guards.sh
git commit -m "feat(config): added the podman runtime block to the schema

Declares a `podman` config block mirroring `docker`, so the two
runtimes are selected by the same enabled-flag pattern every other
module already uses. base.json switches the default over: docker
off, podman on.

* vm.max_map_count moves into the podman block. It lived only under
  `docker` and is runtime-agnostic, so flipping docker off would have
  silently deleted it from the image with no test noticing.
* portainer.image becomes fully qualified (docker.io/...) - podman
  resolves short names through unqualified-search-registries, which
  this image does not ship, and AutoUpdate=registry requires an FQN.
* The variant description is customer-visible (MOTD, rpi-imager OS
  list, Pages landing page), so it stops claiming Docker."
```

---

### Task 2: Semantic guards

**Files:**

- Modify: `scripts/generate.py` — `_semantic_validate()` at line 2104
- Modify: `tests/test-config-guards.sh`

**Interfaces:**

- Consumes: the config keys produced by Task 1.
- Produces: a module-level helper `_hhmm_to_minutes(value: str) -> int` and the guard behaviour that Task 6's schedule relies on. No other task calls the guards directly.

**Context you need:** `_semantic_validate(cfg)` raises `ValueError` with a human-readable message. The test harness's `refuses(label, mutate, needle, child=FD)` asserts that a mutation raises with `needle` as a case-insensitive substring; `accepts(label, child, mutate)` asserts it does not raise. `FD`, `CLASSIC` and `BASE` are pre-resolved configs. There is already a `_window_minutes(start_hhmm, end_hhmm) -> int` helper near line 2227.

- [ ] **Step 1: Write the failing tests**

In `tests/test-config-guards.sh`, insert before the `# --- stdout discipline` block:

```bash
echo
echo "=== container runtime guards ==="
```

Then inside the embedded Python (before the final `guards_rc` computation), add:

```python
print()
print("=== container runtime guards ===")

refuses(
    "docker and podman both enabled",
    lambda c: (c.setdefault("docker", {}).__setitem__("enabled", True),
               c.setdefault("podman", {}).__setitem__("enabled", True)),
    "mutually exclusive",
    child=BASE,
)
accepts("podman only", child=BASE)
accepts(
    "docker only",
    child=BASE,
    mutate=lambda c: (c["docker"].__setitem__("enabled", True),
                      c["podman"].__setitem__("enabled", False)),
)
refuses(
    "portainer auto_update without the podman timer",
    lambda c: c["podman"]["auto_update"].__setitem__("enabled", False),
    "podman.auto_update.enabled",
    child=BASE,
)
refuses(
    "auto_update against a digest-pinned image",
    lambda c: c["portainer"].__setitem__(
        "image", "docker.io/portainer/portainer-ce@sha256:"
                 "511f3f06c96fe3b993ebeaafde311c1959cae73a7ef825dba6397d51b450dffa"),
    "digest-pinned",
    child=BASE,
)
refuses(
    "auto-update window overlaps the unattended-upgrades window",
    lambda c: c["podman"]["auto_update"]["schedule"].__setitem__("start", "02:30"),
    "overlaps",
    child=BASE,
)
refuses(
    "auto-update window overlaps the reboot window",
    lambda c: c["podman"]["auto_update"]["schedule"].__setitem__("start", "04:30"),
    "overlaps",
    child=BASE,
)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test-config-guards.sh`
Expected: every line under `=== container runtime guards ===` except the two `accepts` prints `FAIL ... built without complaint`.

- [ ] **Step 3: Add the time helper**

In `scripts/generate.py`, directly above `def _semantic_validate(`, add:

```python
def _hhmm_to_minutes(value: str) -> int:
    """"HH:MM" -> minutes since midnight. Raises ValueError on junk."""
    hh, _, mm = value.partition(":")
    return int(hh) * 60 + int(mm)


def _windows_overlap(a_start: int, a_len: int, b_start: int, b_len: int) -> bool:
    """Do two [start, start+len) minute windows intersect on a 24h clock?

    Both windows are unrolled onto a 48h axis so a window that wraps past
    midnight (reboot 23:00-01:00) still compares correctly against one that
    does not.
    """
    for shift in (0, 1440):
        if a_start + shift < b_start + b_len and b_start < a_start + shift + a_len:
            return True
        if b_start + shift < a_start + a_len and a_start < b_start + shift + b_len:
            return True
    return False
```

- [ ] **Step 4: Add the guards**

At the end of `_semantic_validate()`, append:

```python
    # Exactly one container runtime. Both modules install a /usr/bin/docker
    # and both claim the container storage; the image that ships with both
    # is not "belt and braces", it is undefined.
    docker_on = bool((cfg.get("docker") or {}).get("enabled"))
    podman_on = bool((cfg.get("podman") or {}).get("enabled"))
    if docker_on and podman_on:
        raise ValueError(
            "docker.enabled and podman.enabled are mutually exclusive - pick one "
            "container runtime per variant"
        )

    portainer = cfg.get("portainer") or {}
    podman = cfg.get("podman") or {}
    au = podman.get("auto_update") or {}

    if portainer.get("auto_update"):
        if not podman_on:
            raise ValueError(
                "portainer.auto_update=true requires podman.enabled=true - "
                "auto-update is a podman mechanism and does nothing under Docker"
            )
        if not au.get("enabled"):
            raise ValueError(
                "portainer.auto_update=true requires podman.auto_update.enabled=true "
                "- without the timer the AutoUpdate=registry label is inert"
            )
        if "@sha256:" in str(portainer.get("image", "")):
            raise ValueError(
                "portainer.auto_update=true is incompatible with a digest-pinned "
                "portainer.image - the remote digest can never differ, so the "
                "update would never fire"
            )

    # The device reboots itself inside the unattended-upgrades reboot window,
    # and Portainer migrates its database one-way on startup. An update that
    # takes a scripted reboot mid-migration leaves a portainer.db that no
    # version can open - a truck roll, not a retry.
    if podman_on and au.get("enabled"):
        sched = au.get("schedule") or {}
        start = _hhmm_to_minutes(sched.get("start", "05:30"))
        length = int(sched.get("randomized_delay_minutes", 30))
        uu = cfg.get("unattended_upgrades") or {}
        if uu.get("enabled"):
            uu_sched = uu.get("schedule") or {}
            uu_start = _hhmm_to_minutes(uu_sched.get("start", "02:00"))
            uu_len = _window_minutes(
                uu_sched.get("start", "02:00"), uu_sched.get("end", "04:00")
            )
            if _windows_overlap(start, length, uu_start, uu_len):
                raise ValueError(
                    f"podman.auto_update.schedule ({sched.get('start')} +{length}m) "
                    f"overlaps the unattended_upgrades window "
                    f"({uu_sched.get('start')}-{uu_sched.get('end')})"
                )
            reboot = uu.get("auto_reboot") or {}
            if reboot.get("enabled"):
                win = reboot.get("window") or {}
                r_start = _hhmm_to_minutes(win.get("start", "03:00"))
                r_len = _window_minutes(
                    win.get("start", "03:00"), win.get("end", "05:00")
                )
                if _windows_overlap(start, length, r_start, r_len):
                    raise ValueError(
                        f"podman.auto_update.schedule ({sched.get('start')} "
                        f"+{length}m) overlaps the auto-reboot window "
                        f"({win.get('start')}-{win.get('end')}) - a reboot during "
                        "Portainer's one-way database migration is unrecoverable"
                    )
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test-config-guards.sh`
Expected: all lines under `=== container runtime guards ===` print `PASS`, and the shipped-variant checks at the top of the file still pass.

- [ ] **Step 6: Verify the shipped variants still validate**

Run: `make validate`
Expected: all three variants report `ok`. If `base.json` is now refused, the schedule in Task 1 overlaps a window — the default `05:30 +30m` is clear of both `02:00-04:00` and `03:00-05:00`.

- [ ] **Step 7: Commit**

```bash
git add scripts/generate.py tests/test-config-guards.sh
git commit -m "feat(config): refused configs that break the podman runtime

Four cross-field guards that JSON Schema cannot express:

* docker.enabled and podman.enabled are mutually exclusive
* portainer.auto_update needs podman.auto_update.enabled, otherwise
  the AutoUpdate=registry label sits on the container doing nothing
* portainer.auto_update against a digest-pinned image never fires,
  because the remote digest can never differ
* the auto-update window must not overlap the unattended-upgrades
  or auto-reboot windows. Portainer migrates its database one-way on
  startup; a scripted reboot landing mid-migration produces a
  portainer.db that no version will open."
```

---

### Task 3: `render_podman()` — the runtime payload

**Files:**

- Modify: `scripts/generate.py` — add `render_podman()` directly after `render_docker()` (which ends at line 1639)
- Create: `tests/test-render-podman.sh`
- Modify: `Makefile`

**Interfaces:**

- Consumes: the `podman` config block from Task 1.
- Produces: `def render_podman(cfg: dict[str, Any]) -> None`, and these payload filenames under `src/modules/bgrpiimage-podman/filesystem/root/opt/bgrpiimage/bgrpiimage-podman/`, which Task 5's `start_chroot_script` installs by exactly these names:
  `containers.conf`, `podman-network.json`, `98-podman.conf`, `99-bgrpiimage-containers.conf`, `nodocker`, `podman.env`, `.disabled` (only when disabled).

**Context you need:** `clean_generated(module)` wipes and recreates the payload dir and returns its `Path`. `write(path, content)` writes UTF-8 with LF endings. `shell_var(name, value)` renders a shell assignment with booleans as `yes`/`no`. Look at `render_docker()` (line 1559) for the shape: it writes a `.disabled` marker and returns early when the block is off.

- [ ] **Step 1: Write the failing test**

Create `tests/test-render-podman.sh`:

```bash
#!/usr/bin/env bash
# Asserts render_podman() and the podman branch of render_portainer() emit
# what the modules install.
#
# These are positives, but the failure they guard against is silent: a
# Quadlet unit with a key in the wrong section generates without complaint
# on the build host and only fails on the device, at first boot, in the
# field. Nothing else in the suite ever parses the rendered units.
#
#   bash tests/test-render-podman.sh    # or: make test-render-podman
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

PY=""
for cand in "${PY_OVERRIDE:-}" python3 python; do
    [ -n "$cand" ] || continue
    if "$cand" -c 'import sys' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "no working python3/python on PATH" >&2; exit 1; }

"$PY" - <<'PYEOF'
import importlib.util, json, sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
spec = importlib.util.spec_from_file_location("gen", "scripts/generate.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

import io as _io
from rich.console import Console as _Console
gen.err_console = _Console(file=_io.StringIO())

cfg = gen.load_variant(Path("config/variants/base.json"))
gen.render_podman(cfg)

GEN = Path("src/modules/bgrpiimage-podman/filesystem/root/opt/bgrpiimage/bgrpiimage-podman")

passed = failed = 0

def report(good, label, detail=""):
    global passed, failed
    if good:
        passed += 1
        print(f"  PASS  {label}")
    else:
        failed += 1
        print(f"  FAIL  {label}")
        if detail:
            print(f"        {detail}")

def body(name):
    p = GEN / name
    return p.read_text(encoding="utf-8") if p.is_file() else ""

print("=== render_podman payload ===")
for name in ("containers.conf", "podman-network.json", "98-podman.conf",
             "99-bgrpiimage-containers.conf", "nodocker", "podman.env"):
    report((GEN / name).is_file(), f"emits {name}")

print()
print("=== containers.conf ===")
cc = body("containers.conf")
report('default_subnet = "10.10.0.0/17"' in cc, "default_subnet is the fleet plan")
report('{"base" = "10.10.128.0/17", "size" = 24}' in cc,
       "default_subnet_pools uses quoted-key inline tables")
report("[network]" in cc, "has a [network] section")

print()
print("=== the netavark network definition ===")
try:
    net = json.loads(body("podman-network.json"))
except Exception as exc:
    net = {}
    report(False, "podman-network.json parses", str(exc))
else:
    report(True, "podman-network.json parses")
report(net.get("name") == "podman",
       "name is 'podman' (must match the filename or netavark skips it)")
report(isinstance(net.get("id"), str) and len(net.get("id", "")) == 64,
       "id is 64 hex chars (a short id is skipped with only a log line)")
report(net.get("ipv6_enabled") is True, "ipv6_enabled is true")
report(any(":" in s.get("subnet", "") for s in net.get("subnets", [])),
       "carries an IPv6 subnet")
report(any("." in s.get("subnet", "") for s in net.get("subnets", [])),
       "carries an IPv4 subnet")

print()
print("=== sysctl and journald ===")
report("vm.max_map_count=4194304" in body("98-podman.conf").replace(" ", ""),
       "vm.max_map_count survived the move off the docker block")
jd = body("99-bgrpiimage-containers.conf")
report("[Journal]" in jd and "SystemMaxUse=200M" in jd,
       "journald cap replaces docker's json-file cap")

print()
print(f"{passed} passed, {failed} failed")
sys.exit(0 if failed == 0 else 1)
PYEOF
```

Make it executable and add the Makefile target. In `Makefile`, after the `test-config-guards` target, add:

```makefile
.PHONY: test-render-podman
test-render-podman: ## assert the podman + quadlet payload renders correctly (no docker)
	bash tests/test-render-podman.sh
```

and add `test-render-podman` to the `test` target's prerequisite list, after `test-config-guards`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-render-podman.sh`
Expected: `AttributeError: module 'gen' has no attribute 'render_podman'`.

- [ ] **Step 3: Implement `render_podman()`**

In `scripts/generate.py`, directly after `render_docker()` ends (line 1639, before `def render_portainer(`):

```python
# netavark's own id for the built-in default network. Reusing it keeps
# `podman network inspect podman` byte-identical to a stock install; a
# different id is legal but makes every diff against a stock box noise.
_NETAVARK_DEFAULT_NETWORK_ID = (
    "2f259bab93aaaaa2542ba43ef33eb990d0999ee1b9924b557b7be53c0b7a1bb9"
)


def render_podman(cfg: dict[str, Any]) -> None:
    gen = clean_generated("bgrpiimage-podman")
    p = cfg.get("podman") or {}
    if not p.get("enabled"):
        write(gen / ".disabled", "")
        return

    net = p.get("network") or {}

    # containers.conf carries the IPv4 half of the address plan. The IPv6
    # half cannot live here: containers.conf has no key that enables IPv6
    # on the default network - the only declarative path is the network
    # definition file written below.
    cc = ["# Auto-generated by scripts/generate.py", "", "[network]"]
    if net.get("default_subnet"):
        cc.append(f'default_subnet = "{net["default_subnet"]}"')
    pools = net.get("default_subnet_pools") or []
    if pools:
        cc.append("default_subnet_pools = [")
        for pool in pools:
            cc.append(f'  {{"base" = "{pool["base"]}", "size" = {pool["size"]}}},')
        cc.append("]")
    if net.get("firewall_driver"):
        cc.append(f'firewall_driver = "{net["firewall_driver"]}"')
    write(gen / "containers.conf", "\n".join(cc) + "\n")

    # /etc/containers/networks/podman.json - loaded by netavark on the next
    # podman invocation, no daemon to restart. Two silent failure modes:
    # the filename must match the `name` field, and `id` must be 64 hex
    # chars. Violate either and netavark skips the file with nothing but a
    # log line, falling back to a stock IPv4-only default network.
    subnets: list[dict[str, Any]] = []
    if net.get("default_subnet"):
        subnets.append({"subnet": net["default_subnet"]})
    if net.get("ipv6") and net.get("subnet_v6"):
        subnets.append({"subnet": net["subnet_v6"]})
    network = {
        "name": "podman",
        "id": _NETAVARK_DEFAULT_NETWORK_ID,
        "driver": "bridge",
        "network_interface": "podman0",
        "subnets": subnets,
        "ipv6_enabled": bool(net.get("ipv6")),
        "internal": False,
        "dns_enabled": True,
    }
    write(gen / "podman-network.json", json.dumps(network, indent=2) + "\n")

    # Runtime-agnostic kernel setting. It lived under `docker` until the
    # runtime switch; any container workload that mmaps heavily needs it
    # regardless of which engine starts the container.
    sysctl = p.get("sysctl") or {}
    lines = ["# Auto-generated by scripts/generate.py"]
    for key, value in sysctl.items():
        lines.append(f"{key}={value}")
    write(gen / "98-podman.conf", "\n".join(lines) + "\n")

    # Podman logs containers to journald, which this image did not bound
    # before: Docker's json-file driver capped them at 10m x 3 and that cap
    # leaves with Docker. Unbounded container logs on an SD card is a
    # wear-out, not an inconvenience.
    jd = p.get("journald") or {}
    write(
        gen / "99-bgrpiimage-containers.conf",
        "# Auto-generated by scripts/generate.py\n"
        "[Journal]\n"
        f"SystemMaxUse={jd.get('system_max_use', '200M')}\n"
        f"SystemMaxFileSize={jd.get('system_max_file_size', '20M')}\n",
    )

    # Presence alone suppresses "Emulate Docker CLI using podman" on every
    # docker(1) invocation. Content is irrelevant.
    write(gen / "nodocker", "")

    au = p.get("auto_update") or {}
    write(
        gen / "podman.env",
        shell_var("BGRPIIMAGE_PODMAN_DOCKER_EMULATION", p.get("docker_emulation", True))
        + shell_var("BGRPIIMAGE_PODMAN_AUTO_UPDATE", au.get("enabled", False)),
    )
```

Confirm `json` is already imported at the top of `generate.py` — it is, since `load_variant()` uses it.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-render-podman.sh`
Expected: every assertion under `=== render_podman payload ===`, `=== containers.conf ===`, `=== the netavark network definition ===` and `=== sysctl and journald ===` prints `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/generate.py tests/test-render-podman.sh Makefile
git commit -m "feat(podman): rendered the podman runtime payload

render_podman() emits the six files the module installs: containers.conf,
the netavark default-network definition, the sysctl drop-in, a journald
cap, the nodocker marker and podman.env.

* The IPv4 address plan goes in containers.conf. The IPv6 half cannot:
  containers.conf has no key that enables IPv6 on the default network,
  so the only declarative path is /etc/containers/networks/podman.json.
* That file has two silent failure modes worth the comment in the code -
  the filename must match the `name` field and `id` must be 64 hex chars,
  or netavark skips it and falls back to IPv4-only with only a log line.
  The new test asserts both.
* The journald cap is new, not ported. Docker's json-file driver capped
  container logs at 10m x 3 and that cap leaves with Docker; nothing else
  in the tree bounds log growth, on devices that boot off SD cards."
```

---

### Task 4: The module and its generator wiring

**Files:**

- Create: `src/modules/bgrpiimage-podman/config`
- Create: `src/modules/bgrpiimage-podman/start_chroot_script`
- Modify: `scripts/generate.py` — `ACTIVE_MODULES` (line 2242), `_module_enabled()` (line 2282), the `steps` table (line 2409)
- Modify: `tests/test-render-podman.sh`

**Interfaces:**

- Consumes: `render_podman()` and its payload filenames from Task 3.
- Produces: the module name `bgrpiimage-podman` in `ACTIVE_MODULES`, `_module_enabled()` and `steps`. Task 5 and Task 6 assume the module is built.

**Context you need:** These three lists are independent and nothing asserts they agree. A module in `steps` but not `ACTIVE_MODULES` renders its payload and is then never built. A module in `ACTIVE_MODULES` but not `steps` is built with an empty payload directory. `_module_enabled()` is also read by `scripts/bundle.py:95`, which is why `bgrpiimage-podman` must stay out of `BUNDLE_MODULES`.

CustomPiOS copies `module/filesystem/` into the chroot root; `unpack /filesystem/root / root` then moves it to `/`. So the payload lands at `/opt/bgrpiimage/bgrpiimage-podman/` inside the chroot, and `start_chroot_script` installs from there.

- [ ] **Step 1: Write the failing test**

Append to the embedded Python in `tests/test-render-podman.sh`, before the final `print(f"{passed} passed...")`:

```python
print()
print("=== module wiring ===")
report("bgrpiimage-podman" in gen.ACTIVE_MODULES, "in ACTIVE_MODULES")
report(gen._module_enabled("bgrpiimage-podman", cfg), "enabled for base.json")
report(not gen._module_enabled("bgrpiimage-docker", cfg),
       "bgrpiimage-docker is off for base.json")
report(gen.ACTIVE_MODULES.index("bgrpiimage-podman")
       < gen.ACTIVE_MODULES.index("bgrpiimage-portainer"),
       "podman is built before portainer")

bundle_src = Path("scripts/bundle.py").read_text(encoding="utf-8")
report("bgrpiimage-podman" not in bundle_src,
       "stays out of BUNDLE_MODULES (runtime config is reflash-only)")

mod = Path("src/modules/bgrpiimage-podman")
report((mod / "config").is_file(), "module has a config file")
report((mod / "start_chroot_script").is_file(), "module has a start_chroot_script")
report(not (mod / "apply.sh").exists(),
       "module has no apply.sh (matches docker/portainer)")


sc = (mod / "start_chroot_script").read_text(encoding="utf-8") \
    if (mod / "start_chroot_script").is_file() else ""
for pkg in ("podman", "podman-docker", "netavark", "aardvark-dns", "nftables"):
    report(pkg in sc, f"installs {pkg}")
report("nftables" in sc,
       "installs nftables explicitly (netavark only Recommends it)")
report("podman-auto-update.service" not in sc.replace("podman-auto-update.timer", ""),
       "never enables podman-auto-update.service")
```

Remove the bogus `import scripts.bundle if False else None` line — that is not valid Python. Use only:

```python
bundle_src = Path("scripts/bundle.py").read_text(encoding="utf-8")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-render-podman.sh`
Expected: `FAIL in ACTIVE_MODULES`, `FAIL module has a config file`, `FAIL module has a start_chroot_script` and the per-package assertions all fail.

- [ ] **Step 3: Create the module config**

Create `src/modules/bgrpiimage-podman/config` with exactly:

```bash
BGRPIIMAGE_PODMAN_MODULE=1
```

- [ ] **Step 4: Create the chroot script**

Create `src/modules/bgrpiimage-podman/start_chroot_script`:

```bash
#!/usr/bin/env bash
# bgrpiimage-podman: install Podman with Docker CLI emulation as the image's
# container runtime.
#
# Everything here is a file drop plus `systemctl enable`. Nothing needs a
# live podman: the network definition is read by netavark on first use, and
# Quadlet units (bgrpiimage-portainer) are generated by systemd at boot.
set -x
set -e
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

source /common.sh
install_cleanup_trap

unpack /filesystem/root / root

GEN=/opt/bgrpiimage/bgrpiimage-podman

# Remove Docker CE if a previous module or the base image left it behind.
# The two runtimes both own /usr/bin/docker and the container storage.
for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
           docker-compose-plugin docker-ce-rootless-extras docker.io docker-compose; do
    apt-get remove -y "$pkg" 2>/dev/null || true
done
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc

apt-get update
# Explicit list, because every install in this project runs with
# --no-install-recommends. netavark only *Recommends* nftables while using it
# as its compiled-in default firewall driver, so leaving it implicit builds a
# clean image whose container networking comes up with no firewall rules.
apt-get install -y --no-install-recommends \
    podman podman-docker containers-common netavark aardvark-dns \
    nftables uidmap catatonit

# Podman reads this on the next invocation; there is no daemon to restart.
if [[ -f "$GEN/containers.conf" ]]; then
    install -D -m 644 "$GEN/containers.conf" /etc/containers/containers.conf
fi

# Filename MUST stay podman.json - netavark matches it against the `name`
# field and silently skips the file otherwise.
if [[ -f "$GEN/podman-network.json" ]]; then
    install -D -m 644 "$GEN/podman-network.json" /etc/containers/networks/podman.json
fi

if [[ -f "$GEN/98-podman.conf" ]]; then
    install -D -m 644 "$GEN/98-podman.conf" /etc/sysctl.d/98-podman.conf
fi

if [[ -f "$GEN/99-bgrpiimage-containers.conf" ]]; then
    install -D -m 644 "$GEN/99-bgrpiimage-containers.conf" \
        /etc/systemd/journald.conf.d/99-bgrpiimage-containers.conf
fi

# shellcheck disable=SC1091
source "$GEN/podman.env" 2>/dev/null || true

# Presence suppresses the "Emulate Docker CLI using podman" notice that
# podman-docker otherwise prints on every docker(1) call.
if [[ "${BGRPIIMAGE_PODMAN_DOCKER_EMULATION:-yes}" == "yes" ]]; then
    install -D -m 644 "$GEN/nodocker" /etc/containers/nodocker
fi

# The Docker-compatible API socket Portainer binds. podman-docker ships the
# tmpfiles drop-in that links /run/docker.sock to it, so no symlink here.
systemctl enable podman.socket
# Brings back operator-created containers that use --restart=always. The
# Portainer container does not need it: its Quadlet unit is WantedBy
# multi-user.target and systemd starts it directly.
systemctl enable podman-restart.service

apt-get clean
```

Mark it executable: `chmod +x src/modules/bgrpiimage-podman/start_chroot_script`

- [ ] **Step 5: Wire the module into the generator**

In `scripts/generate.py`, in `ACTIVE_MODULES` (line 2242), insert `"bgrpiimage-podman",` immediately **before** `"bgrpiimage-docker",`. Ordering matters: the runtime must be installed before `bgrpiimage-portainer` drops its Quadlet units.

In `_module_enabled()`, add after the `bgrpiimage-docker` branch:

```python
    if module == "bgrpiimage-podman":
        return bool((cfg.get("podman") or {}).get("enabled"))
```

In the `steps` table (line 2409), add before the `bgrpiimage-docker` entry:

```python
        ("bgrpiimage-podman",               render_podman),
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test-render-podman.sh`
Expected: all `=== module wiring ===` assertions print `PASS`.

- [ ] **Step 7: Verify the variant config picks the module up**

Run: `make render VARIANT=base`
Then: `grep MODULES src/variants/base/config`
Expected: the `MODULES=` line contains `bgrpiimage-podman` and does **not** contain `bgrpiimage-docker`.

- [ ] **Step 8: Commit**

```bash
git add src/modules/bgrpiimage-podman scripts/generate.py tests/test-render-podman.sh
git commit -m "feat(podman): added the bgrpiimage-podman module

Installs podman with Docker CLI emulation and enables podman.socket
plus podman-restart.service. Sibling of bgrpiimage-docker, which is
left untouched - the Docker stack stays supported, just not default.

* The package list is explicit because every install in this project
  runs --no-install-recommends. netavark only Recommends nftables
  while using it as its compiled-in default firewall driver, so an
  implicit dependency would build a clean image whose container
  networking has no firewall rules.
* No apply.sh and no BUNDLE_MODULES entry, matching bgrpiimage-docker
  and bgrpiimage-portainer: container runtime config is reflash-only.
* ACTIVE_MODULES, _module_enabled() and the steps table are three
  independent lists that nothing asserts agree - the new test covers
  that, including that podman is ordered before portainer."
```

---

### Task 5: Portainer via Quadlet

**Files:**

- Modify: `scripts/generate.py` — `render_portainer()` at line 1642
- Modify: `src/modules/bgrpiimage-portainer/start_chroot_script`
- Modify: `tests/test-render-podman.sh`

**Interfaces:**

- Consumes: `podman.enabled` (Task 1) to choose the branch; the module wiring from Task 4.
- Produces: payload files `portainer.container` and `portainer.image` under the `bgrpiimage-portainer` payload dir when Podman is active. Task 6 adds `podman-auto-update.timer.d/override.conf` and friends to the **podman** module, not this one.

**Context you need:** `render_portainer()` currently always writes `docker-compose.yml`, `bgrpiimage-portainer-install.service` and `portainer.env`. The `port()` closure at line 1664 encodes dual-stack semantics: when `bind` is `0.0.0.0` the host IP is **omitted** so the listener covers both `0.0.0.0:PORT` and `[::]:PORT`. `PublishPort` takes the same `[IP:]host:container` syntax, so the same closure works.

- [ ] **Step 1: Write the failing test**

Append to the embedded Python in `tests/test-render-podman.sh`, before the final summary:

```python
print()
print("=== portainer quadlet units ===")
gen.render_portainer(cfg)
PGEN = Path("src/modules/bgrpiimage-portainer/filesystem/root/opt/bgrpiimage/bgrpiimage-portainer")

def pbody(name):
    p = PGEN / name
    return p.read_text(encoding="utf-8") if p.is_file() else ""

container = pbody("portainer.container")
image = pbody("portainer.image")

report(bool(container), "emits portainer.container")
report(bool(image), "emits portainer.image")
report(not (PGEN / "docker-compose.yml").exists(),
       "emits no compose file under podman")
report(not (PGEN / "bgrpiimage-portainer-install.service").exists(),
       "emits no first-boot oneshot under podman")

report("[Image]" in image and "docker.io/portainer/portainer-ce:lts" in image,
       ".image unit pulls the fully qualified :lts tag")
report("AutoUpdate" not in image,
       "AutoUpdate is absent from [Image] (it aborts generation there)")

report("Image=portainer.image" in container,
       ".container references the .image unit")
report("AutoUpdate=registry" in container, "[Container] carries AutoUpdate=registry")
report("PodmanArgs=--privileged" in container,
       "privileged via PodmanArgs (no dedicated key exists at 5.4.2)")
report("Volume=/run/podman/podman.sock:/var/run/docker.sock" in container,
       "podman socket bound where Portainer looks for the docker socket")
report(":z" not in container and ":Z" not in container,
       "no SELinux relabel suffix (Debian ships no policy)")
for port in ("8000:8000", "9000:9000", "9443:9443"):
    report(f"PublishPort={port}" in container, f"publishes {port}")

svc = container.split("[Service]", 1)[-1].split("[Install]", 1)[0]
cont_section = container.split("[Container]", 1)[-1].split("[Service]", 1)[0]
report("Restart=always" in svc, "Restart=always is in [Service]")
report("Restart=" not in cont_section,
       "Restart= is NOT in [Container] (quadlet would ignore it)")
report("WantedBy=multi-user.target" in container, "[Install] makes it start on boot")
report("After=podman.socket" in container, "ordered after podman.socket")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-render-podman.sh`
Expected: `FAIL emits portainer.container` and every following Quadlet assertion fails.

- [ ] **Step 3: Branch `render_portainer()` on the runtime**

In `scripts/generate.py`, inside `render_portainer()`, after the `port()` closure is defined (after line 1668) and **before** the `compose = (` assignment, insert:

```python
    if (cfg.get("podman") or {}).get("enabled"):
        # Quadlet. No compose file, no first-boot oneshot: systemd's
        # generator turns these two files into units at boot and applies
        # their [Install] section itself, so there is nothing to enable in
        # the chroot.
        write(
            gen / "portainer.image",
            "# Auto-generated by bgRPIImage\n"
            "[Image]\n"
            f"Image={image}\n",
        )

        # PublishPort takes the same [IP:]host:container syntax as
        # `podman run --publish`, so the dual-stack rule is unchanged: with
        # bind=0.0.0.0 the host IP is omitted and the listener covers v4
        # and v6; naming 0.0.0.0 explicitly would pin it to v4 only.
        def qport(host_port: int, container_port: int) -> str:
            if bind in ("0.0.0.0", "", None):
                return f"PublishPort={host_port}:{container_port}"
            return f"PublishPort={bind}:{host_port}:{container_port}"

        auto_update = "AutoUpdate=registry\n" if p.get("auto_update") else ""
        unit = (
            "# Auto-generated by bgRPIImage\n"
            "[Unit]\n"
            "Description=Portainer CE\n"
            "Requires=podman.socket\n"
            "After=podman.socket\n"
            "\n"
            "[Container]\n"
            # Resolves to the .image unit above, which makes the generated
            # service depend on portainer-image.service. Without it the
            # first pull counts against this unit's start timeout.
            "Image=portainer.image\n"
            "ContainerName=portainer\n"
            f"{auto_update}"
            f"{qport(edge, 8000)}\n"
            f"{qport(http, 9000)}\n"
            f"{qport(https, 9443)}\n"
            # Portainer's own Podman install docs bind the podman socket at
            # the path the Docker client defaults to. No :z - Debian ships
            # no SELinux policy and the suffix would be a no-op at best.
            "Volume=/run/podman/podman.sock:/var/run/docker.sock\n"
            "Volume=portainer_data:/data\n"
            # No dedicated privileged key exists in [Container] at 5.4.2.
            "PodmanArgs=--privileged\n"
            "\n"
            "[Service]\n"
            # Quadlet emits no Restart= for .container units, and
            # --restart=always inside PodmanArgs would be ignored because
            # systemd owns the lifecycle.
            "Restart=always\n"
            "TimeoutStartSec=900\n"
            "\n"
            "[Install]\n"
            "WantedBy=multi-user.target\n"
        )
        write(gen / "portainer.container", unit)
        write(
            gen / "portainer.env",
            shell_var("BGRPIIMAGE_PORTAINER_AUTOSTART", p.get("auto_start", True))
            + shell_var("BGRPIIMAGE_PORTAINER_IMAGE", image)
            + shell_var("BGRPIIMAGE_PORTAINER_RUNTIME", "podman"),
        )
        return
```

Everything below that `return` is the unchanged Docker path.

- [ ] **Step 4: Teach the portainer module to install the units**

In `src/modules/bgrpiimage-portainer/start_chroot_script`, replace the body from `GEN=/opt/bgrpiimage/bgrpiimage-portainer` to the end of the file with:

```bash
GEN=/opt/bgrpiimage/bgrpiimage-portainer

# shellcheck disable=SC1091
source "$GEN/portainer.env" 2>/dev/null || true

if [[ -f "$GEN/portainer.env" ]]; then
    install -D -m 644 "$GEN/portainer.env" /etc/default/portainer
fi

if [[ "${BGRPIIMAGE_PORTAINER_RUNTIME:-docker}" == "podman" ]]; then
    # Quadlet: systemd's generator builds the units at boot and applies
    # their [Install] section itself. There is deliberately no
    # `systemctl enable portainer.service` - that unit does not exist yet.
    install -D -m 644 "$GEN/portainer.image" /etc/containers/systemd/portainer.image
    install -D -m 644 "$GEN/portainer.container" /etc/containers/systemd/portainer.container
else
    install -D -m 644 "$GEN/docker-compose.yml" /etc/bgrpiimage/portainer/docker-compose.yml
    install -D -m 644 "$GEN/bgrpiimage-portainer-install.service" \
        /etc/systemd/system/bgrpiimage-portainer-install.service

    if [[ "${BGRPIIMAGE_PORTAINER_AUTOSTART:-yes}" == "yes" ]]; then
        systemctl enable bgrpiimage-portainer-install.service
    fi
fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-render-podman.sh`
Expected: every `=== portainer quadlet units ===` assertion prints `PASS`.

- [ ] **Step 6: Verify the Docker path did not regress**

Run:

```bash
python3 - <<'PY'
import importlib.util, io
from pathlib import Path
from rich.console import Console
spec = importlib.util.spec_from_file_location("gen", "scripts/generate.py")
gen = importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)
gen.err_console = Console(file=io.StringIO())
cfg = gen.load_variant(Path("config/variants/base.json"))
cfg["podman"]["enabled"] = False
cfg["docker"]["enabled"] = True
gen.render_portainer(cfg)
P = Path("src/modules/bgrpiimage-portainer/filesystem/root/opt/bgrpiimage/bgrpiimage-portainer")
assert (P / "docker-compose.yml").is_file(), "compose file missing on the docker path"
assert (P / "bgrpiimage-portainer-install.service").is_file(), "oneshot missing"
assert not (P / "portainer.container").exists(), "quadlet leaked into the docker path"
print("docker path OK")
PY
```

Expected: `docker path OK`.

- [ ] **Step 7: Re-render the real variant and commit**

Run: `make render VARIANT=base` (so the tree is not left holding the Docker-path render from Step 6).

```bash
git add scripts/generate.py src/modules/bgrpiimage-portainer/start_chroot_script tests/test-render-podman.sh
git commit -m "feat(portainer): deployed portainer via quadlet under podman

render_portainer() branches on the active runtime. Docker keeps the
compose file and the first-boot oneshot unchanged; podman gets two
Quadlet units and no oneshot at all.

Three things here are easy to get wrong and are asserted by the tests:

* Restart=always belongs in [Service]. Quadlet emits no Restart= for
  .container units, and --restart=always in PodmanArgs is ignored
  because systemd owns the lifecycle.
* AutoUpdate= is valid only in [Container]. In [Image] it aborts
  generation of that unit and of the container unit that Requires= it.
* No systemctl enable for portainer.service - Quadlet units are
  generated at boot, so the unit does not exist at build time. The
  generator applies [Install] itself.

The .image unit moves the first pull into its own oneshot with its own
dependency edge, so a slow pull no longer counts against the container
unit's start timeout."
```

---

### Task 6: Auto-update with a pre-update backup

**Files:**

- Modify: `scripts/generate.py` — `render_podman()`
- Modify: `src/modules/bgrpiimage-podman/start_chroot_script`
- Modify: `tests/test-render-podman.sh`

**Interfaces:**

- Consumes: `podman.auto_update.*` and `portainer.backup_before_update.*` from Task 1; `render_podman()` from Task 3.
- Produces: payload files `podman-auto-update.timer.d/override.conf`, `podman-auto-update.service.d/10-backup.conf`, `bgrpiimage-portainer-backup`.

**Context you need:** `podman-auto-update.timer` ships as `OnCalendar=daily`, `RandomizedDelaySec=900`, `Persistent=true`, `WantedBy=timers.target`. A drop-in **must** reset `OnCalendar=` with an empty assignment first, or the shipped value stays active alongside the new one. `render_unattended()` already does exactly this for `apt-daily-upgrade.timer` at line 1786 — follow that shape.

`podman-auto-update.service` already carries `ExecStartPost=podman image prune -f`, so old images clean themselves up. It is `WantedBy=default.target`, which is why only the **timer** is enabled.

- [ ] **Step 1: Write the failing test**

Append to the embedded Python in `tests/test-render-podman.sh`, before the final summary:

```python
print()
print("=== auto-update ===")
tmr = body("podman-auto-update.timer.d/override.conf")
report(bool(tmr), "emits the timer drop-in")
report("OnCalendar=\n" in tmr,
       "resets OnCalendar= first (else the shipped daily value stays active)")
report("OnCalendar=*-*-* 05:30:00" in tmr, "fires at the configured time")
report("RandomizedDelaySec=1800" in tmr, "jitter matches randomized_delay_minutes")
report("Persistent=true" in tmr, "catches up after a power-off")

drop = body("podman-auto-update.service.d/10-backup.conf")
report("ExecStartPre=/usr/local/sbin/bgrpiimage-portainer-backup" in drop,
       "backs the volume up before the update runs")

helper = body("bgrpiimage-portainer-backup")
report("podman volume export portainer_data" in helper, "exports the portainer volume")
report("exit 0" in helper,
       "always exits 0 - a failing ExecStartPre would block updates forever")
report("KEEP=5" in helper or "KEEP=${KEEP:-5}" in helper,
       "prunes to portainer.backup_before_update.keep archives")

sc = Path("src/modules/bgrpiimage-podman/start_chroot_script").read_text(encoding="utf-8")
report("systemctl enable podman-auto-update.timer" in sc, "enables the timer")
report("systemctl enable podman-auto-update.service" not in sc,
       "never enables the service (WantedBy=default.target fires every boot)")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-render-podman.sh`
Expected: `FAIL emits the timer drop-in` and every following auto-update assertion fails.

- [ ] **Step 3: Emit the auto-update payload**

In `scripts/generate.py`, at the end of `render_podman()` (after the `podman.env` write), append:

```python
    if not au.get("enabled"):
        return

    sched = au.get("schedule") or {}
    start = sched.get("start", "05:30")
    delay_min = int(sched.get("randomized_delay_minutes", 30))
    persistent = "true" if sched.get("persistent", True) else "false"

    # The empty OnCalendar= is load-bearing: without it the shipped
    # `OnCalendar=daily` stays active alongside this one and the timer fires
    # twice. Same shape as the apt-daily-upgrade override.
    write(
        gen / "podman-auto-update.timer.d/override.conf",
        "# Auto-generated by scripts/generate.py\n"
        "[Timer]\n"
        "OnCalendar=\n"
        f"OnCalendar=*-*-* {start}:00\n"
        f"RandomizedDelaySec={delay_min * 60}\n"
        f"Persistent={persistent}\n",
    )

    backup = ((cfg.get("portainer") or {}).get("backup_before_update") or {})
    if not backup.get("enabled", True):
        return

    keep = int(backup.get("keep", 5))
    write(
        gen / "podman-auto-update.service.d/10-backup.conf",
        "# Auto-generated by scripts/generate.py\n"
        "[Service]\n"
        "ExecStartPre=/usr/local/sbin/bgrpiimage-portainer-backup\n",
    )
    write(
        gen / "bgrpiimage-portainer-backup",
        "#!/usr/bin/env bash\n"
        "# Auto-generated by scripts/generate.py\n"
        "#\n"
        "# Snapshot the Portainer volume before podman-auto-update runs.\n"
        "# Portainer migrates its database one-way on startup: a portainer.db\n"
        "# written by a newer version will not open on an older one, so\n"
        "# podman's own rollback cannot undo a bad update on its own.\n"
        "#\n"
        "# Runs on EVERY timer fire, not only when an update is available,\n"
        "# so pruning to the last KEEP archives is what bounds disk use.\n"
        "set -uo pipefail\n"
        "\n"
        f"KEEP={keep}\n"
        'DEST=/var/backups/bgrpiimage\n'
        "\n"
        "# Never fail: ExecStartPre= aborts the unit on a non-zero exit, so a\n"
        "# full disk here would block every future update instead of just\n"
        "# skipping one backup.\n"
        "mkdir -p \"$DEST\" || exit 0\n"
        "command -v podman >/dev/null 2>&1 || exit 0\n"
        "podman volume exists portainer_data >/dev/null 2>&1 || exit 0\n"
        "\n"
        'stamp=$(date +%Y%m%dT%H%M%S)\n'
        'if ! podman volume export portainer_data 2>/dev/null '
        '| gzip -c > "$DEST/portainer-$stamp.tar.gz"; then\n'
        '    echo "bgrpiimage: portainer volume backup failed, continuing" >&2\n'
        '    rm -f "$DEST/portainer-$stamp.tar.gz"\n'
        "    exit 0\n"
        "fi\n"
        "\n"
        '# shellcheck disable=SC2012  # names are generated, no odd characters\n'
        'ls -1t "$DEST"/portainer-*.tar.gz 2>/dev/null '
        '| tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done\n'
        "\n"
        "exit 0\n",
        executable=True,
    )
```

- [ ] **Step 4: Install it from the chroot script**

In `src/modules/bgrpiimage-podman/start_chroot_script`, insert directly **before** the `apt-get clean` line:

```bash
# Auto-update. Enable the TIMER only: podman-auto-update.service is
# WantedBy=default.target and would fire on every boot.
if [[ -f "$GEN/podman-auto-update.timer.d/override.conf" ]]; then
    install -D -m 644 "$GEN/podman-auto-update.timer.d/override.conf" \
        /etc/systemd/system/podman-auto-update.timer.d/override.conf
    systemctl enable podman-auto-update.timer
fi

if [[ -f "$GEN/bgrpiimage-portainer-backup" ]]; then
    install -D -m 755 "$GEN/bgrpiimage-portainer-backup" \
        /usr/local/sbin/bgrpiimage-portainer-backup
    install -D -m 644 "$GEN/podman-auto-update.service.d/10-backup.conf" \
        /etc/systemd/system/podman-auto-update.service.d/10-backup.conf
fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-render-podman.sh`
Expected: every `=== auto-update ===` assertion prints `PASS`.

- [ ] **Step 6: Shell-check the generated helper**

Run:

```bash
make render VARIANT=base
bash -n src/modules/bgrpiimage-podman/filesystem/root/opt/bgrpiimage/bgrpiimage-podman/bgrpiimage-portainer-backup
```

Expected: no output (exit 0). A syntax error here would only surface on the device at 05:30.

- [ ] **Step 7: Commit**

```bash
git add scripts/generate.py src/modules/bgrpiimage-podman/start_chroot_script tests/test-render-podman.sh
git commit -m "feat(podman): enabled auto-update for the portainer container

AutoUpdate=registry on the container plus podman-auto-update.timer,
scheduled at 05:30 +30m - clear of both the unattended-upgrades window
(02:00-04:00) and the auto-reboot window (03:00-05:00). Portainer
migrates its database one-way on startup, and a scripted reboot landing
mid-migration produces a portainer.db no version will open.

* Only the timer is enabled. podman-auto-update.service is
  WantedBy=default.target and would otherwise fire on every boot.
* The timer drop-in resets OnCalendar= with an empty assignment first,
  or the shipped `OnCalendar=daily` stays active alongside ours.
* A pre-update ExecStartPre snapshots the portainer volume, because
  podman's rollback only covers \"the new image never started\" - a
  container that starts and then dies counts as a successful restart
  under quadlet's default --sdnotify=conmon.
* The backup helper always exits 0. ExecStartPre= aborts the unit on
  failure, so a full disk would otherwise block updates permanently.

Old images need no cleanup of ours: podman-auto-update.service already
carries ExecStartPost=podman image prune -f."
```

---

### Task 7: Runtime-aware MOTD

**Files:**

- Modify: `scripts/generate.py` — the MOTD generator, lines 629-636
- Modify: `tests/test-render-podman.sh`

**Interfaces:**

- Consumes: `podman.enabled` / `docker.enabled` from Task 1.
- Produces: nothing other tasks depend on.

**Context you need:** The banner is `_MOTD_SCRIPT`, a module-level **raw string constant** at `scripts/generate.py:515`, written verbatim at line 512 with no config interpolation:

```python
    write(gen / "motd-banner.sh", _MOTD_SCRIPT, executable=True)
```

Do **not** convert it to an f-string. It is full of `${DIM}`, `${NC}` and `$(...)` shell expansions that an f-string would try to interpret as Python. The runtime detection therefore happens in shell, inside the constant.

The three lines to change, verbatim as they stand today:

```sh
dk_s=$(systemctl is-active docker 2>/dev/null || echo "?")          # line 629
printf "   ${DIM}docker:${NC} $(active_color "$dk_s")%s${NC}" "$dk_s"   # line 633
    n=$(docker ps -q 2>/dev/null | wc -l)                            # line 635
```

Under Podman there is no `docker.service` to query — `systemctl is-active docker` returns `unknown`, so a perfectly healthy device would show a dead runtime on every login. Podman is daemonless; the meaningful probe is `podman.socket`.

The discriminator must be `command -v podman`, **not** `command -v docker`: `podman-docker` installs `/usr/bin/docker` as a shim, so a `docker` probe is true under both runtimes.

- [ ] **Step 1: Write the failing test**

Append to the embedded Python in `tests/test-render-podman.sh`, before the final summary:

```python
print()
print("=== motd runtime line ===")
gen.render_base(cfg)
BGEN = Path("src/modules/bgrpiimage-base/filesystem/root/opt/bgrpiimage/bgrpiimage-base")
motd = (BGEN / "motd-banner.sh").read_text(encoding="utf-8")
report('rt_unit="podman.socket"' in motd,
       "probes podman.socket, not a docker service that will never exist")
report('command -v podman' in motd,
       "discriminates on podman, not docker (podman-docker ships a docker shim)")
report('n=$("$rt_name" ps -q' in motd, "counts containers with the active runtime")
report("systemctl is-active docker" not in motd,
       "no hardcoded docker probe remains")
report('rt_name="docker"' in motd, "still falls back to docker when podman is absent")
```

`_MOTD_SCRIPT` is a static constant, so this assertion holds regardless of which variant is rendered — the branch is evaluated on the device, not at render time.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-render-podman.sh`
Expected: `FAIL probes podman.socket, not docker.service`.

- [ ] **Step 3: Make the MOTD runtime-aware**

In `scripts/generate.py`, inside the `_MOTD_SCRIPT` raw string, replace line 629:

```sh
dk_s=$(systemctl is-active docker 2>/dev/null || echo "?")
```

with:

```sh
# Which runtime is installed? podman-docker ships /usr/bin/docker as a
# shim, so probing for `docker` is true under both - `podman` is the only
# honest discriminator. Podman is daemonless, so the unit that means
# "the API is reachable" is the socket, not a service.
if command -v podman >/dev/null 2>&1; then
    rt_name="podman"; rt_unit="podman.socket"
else
    rt_name="docker"; rt_unit="docker"
fi
dk_s=$(systemctl is-active "$rt_unit" 2>/dev/null || echo "?")
```

Replace line 633:

```sh
printf "   ${DIM}docker:${NC} $(active_color "$dk_s")%s${NC}" "$dk_s"
```

with:

```sh
printf "   ${DIM}%s:${NC} $(active_color "$dk_s")%s${NC}" "$rt_name" "$dk_s"
```

Replace line 635:

```sh
    n=$(docker ps -q 2>/dev/null | wc -l)
```

with:

```sh
    n=$("$rt_name" ps -q 2>/dev/null | wc -l)
```

Leave the `if [ "$dk_s" = "active" ]` guard, the `active_color` calls and the `(%d running)` formatting exactly as they are. The variable name `dk_s` is kept deliberately: renaming it would touch unrelated lines in the same string for no behavioural gain.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-render-podman.sh`
Expected: all three `=== motd runtime line ===` assertions print `PASS`.

- [ ] **Step 5: Verify the rendered banner is still valid shell**

Run:

```bash
make render VARIANT=base
bash -n src/modules/bgrpiimage-base/filesystem/root/opt/bgrpiimage/bgrpiimage-base/motd-banner.sh
```

Expected: no output. This catches an unbalanced quote introduced by the f-string edit — the banner runs on every login, so a syntax error is visible on every SSH session.

- [ ] **Step 6: Run the whole host-side suite**

Run:

```bash
make validate
bash tests/test-config-guards.sh
bash tests/test-render-podman.sh
```

Expected: all three exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/generate.py tests/test-render-podman.sh
git commit -m "fix(banner): reported the active runtime in the motd

The banner queried `systemctl is-active docker` unconditionally. Under
podman that service does not exist, so a perfectly healthy device would
have shown a dead container runtime on every login.

Podman is daemonless, so the meaningful probe is podman.socket rather
than a service, and the container count comes from `podman ps`. The
docker path is unchanged."
```

---

### Task 8: Documentation

**Files:**

- Modify: `README.md`
- Modify: `docs/configuration.md`, `docs/post-flash-setup.md`, `docs/architecture.md`, `docs/banner-and-updates.md`, `docs/hardware.md`, `docs/flash.md`
- Modify: `CHANGELOG.md` only if the repo's release tooling does not generate it — check first with `git log --oneline -5 -- CHANGELOG.md`; if the entries say `chore(release):` it is generated, so leave it alone.

**Interfaces:**

- Consumes: everything built in Tasks 1-7.
- Produces: nothing code depends on.

**Context you need:** `docs/tools-container.md` and `docs/ci-cd.md` describe the **build host**, which still uses Docker. Do not touch them. The same applies to the Docker references in `docs/architecture.md:89-94` and `:177-188` — that section is titled "Why two docker containers for a build?" and is about CustomPiOS, not the image.

Find every mention with:

```bash
grep -n -i "docker\|portainer" README.md docs/configuration.md docs/post-flash-setup.md \
  docs/architecture.md docs/banner-and-updates.md docs/hardware.md docs/flash.md
```

- [ ] **Step 1: Update `docs/configuration.md`**

- Line 17: the Pi Zero 2 W note says "insufficient for Docker + Portainer" — change to "Podman + Portainer".
- Line 43-44 table: keep the `docker` row, describing it as the non-default option, and add a `podman` row above it: "Podman runtime, Docker CLI emulation, container networking (default)."
- Lines 185-186: the `network-online.target` rationale names `docker.service`. Under Podman there is no such service; the ordering that matters is `podman.socket` and the Quadlet unit's `After=`.
- Replace the `## 🎛 portainer` section body (lines 387-416): document `auto_update`, `backup_before_update`, and that under Podman the deployment is two Quadlet files at `/etc/containers/systemd/` with no oneshot and no compose file. Give the new operator workflow:

```bash
systemctl status portainer.service          # quadlet-generated unit
systemctl restart portainer.service
podman auto-update --dry-run                # what would change
```

- Add a `## 🦭 podman` section documenting every key from the Task 1 schema block.

- [ ] **Step 2: Update `docs/post-flash-setup.md`**

- Lines 338-361 (Reaching Portainer): `sudo docker restart portainer` becomes `sudo systemctl restart portainer.service`; the sentinel check `ls -l /var/lib/bgrpiimage/portainer.installed` no longer exists under Podman — replace it with `systemctl status portainer.service` and `podman ps`.
- Line 432 table: the Portainer update row becomes `podman auto-update` (automatic at 05:30) with the manual form `systemctl start podman-auto-update.service`.
- Line 410: "Does not configure Docker, Portainer or unattended-upgrades" — add Podman to that list.
- Line 546: the deny-glob list mentions `/etc/docker/daemon.json`; note that the Podman equivalents (`/etc/containers/*`) are image-only for the same reason.

- [ ] **Step 3: Update `docs/architecture.md`**

- Line 66-67 module table: add a `bgrpiimage-podman` row listing `containers.conf`, `podman-network.json`, `98-podman.conf`, `99-bgrpiimage-containers.conf`, `nodocker`, `podman.env`, the auto-update drop-ins and `bgrpiimage-portainer-backup`. Change the `bgrpiimage-portainer` row to name both shapes: compose + oneshot under Docker, `portainer.container` + `portainer.image` under Podman.
- Leave lines 89-94 and 177-188 alone — build host.

- [ ] **Step 4: Update the remaining three docs**

- `docs/banner-and-updates.md`: the banner's runtime status line now reads `podman:` and is sourced from `podman.socket`.
- `docs/hardware.md` lines 352-365: the watchdog `runtime_sec=15` rationale argues from "a Docker host with container healthchecks" producing PID 1 fork storms. The conclusion stands; reword for a daemonless runtime — under Podman the equivalent load is conmon processes per container plus the auto-update timer, not a single supervising daemon.
- `docs/flash.md`: one mention, adjust in place.

- [ ] **Step 5: Update `README.md`**

Fourteen mentions. Each is either (a) the image's runtime, which becomes Podman, or (b) the build toolchain, which stays Docker. Classify each before editing. The feature list, the Portainer access section and any `docker compose` operator commands are category (a).

- [ ] **Step 6: Verify no stale claims remain**

Run:

```bash
grep -rn -i "docker" README.md docs/configuration.md docs/post-flash-setup.md \
  docs/banner-and-updates.md docs/flash.md
```

Expected: every remaining hit is either explicitly about the build host, about Docker CLI *emulation*, or about the Docker stack as the documented non-default option. Any sentence that still tells an operator to run `docker compose` against Portainer is a bug.

- [ ] **Step 7: Commit**

```bash
git add README.md docs/
git commit -m "docs: documented podman as the default container runtime

Covers the new podman config block, the Quadlet deployment of Portainer
and the auto-update schedule, and replaces the operator commands that
assumed a compose file and a first-boot oneshot.

Deliberately unchanged: docs/tools-container.md, docs/ci-cd.md and the
\"Why two docker containers for a build?\" section of architecture.md.
Those describe the machine that BUILDS the image, which still uses
Docker - two different things that are both called Docker, and
conflating them is how the build instructions get broken."
```

---

## Final verification

After Task 8, run the full host-side suite plus a real render of every variant:

```bash
make validate
bash tests/test-config-guards.sh
bash tests/test-render-podman.sh
bash tests/test-apply-guards.sh
make render VARIANT=base
make render VARIANT=canbus-plattform
make render VARIANT=canbusfd-plattform
```

`make test` additionally runs `test-parity`, `test-idempotence`, `test-selfupdate` and `test-update`, which need Docker on the build host. Run it if Docker is available; `test-apply-parity.sh` should be unaffected because `bgrpiimage-podman` has no `apply.sh`.

An actual image build (`make build VARIANT=base`) needs Docker and `--privileged`, and is the only way to prove the chroot scripts run. It is not a gate for the commits above, but nothing in this plan is confirmed working on hardware until an image is flashed and these run on the device:

```bash
systemctl is-active podman.socket
systemctl status portainer.service
podman inspect portainer --format '{{index .Config.Labels "io.containers.autoupdate"}}'   # registry
podman inspect portainer --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}'        # portainer.service
podman network inspect podman --format '{{.IPv6Enabled}}'                                 # true
podman auto-update --dry-run
systemctl list-timers podman-auto-update.timer
docker ps                                                                                  # emulation works
curl -sk https://localhost:9443/ -o /dev/null -w '%{http_code}\n'                          # 200
```
