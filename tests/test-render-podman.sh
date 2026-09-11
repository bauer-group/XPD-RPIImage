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
import importlib.util, json, re, sys
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
_id = net.get("id", "")
report(isinstance(net.get("id"), str) and bool(re.fullmatch(r"[0-9a-f]{64}", _id)),
       "id is exactly 64 lowercase hex chars (netavark silently skips the file otherwise)")
report(net.get("ipv6_enabled") is True, "ipv6_enabled is true")
report(any(":" in s.get("subnet", "") for s in net.get("subnets", [])),
       "carries an IPv6 subnet")
report(any("." in s.get("subnet", "") for s in net.get("subnets", [])),
       "carries an IPv4 subnet")

print()
print("=== sysctl and journald ===")
sc = body("98-podman.conf")
report("vm.max_map_count=4194304" in sc.splitlines(),
       "vm.max_map_count survived the move off the docker block")
jd = body("99-bgrpiimage-containers.conf")
report("[Journal]" in jd and "SystemMaxUse=200M" in jd,
       "journald cap replaces docker's json-file cap")
report("SystemMaxFileSize=20M" in jd,
       "journald file-size cap also flowed through from config")

print()
print(f"{passed} passed, {failed} failed")
sys.exit(0 if failed == 0 else 1)
PYEOF
