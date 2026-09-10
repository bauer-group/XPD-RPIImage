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

BASE = json.load(open("config/variants/base.json", encoding="utf-8"))
FD = json.load(open("config/variants/canbusfd-plattform.json", encoding="utf-8"))
CLASSIC = json.load(open("config/variants/canbus-plattform.json", encoding="utf-8"))

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
    """Merge child onto base exactly as generate.py does, then mutate."""
    cfg = gen.deep_merge(copy.deepcopy(BASE), copy.deepcopy(child))
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
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PYEOF
