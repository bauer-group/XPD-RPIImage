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
import importlib.util, json, re, shutil, subprocess, sys
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
report("systemctl enable podman-auto-update.service" not in sc,
       "never enables podman-auto-update.service")

# The assertions above only prove ACTIVE_MODULES, _module_enabled() and
# BUNDLE_MODULES agree - none of them touch the `steps` dispatch table
# inside main(), which is a local variable, not an attribute of `gen`.
# A module present in ACTIVE_MODULES but missing from `steps` builds with
# an empty payload directory, silently. The only way to catch that is to
# run the real generator end-to-end and check it repopulates the payload -
# so wipe it first, or leftovers from the direct render_podman() call above
# would pass even with `steps` broken.
shutil.rmtree(GEN, ignore_errors=True)
_rc = subprocess.run([sys.executable, "scripts/generate.py",
                      "config/variants/base.json"],
                     capture_output=True, text=True)
report(_rc.returncode == 0, "full generator run succeeds",
       _rc.stderr[-400:] if _rc.returncode else "")
report(GEN.is_dir() and any(GEN.iterdir()),
       "steps table actually dispatches render_podman "
       "(payload repopulated by a real generator run)")

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

print()
print(f"{passed} passed, {failed} failed")
sys.exit(0 if failed == 0 else 1)
PYEOF
