#!/usr/bin/env python3
"""Pack a variant's rendered configuration into an update bundle.

A bundle is what an already-flashed device needs in order to catch up with a
release without being reflashed. It carries no kernel, no root filesystem and
no packages - only the files this project generates, which is where 65% of
releases actually live: systemd units, the config.txt fence, the MOTD, CAN and
network configuration. Roughly 30 KB against a 0.9 GB image.

Layout mirrors what CustomPiOS `unpack` rolls out at build time:

    manifest.json
    root/opt/bgrpiimage/<module>/...     payload + the module's apply.sh
    root/usr/local/sbin/bgrpiimage-setup
    root/etc/profile.d/50-bgrpiimage-shell.sh

That symmetry is the point. The updater's extract step IS unpack, so the same
apply.sh runs against the same tree in both contexts and neither side needs to
know about the other.

Module selection is an ALLOWLIST, never a denylist. bgrpiimage-users is the
reason: it is simultaneously the only module carrying credential material
(create-users.sh embeds the resolved ADMIN_PASSWORD in cleartext) and the only
one that is not safe to re-apply (unconditional chpasswd + chage -d 0). A
denylist would ship it the day someone adds a module and forgets to exclude
it; an allowlist cannot.

    python scripts/bundle.py config/variants/canbus-plattform.json [--out dist]
"""
from __future__ import annotations

import argparse
import gzip
import os
import hashlib
import io
import json
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate as gen  # noqa: E402  (path shim above is deliberate)

# Bundle wire format. Bumped only when the device-side applier would
# misinterpret an older or newer layout - never for a new optional field.
BUNDLE_FORMAT = 1

# Repository root, for the local signing-key fallback. bundle.py otherwise
# reaches the tree through generate's MODULES_DIR, so it had no ROOT of its
# own until signing needed one.
ROOT = Path(__file__).resolve().parent.parent

# The modules an update may carry. See the module note in the docstring.
BUNDLE_MODULES = [
    "bgrpiimage-common",              # apply-lib.sh, sourced by every apply.sh
    "bgrpiimage-base",
    "bgrpiimage-network",
    "bgrpiimage-boot",
    "bgrpiimage-can",
    "bgrpiimage-unattended-upgrades",
]

# Refuse to publish a bundle containing any of these. The generator resolves
# ${ADMIN_PASSWORD} and ${WIFI_PSK} into the tree, so "we excluded the module
# that has secrets" is an assumption worth checking rather than trusting - a
# public release asset is not somewhere to discover you were wrong.
SECRET_ENV = ("ADMIN_PASSWORD", "WIFI_PSK")


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def stage(cfg: dict[str, Any], staging: Path) -> list[Path]:
    """Copy every allowlisted module's filesystem/root into one tree."""
    root = staging / "root"
    root.mkdir(parents=True)
    for module in BUNDLE_MODULES:
        if not gen._module_enabled(module, cfg):
            continue
        src = gen.MODULES_DIR / module / "filesystem" / "root"
        if not src.is_dir():
            continue
        shutil.copytree(src, root, dirs_exist_ok=True)
    return sorted(p for p in root.rglob("*") if p.is_file())


def scan_for_secrets(staging: Path, env: dict[str, str]) -> list[str]:
    """Fail closed if a credential made it into the tree.

    Checks the resolved values, not the variable names: the point is whether
    the actual password is in a file that is about to become a public release
    asset. Short or empty values are skipped - matching on "" would flag every
    file, and matching on a two-character password would be noise rather than
    signal.
    """
    needles: list[tuple[str, str]] = []
    for name in SECRET_ENV:
        value = env.get(name, "")
        if len(value) >= 6:
            needles.append((name, value))
    for demo in gen._KNOWN_DEMO_PASSWORDS:
        needles.append(("known demo password", demo))

    hits: list[str] = []
    for path in sorted(staging.rglob("*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for label, needle in needles:
            if needle in text:
                hits.append(f"{path.relative_to(staging).as_posix()} contains {label}")
    return hits


def build_manifest(cfg: dict[str, Any], staging: Path, files: list[Path]) -> dict[str, Any]:
    variant = cfg["variant"]
    base_image = cfg.get("base_image") or {}
    root = staging / "root"
    return {
        "bundle_format": BUNDLE_FORMAT,
        "dist": "bgrpiimage",
        "variant": variant["name"],
        "version": variant.get("version", "0.0.0"),
        "description": variant.get("description", ""),
        # The line between a config update and an OS update. A device whose
        # /etc/bgrpiimage-release records a different base image is running a
        # different Raspberry Pi OS than this bundle was generated against,
        # and applying it would be guesswork.
        "applies_to": {
            "variant": variant["name"],
            "base_image_sha256": base_image.get("sha256", ""),
            "base_image_url": base_image.get("url", ""),
            # Devices flashed before the identity contract carry none of the
            # fields the refusals need, so they are told to reflash instead.
            "min_apply_contract": gen.APPLY_CONTRACT_VERSION,
        },
        "modules": [
            m for m in BUNDLE_MODULES
            if gen._module_enabled(m, cfg)
            and (gen.MODULES_DIR / m / "filesystem" / "root").is_dir()
        ],
        "files": [
            {
                "path": f.relative_to(root).as_posix(),
                "sha256": _sha256_file(f),
                "size": f.stat().st_size,
            }
            for f in files
        ],
    }


def sign(payload: bytes, key_pem: bytes) -> bytes:
    """Sign the manifest with the release key.

    Ed25519 over the exact manifest bytes that go into the archive. The
    manifest already carries a SHA-256 for every file, so one signature
    covers the whole bundle: signature authenticates the manifest, the
    manifest authenticates the contents. Nothing else needs signing, and a
    device can reject a tampered bundle before it reads a single payload file.

    Raw Ed25519 rather than a container format, because the verifier is
    `openssl pkeyutl -verify` on the device - openssl is already present
    there as a dependency of ca-certificates, and adding a package that a
    device cannot install without an update would be circular.
    """
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization

    key = serialization.load_pem_private_key(key_pem, password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise SystemExit("error: the signing key is not an Ed25519 key")
    return key.sign(payload)


def load_signing_key() -> bytes | None:
    """The key comes from the environment in CI, or a file locally.

    BGRPIIMAGE_SIGNING_KEY holds the PEM itself rather than a path, because
    that is the shape a GitHub Actions secret has: the workflow can hand it
    over without ever writing it to disk on the runner.
    """
    pem = os.environ.get("BGRPIIMAGE_SIGNING_KEY", "").strip()
    if pem:
        return pem.encode("utf-8") + b"\n"
    local = ROOT / ".secrets" / "bgrpiimage-recovery.key"
    if local.is_file():
        return local.read_bytes().replace(b"\r\n", b"\n")
    return None


def write_tar(staging: Path, out: Path, manifest: dict[str, Any],
              signature: bytes | None = None) -> bytes:
    """Deterministic tarball: same commit in, same bytes out.

    Sorted names and zeroed mtime/uid/gid, so rebuilding a release produces an
    identical archive and its checksum means something beyond "it downloaded".
    Modes are normalised rather than inherited, because this repo is developed
    on Windows where every file reads as 0755 and the archive would otherwise
    describe the build host instead of the intent.
    """
    payload = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8") + b"\n"

    out.parent.mkdir(parents=True, exist_ok=True)
    # tarfile's "w:gz" writes the current time into the gzip header, so two
    # builds of the same commit produced different checksums - which defeats
    # the point of publishing one. Drive the GzipFile directly with mtime=0
    # and an empty filename field so the container is a pure function of its
    # contents.
    with open(out, "wb") as raw,          gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz,          tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
        info = tarfile.TarInfo("manifest.json")
        info.size = len(payload)
        info.mtime = 0
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(payload))

        if signature is not None:
            sig_info = tarfile.TarInfo("manifest.json.sig")
            sig_info.size = len(signature)
            sig_info.mtime = 0
            sig_info.mode = 0o644
            tar.addfile(sig_info, io.BytesIO(signature))

        root = staging / "root"
        for path in sorted(p for p in root.rglob("*") if p.is_file()):
            rel = path.relative_to(staging).as_posix()
            info = tar.gettarinfo(str(path), arcname=rel)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mode = 0o755 if path.suffix == ".sh" or "sbin/" in rel else 0o644
            with path.open("rb") as fh:
                tar.addfile(info, fh)

    return payload


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("config", type=Path, help="path to variant JSON config")
    ap.add_argument("--env-file", type=Path, help="optional .env file (KEY=VALUE lines)")
    ap.add_argument("--out", type=Path, default=Path("dist"), help="output directory")
    ap.add_argument("--unsigned", action="store_true",
                    help="build without a signature (devices will refuse it)")
    args = ap.parse_args()

    # Same precedence as generate.py's main(): the process environment wins,
    # the file only fills gaps. Duplicated rather than imported because that
    # parsing lives inside generate.main() and pulling it out is a refactor
    # this script does not need to force.
    import os
    env = dict(os.environ)
    if args.env_file and args.env_file.exists():
        for line in args.env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env.setdefault(k.strip(), v.strip().strip('"').strip("'"))

    raw = gen.load_variant(args.config)
    cfg = gen.resolve_tree(raw, env)

    name = cfg["variant"]["name"]
    version = cfg["variant"].get("version", "0.0.0")

    # Guard against packing a stale tree. The renderer writes this file on
    # every run, so a mismatch means generate.py has not been run for this
    # variant at this version and the payload on disk belongs to something
    # else entirely.
    variant_cfg = gen.VARIANTS_DIR / name / "config"
    if not variant_cfg.exists():
        print(f"error: {variant_cfg} missing - run generate.py for this variant first",
              file=sys.stderr)
        return 1
    if f"DIST_VERSION='{version}'" not in variant_cfg.read_text(encoding="utf-8") \
            and f"DIST_VERSION={version}" not in variant_cfg.read_text(encoding="utf-8"):
        print(f"error: {variant_cfg} was rendered for a different version than {version}",
              file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp)
        files = stage(cfg, staging)
        if not files:
            print("error: nothing staged - has the variant been rendered?", file=sys.stderr)
            return 1

        hits = scan_for_secrets(staging, env)
        if hits:
            print("error: refusing to build a bundle containing credentials:", file=sys.stderr)
            for h in hits:
                print(f"  {h}", file=sys.stderr)
            return 1

        manifest = build_manifest(cfg, staging, files)

        # Sign the exact bytes that go into the archive, so the signature and
        # the manifest cannot drift apart through a re-serialisation.
        payload = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        key_pem = None if args.unsigned else load_signing_key()
        if key_pem is None and not args.unsigned:
            print("error: no signing key. Set BGRPIIMAGE_SIGNING_KEY (the PEM itself, "
                  "as CI does) or keep .secrets/bgrpiimage-recovery.key locally.\n"
                  "       Pass --unsigned only for a bundle no device is meant to apply.",
                  file=sys.stderr)
            return 1
        signature = sign(payload, key_pem) if key_pem else None

        stem = f"bgrpiimage-{name}-v{version}"
        tar_path = args.out / f"{stem}.confbundle.tar.gz"
        write_tar(staging, tar_path, manifest, signature)

    digest = _sha256_file(tar_path)
    (args.out / f"{stem}.confbundle.tar.gz.sha256").write_text(
        f"{digest}  {tar_path.name}\n", encoding="utf-8"
    )
    # Published beside the bundle so `update --check` can answer without
    # downloading it.
    (args.out / f"{stem}.bundle.manifest.json").write_bytes(payload)
    if signature is not None:
        # Sidecar for the standalone manifest, so `update check` can verify
        # what it reads without pulling the whole bundle.
        (args.out / f"{stem}.bundle.manifest.json.sig").write_bytes(signature)

    size_kb = tar_path.stat().st_size / 1024
    print(f"{tar_path}  ({size_kb:.1f} KB, {len(manifest['files'])} files, "
          f"{len(manifest['modules'])} modules)")
    print(f"  sha256 {digest}")
    print(f"  signed {'yes' if signature else 'NO - devices will refuse this bundle'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
