#!/usr/bin/env bash
# Asserts the cross-field guards in generate.py `_semantic_validate()` refuse.
#
# Same reasoning as tests/test-apply-guards.sh: every one of these is a
# negative - "this config must NOT build". Negatives rot silently, because a
# refactor that drops a condition breaks nothing visible; it just stops
# declining, and the next image ships with one CAN channel bound to the other
# channel's interrupt. `make validate` only ever proves the happy path.
#
# Host-side, no docker: these guards are pure Python and run wherever
# `make validate` runs.
#
#   bash tests/test-config-guards.sh     # or: make test-config-guards
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

# python3 first, python second. On Windows dev boxes `python3` is the Microsoft
# Store alias stub: it resolves on PATH and exits 49 with a German shop advert
# instead of running anything, so `command -v` alone is not proof of an
# interpreter. Probe by actually executing one.
PY=""
for cand in "${PY_OVERRIDE:-}" python3 python; do
    [ -n "$cand" ] || continue
    if "$cand" -c 'import sys' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "no working python3/python on PATH" >&2; exit 1; }

"$PY" - <<'PYEOF'
import copy, importlib.util, json, sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
spec = importlib.util.spec_from_file_location("gen", "scripts/generate.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

# Silence the advisory notes _semantic_validate() writes to stderr. Several
# cases below deliberately trip them, and 20 repetitions of the SPI-clamp note
# would bury the PASS/FAIL lines this file exists to print. The stdout-discipline
# section at the end is what actually asserts where those notes go.
import io as _io
from rich.console import Console as _Console
gen.err_console = _Console(file=_io.StringIO())

# Loaded through the generator's own loader, not json.load: it follows the
# `extends` chain and strips the `$schema` / `extends` meta keys. Reading the
# files raw leaves those in place, and the schema's additionalProperties:false
# then rejects EVERY config - which does not look like a broken harness, it
# looks like all the guards passing.
from pathlib import Path

BASE = gen.load_variant(Path("config/variants/base.json"))
FD = gen.load_variant(Path("config/variants/canbusfd-plattform.json"))
CLASSIC = gen.load_variant(Path("config/variants/canbus-plattform.json"))

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


def resolve(child, mutate=None):
    """Take an already extends-resolved config and apply a mutation to it."""
    cfg = copy.deepcopy(child)
    if mutate:
        mutate(cfg)
    return cfg


def accepts(label, child=FD, mutate=None):
    try:
        gen._semantic_validate(resolve(child, mutate))
        report(True, label)
    except ValueError as exc:
        report(False, label, f"unexpectedly refused: {exc}")


def refuses(label, mutate, needle, child=FD):
    try:
        gen._semantic_validate(resolve(child, mutate))
        report(False, label, "built without complaint")
    except ValueError as exc:
        report(
            needle.lower() in str(exc).lower(),
            label,
            "" if needle.lower() in str(exc).lower() else f"wrong reason: {exc}",
        )


ovl = lambda c: c["boot_config"]["dtoverlays"]
ifc = lambda c: c["can"]["interfaces"]

print("=== the shipped variants still build ===")
accepts("base")
accepts("canbus-plattform", CLASSIC)
accepts("canbusfd-plattform")

print()
print("=== mcp251xfd: the overlay is loaded twice, so identity must survive ===")


def strip_ids(cfg):
    for entry in ovl(cfg):
        entry.pop("id", None)


# Authored without `id`, both entries are named "mcp251xfd" and deep_merge
# collapses them into one overlay carrying both chip selects. The count check
# is what notices.
refuses(
    "two mcp251xfd entries without `id` collapse into one",
    lambda cfg: cfg["boot_config"].__setitem__(
        "dtoverlays",
        gen.deep_merge({"o": []}, {"o": [
            {k: v for k, v in e.items() if k != "id"} for e in ovl(cfg)
        ]})["o"],
    ),
    "mcp251xfd overlay",
)
refuses("an interface with no overlay behind it", lambda c: ifc(c).append(
    {"name": "can2", "bitrate": 500000}), "can.interfaces declares")
refuses("an overlay with no interface in front of it", lambda c: ifc(c).pop(),
        "can.interfaces declares")

print()
print("=== chip selects ===")
refuses("no spi<n>-<m> selector at all",
        lambda c: ovl(c)[1]["params"].pop("spi0-0"), "exactly one spi<n>-<m>")
refuses("two selectors on one overlay",
        lambda c: ovl(c)[1]["params"].__setitem__("spi0-1", True),
        "exactly one spi<n>-<m>")
refuses("both controllers on the same chip select",
        lambda c: (ovl(c)[2]["params"].pop("spi1-0"),
                   ovl(c)[2]["params"].__setitem__("spi0-0", True)),
        "both select spi0-0")
refuses("spi0-2, which the overlay does not implement",
        lambda c: (ovl(c)[1]["params"].pop("spi0-0"),
                   ovl(c)[1]["params"].__setitem__("spi0-2", True)),
        "does not implement")

print()
print("=== interrupts ===")
refuses("a channel with no interrupt (every instance defaults to GPIO 25)",
        lambda c: ovl(c)[2]["params"].pop("interrupt"), "must set params.interrupt")
refuses("two channels sharing an INT GPIO",
        lambda c: ovl(c)[2]["params"].__setitem__("interrupt", "25"),
        "own INT GPIO")

print()
print("=== SPI clock ===")
refuses("the MCP2515 spelling `spimaxfrequency`",
        lambda c: ovl(c)[1]["params"].__setitem__("spimaxfrequency", "8000000"),
        "spelling")
# A speed above the driver's clamp is noted, not refused: min() discards it,
# and the upstream overlay's own default (20 MHz) is already above the ceiling
# for a 40 MHz crystal. Refusing it would reject upstream's own value.
accepts("a speed above the clamp (noted, not refused)",
        mutate=lambda c: ovl(c)[1]["params"].__setitem__("speed", "20000000"))
accepts("a speed exactly at the clamp",
        mutate=lambda c: ovl(c)[1]["params"].__setitem__("speed", "17000000"))
accepts("no speed at all (overlay default applies)",
        mutate=lambda c: ovl(c)[1]["params"].pop("speed"))

print()
print("=== the AUX SPI bus has to be switched on, and switched on first ===")
refuses("spi1 in use with no spi1-<N>cs overlay",
        lambda c: c["boot_config"].__setitem__("dtoverlays", ovl(c)[1:]),
        "no spi1-<N>cs overlay")
refuses("spi1-<N>cs listed after the entries that use it",
        lambda c: c["boot_config"].__setitem__("dtoverlays", ovl(c)[1:] + [ovl(c)[0]]),
        "must be listed BEFORE")
refuses("spi1-1cs when CS1 is in use",
        lambda c: (ovl(c)[0].__setitem__("name", "spi1-1cs"),
                   ovl(c)[2]["params"].pop("spi1-0"),
                   ovl(c)[2]["params"].__setitem__("spi1-1", True)),
        "chip select")

print()
print("=== CAN FD ===")
refuses("a data phase slower than arbitration",
        lambda c: ifc(c)[0].__setitem__("dbitrate", 125000), "look swapped")
refuses("dbitrate on a Classic-CAN-only MCP2515 board",
        lambda c: ifc(c)[0].__setitem__("dbitrate", 2000000),
        "Classic-CAN-only", child=CLASSIC)

print()
print("=== watchdog: the two settings that reboot-loop or corrupt a device ===")

# These are schema bounds rather than _semantic_validate() rules, so they are
# asserted through the schema the way `make validate` reaches it. Both bounds
# guard a silent failure, which is exactly the kind of rule that gets "tidied"
# by someone who reads them as ordinary tuning ranges.
import jsonschema

SCHEMA = json.load(open("config/schema.json", encoding="utf-8"))


def schema_refuses(label, watchdog, why):
    cfg = copy.deepcopy(FD)
    cfg["watchdog"] = watchdog
    try:
        jsonschema.validate(cfg, SCHEMA)
        report(False, label, f"schema accepted it - {why}")
    except jsonschema.ValidationError:
        report(True, label)


def schema_accepts(label, watchdog):
    cfg = copy.deepcopy(FD)
    cfg["watchdog"] = watchdog
    try:
        jsonschema.validate(cfg, SCHEMA)
        report(True, label)
    except jsonschema.ValidationError as exc:
        report(False, label, f"schema refused it: {exc.message}")


# bcm2835_wdt_start() masks: (t << 16) & 0xfffff, so the armed timeout is
# t mod 16. 16 arms ZERO seconds and the board resets forever, and since the
# 6.8 backport the ioctl does not even fail. Only this bound stops it.
schema_refuses("runtime_sec 16 (would arm 0s - reset loop)",
               {"enabled": True, "runtime_sec": 16, "reboot_sec": 600},
               "16 mod 16 = 0")
schema_refuses("runtime_sec 20 (would arm 4s)",
               {"enabled": True, "runtime_sec": 20, "reboot_sec": 600},
               "20 mod 16 = 4")
schema_accepts("runtime_sec 15 (the hardware maximum)",
               {"enabled": True, "runtime_sec": 15, "reboot_sec": 600})

# systemd-shutdown may spend 210s+ before its first watchdog_ping(): an
# unbounded sync, then SIGTERM (90s), then SIGKILL (90s). A shorter value
# resets the board mid-unmount_all().
schema_refuses("reboot_sec 120 (inside the systemd-shutdown window)",
               {"enabled": True, "runtime_sec": 15, "reboot_sec": 120},
               "fires during sync/SIGTERM/SIGKILL")
schema_accepts("reboot_sec 600 (upstream default)",
               {"enabled": True, "runtime_sec": 15, "reboot_sec": 600})

# The watchdog values are rendered TWICE - into hardware.env and into the
# systemd drop-in - and the two used to carry different hardcoded fallbacks, so
# hardware.env could hold a reboot_sec of 120 that the schema's own minimum
# forbids. Two renderers of one value drift; assert they cannot.
for key, const in (("runtime_sec", "WATCHDOG_RUNTIME_SEC_DEFAULT"),
                   ("reboot_sec", "WATCHDOG_REBOOT_SEC_DEFAULT")):
    report(getattr(gen, const) is not None, f"{const} is defined")
try:
    jsonschema.validate(
        {"enabled": True, "reboot_sec": gen.WATCHDOG_REBOOT_SEC_DEFAULT,
         "runtime_sec": gen.WATCHDOG_RUNTIME_SEC_DEFAULT},
        SCHEMA["properties"]["watchdog"])
    report(True, "the code defaults satisfy the schema bounds")
except jsonschema.ValidationError as exc:
    report(False, "the code defaults satisfy the schema bounds", exc.message)

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
    # BASE ships podman.enabled=true with portainer.auto_update=true (Task 1);
    # auto_update is a podman-only mechanism, so a config that switches to
    # docker only must also drop it, or the "portainer auto_update without
    # the podman timer" guard above correctly refuses this as self-contradictory.
    mutate=lambda c: (c["docker"].__setitem__("enabled", True),
                      c["podman"].__setitem__("enabled", False),
                      c["portainer"].__setitem__("auto_update", False)),
)
refuses(
    "portainer.image is a short name under podman (no registry host)",
    lambda c: c["portainer"].__setitem__("image", "portainer/portainer-ce:lts"),
    "registry host",
    child=BASE,
)
accepts(
    "portainer.image qualified with an explicit registry host",
    child=BASE,
    mutate=lambda c: c["portainer"].__setitem__(
        "image", "docker.io/portainer/portainer-ce:lts"),
)
accepts(
    "portainer.image at a bare localhost registry",
    child=BASE,
    mutate=lambda c: c["portainer"].__setitem__("image", "localhost/portainer-ce:lts"),
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

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PYEOF
guards_rc=$?

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

# --- stdout discipline -------------------------------------------------------
# `--json` writes the resolved config to stdout so CI can pipe it into jq
# (build.yml, "Resolve variant metadata": generate.py --json > /tmp/resolved.json
# then jq .variant.version). Anything else printed on stdout lands INSIDE that
# JSON and makes it unparseable, and the resulting failure names jq, not the
# print that caused it. This is not hypothetical: a validation note added on the
# shared rich console broke exactly this step for one variant while every other
# check stayed green.
echo
echo "=== --json puts nothing but JSON on stdout ==="
json_rc=0
for cfg in config/variants/*.json; do
    name=$(basename "$cfg" .json)
    if ADMIN_PASSWORD=ci-placeholder-pw WIFI_PSK=ci-placeholder-psk \
       "$PY" scripts/generate.py "$cfg" --json 2>/dev/null \
       | "$PY" -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        echo "  PASS  $name"
    else
        echo "  FAIL  $name -- stdout is not valid JSON (something printed to stdout)"
        json_rc=1
    fi
done

[ "$guards_rc" -eq 0 ] && [ "$json_rc" -eq 0 ] && [ "$contract_rc" -eq 0 ]
