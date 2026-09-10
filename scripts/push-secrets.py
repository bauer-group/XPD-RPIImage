#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
BAUER GROUP XPD-RPIImage - push local key material into GitHub Actions secrets.

Release signing runs in CI, so the private signing key has to live in the
repository's Actions secrets. This is the supported way to put it there:
the web UI means pasting a private key into a browser, and
`gh secret set --body` puts it in the process arguments, where it is visible
in /proc and lands in shell history. Everything here goes over stdin.

MAINTENANCE
    The SECRETS table below is the only thing to edit - one entry per secret,
    giving the secret name, the file and whether it holds a private or public
    key. The kind is checked rather than trusted: uploading the .pub by
    accident and believing signing is configured would only surface when
    every device rejects every release.

Usage:
    python scripts/push-secrets.py --dry-run     # what would be pushed
    python scripts/push-secrets.py               # do it
    python scripts/push-secrets.py --list        # what is configured now
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    from cryptography.hazmat.primitives import serialization
    from rich import box
    from rich.console import Console
    from rich.panel import Panel
except ImportError:
    print("error: missing dependencies. run: pip install -r scripts/requirements.txt",
          file=sys.stderr)
    raise SystemExit(2)

console = Console()
ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Secret:
    name: str
    path: str
    private: bool = True


# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------
# BGRPIIMAGE_SIGNING_KEY is what the release workflow signs bundle manifests
# with; devices verify against the matching public key shipped in the image.
#
# A second keypair whose private half is kept genuinely OFFLINE - the one that
# lets trust be re-established if this one is ever compromised - does not
# belong here at all. Only its public half goes into the image tree, because a
# key held in CI cannot be the recovery for a compromise of CI.
SECRETS: list[Secret] = [
    Secret("BGRPIIMAGE_SIGNING_KEY", ".secrets/bgrpiimage-recovery.key"),
]


def error(title: str, body: str, hint: str | None = None) -> None:
    text = body
    if hint:
        text += f"\n\n[dim]hint:[/] {hint}"
    console.print(Panel(text, title=f"[red]{title}[/]", border_style="red", box=box.ROUNDED))


def run_gh(args: list[str], stdin: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(  # noqa: S603 - fixed argv, no shell
        ["gh", *args], input=stdin, capture_output=True, check=False
    )


def fingerprint(pem: bytes, private: bool) -> str:
    """Identify a key without revealing it.

    SHA-256 over the DER SubjectPublicKeyInfo, which is the same value whether
    it is derived from the private half or read from the public one. That is
    the point: print it when pushing, compare it later against the .pub that
    ships in the image, and "is CI signing with the right key" stays
    answerable without touching the private half again.
    """
    if private:
        key = serialization.load_pem_private_key(pem, password=None)
        pub = key.public_key()
    else:
        pub = serialization.load_pem_public_key(pem)
    der = pub.public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return base64.b64encode(hashlib.sha256(der).digest()).decode()[:32]


def load(secret: Secret) -> tuple[bytes, str, bool]:
    """Read and validate one entry. Returns (normalised pem, fingerprint, had_crlf)."""
    path = ROOT / secret.path
    if not path.is_file():
        error(
            "key file missing",
            f"{secret.name}: no such file: {secret.path}",
            "generate it with:\n"
            f"  openssl genpkey -algorithm ed25519 -out {secret.path}\n"
            # as_posix(): the hint is a command to copy and paste, and a
            # Windows separator would not survive that.
            f"  openssl pkey -in {secret.path} -pubout -out "
            f"{Path(secret.path).with_suffix('.pub').as_posix()}",
        )
        raise SystemExit(1)

    raw = path.read_bytes()
    had_crlf = b"\r\n" in raw
    # The runner consumes this on Linux; these keys are generated on Windows
    # and carry CRLF, which would reach openssl verbatim.
    pem = raw.replace(b"\r\n", b"\n")

    # Decide on the PEM header rather than on whether a loader accepts it:
    # some builds happily read a public PEM through a private-key path, so
    # parseability does not tell the two halves apart.
    if secret.private and b"BEGIN PUBLIC KEY" in pem:
        error(
            "public key in a private slot",
            f"{secret.name}: {secret.path} contains a PUBLIC key.",
            "the public half never goes into a secret - it belongs in the image tree",
        )
        raise SystemExit(1)
    if not secret.private and b"PRIVATE KEY" in pem:
        error("private key in a public slot", f"{secret.name}: {secret.path} is a PRIVATE key.")
        raise SystemExit(1)

    try:
        fp = fingerprint(pem, secret.private)
    except Exception as exc:  # noqa: BLE001 - any parse failure is the same answer
        error("unreadable key", f"{secret.name}: {secret.path} could not be parsed.\n{exc}")
        raise SystemExit(1) from exc

    return pem, fp, had_crlf


def resolve_repo(explicit: str | None) -> str:
    if explicit:
        return explicit
    proc = run_gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"])
    if proc.returncode != 0:
        error(
            "repository unknown",
            "could not determine the repository from this checkout.",
            "pass --repo OWNER/NAME",
        )
        raise SystemExit(1)
    return proc.stdout.decode().strip()


def preflight() -> None:
    if shutil.which("gh") is None:
        error("gh not found", "the GitHub CLI is required.", "https://cli.github.com")
        raise SystemExit(1)
    if run_gh(["auth", "status"]).returncode != 0:
        error("not authenticated", "gh is not logged in.", "run: gh auth login")
        raise SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--dry-run", action="store_true", help="report without sending")
    ap.add_argument("-l", "--list", action="store_true", help="list secrets currently set")
    ap.add_argument("--repo", help="OWNER/NAME (default: this checkout's remote)")
    args = ap.parse_args()

    preflight()
    repo = resolve_repo(args.repo)

    if args.list:
        console.print(f"[cyan]secrets on[/] {repo}")
        proc = run_gh(["secret", "list", "--repo", repo])
        sys.stdout.write(proc.stdout.decode())
        return proc.returncode

    # One line per secret rather than a table: a fingerprint that gets
    # ellipsised to fit a narrow terminal identifies nothing, which is the one
    # thing this output exists to do.
    def report(secret: Secret, fp: str, had_crlf: bool, done: bool) -> None:
        mark = "[green]+[/]" if done else "[dim]·[/]"
        console.print(f"{mark} [cyan]{secret.name}[/]")
        crlf = " [yellow](CRLF normalised)[/]" if had_crlf else ""
        console.print(f"    from        {secret.path}{crlf}")
        console.print(f"    fingerprint {fp}")

    prepared: list[tuple[Secret, bytes, str, bool]] = [
        (secret, *load(secret)) for secret in SECRETS
    ]

    if args.dry_run:
        console.print(f"[cyan]would set on[/] {repo}")
        for secret, _pem, fp, had_crlf in prepared:
            report(secret, fp, had_crlf, done=False)
        console.print("[cyan]dry run[/] - nothing was sent")
        return 0

    for secret, pem, fp, had_crlf in prepared:
        proc = run_gh(["secret", "set", secret.name, "--repo", repo], stdin=pem)
        if proc.returncode != 0:
            error("upload failed", f"{secret.name}: {proc.stderr.decode().strip()}")
            return 1
        report(secret, fp, had_crlf, done=True)

    console.print(
        Panel(
            f"{len(prepared)} secret(s) updated on [bold]{repo}[/].\n\n"
            "The fingerprints above identify which key CI now signs with. The\n"
            "matching public key belongs in the image tree, not in a secret.",
            title="[green]done[/]", border_style="green", box=box.ROUNDED,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
