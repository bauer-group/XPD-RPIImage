#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
BAUER GROUP XPD-RPIImage - Pages site + RPi Imager catalog renderer.

Uses Jinja2 for the landing page (autoescape on, proper {% for %} over
variants, filters for size formatting). The RPi Imager catalog is pure
data so we emit it with json.dumps rather than a template.

Input:
    --manifests DIR     directory with one *.manifest.json per variant
    --tag       vX.Y.Z  release tag to display
    --repo      owner/name
    --catalog-url URL   public URL of the rpi-imager.json
    --templates DIR     directory with index.html.j2 (autoescape enabled)
    --out       DIR     destination directory for the rendered site

Output (in --out):
    rpi-imager.json   catalog consumed by RPi Imager's Custom Repository
    index.html        human-facing landing page
    .nojekyll         disables Jekyll on GitHub Pages

`styles.css` and `CNAME` are copied by the workflow, not rendered here.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape


# RPi Imager device tags - maps our JSON `targets` enum to Imager filter tags.
# The Imager UI groups Compute Modules with their Pi siblings: CM4/CM4S sit
# under "Raspberry Pi 4" (tags pi4-64bit / pi4-32bit) and CM5 sits under
# "Raspberry Pi 5" (tags pi5-64bit / pi5-32bit) - there are no standalone
# cm4/cm5 tags. We ship arm64 images, so we emit only the -64bit family tag.
TARGET_TO_IMAGER_DEVICES: dict[str, list[str]] = {
    "rpi4": ["pi4-64bit"],
    "rpi5": ["pi5-64bit"],
    "cm4":  ["pi4-64bit"],
    "cm5":  ["pi5-64bit"],
}


def load_manifests(directory: Path) -> list[dict[str, Any]]:
    paths = sorted(directory.glob("*.manifest.json"))
    if not paths:
        print(f"error: no *.manifest.json in {directory}", file=sys.stderr)
        sys.exit(2)
    out: list[dict[str, Any]] = []
    for p in paths:
        with p.open("r", encoding="utf-8") as f:
            out.append(json.load(f))
    return out


def render_rpi_imager_json(manifests: list[dict[str, Any]], tag: str) -> dict[str, Any]:
    os_list: list[dict[str, Any]] = []
    for m in manifests:
        variant = m["variant"]
        img = m["image"]
        # Targets are already constrained by config/schema.json; an unknown
        # value here means the schema enum and this mapping have drifted -
        # fail loudly rather than silently emit an empty `devices` array
        # (which is what hides a variant in RPi Imager).
        seen: set[str] = set()
        devices: list[str] = []
        for t in m["targets"]:
            if t not in TARGET_TO_IMAGER_DEVICES:
                raise ValueError(
                    f"variant {m.get('variant')!r}: target {t!r} has no "
                    f"Imager tag mapping in TARGET_TO_IMAGER_DEVICES "
                    f"(known: {sorted(TARGET_TO_IMAGER_DEVICES)})"
                )
            for d in TARGET_TO_IMAGER_DEVICES[t]:
                if d not in seen:
                    seen.add(d)
                    devices.append(d)
        os_list.append({
            "name": f"BAUER GROUP RPIImage - {variant} {tag}",
            "description": m.get("description") or f"{variant} image, version {tag}",
            "url": img["url"],
            "release_date": m.get("release_date", ""),
            "extract_size": img["extract_size"],
            "extract_sha256": img["extract_sha256"],
            "image_download_size": img["download_size"],
            "image_download_sha256": img["download_sha256"],
            "devices": devices,
        })
    return {
        "imager": {
            "latest_version": tag,
            "url": "https://github.com/raspberrypi/rpi-imager/releases",
        },
        "os_list": os_list,
    }


def build_jinja_env(templates_dir: Path) -> Environment:
    """Jinja env with autoescape + strict undefined + a MiB filter.

    StrictUndefined raises on `{{ foo }}` where `foo` is missing - typos in
    the template fail the build instead of rendering as `""`, same safety
    contract we had with the previous text substitution.
    """
    env = Environment(
        loader=FileSystemLoader(templates_dir),
        autoescape=select_autoescape(["html", "htm", "xml", "j2"]),
        undefined=StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    env.filters["mib"] = lambda bytes_: f"{bytes_ / 1024 / 1024:,.1f}"
    return env


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifests",   required=True, type=Path)
    p.add_argument("--tag",         required=True)
    p.add_argument("--repo",        required=True)
    p.add_argument("--catalog-url", required=True)
    p.add_argument("--templates",   required=True, type=Path,
                   help="directory with index.html.j2")
    p.add_argument("--out",         required=True, type=Path)
    args = p.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    manifests = load_manifests(args.manifests)

    # --- rpi-imager.json -----------------------------------------------------
    catalog = render_rpi_imager_json(manifests, args.tag)
    (args.out / "rpi-imager.json").write_text(
        json.dumps(catalog, indent=2) + "\n", encoding="utf-8"
    )

    # --- index.html ----------------------------------------------------------
    env = build_jinja_env(args.templates)
    tmpl = env.get_template("index.html.j2")
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    html_text = tmpl.render(
        manifests=manifests,
        tag=args.tag,
        repo=args.repo,
        catalog_url=args.catalog_url,
        generated=generated,
    )
    (args.out / "index.html").write_text(html_text, encoding="utf-8")

    # --- .nojekyll -----------------------------------------------------------
    (args.out / ".nojekyll").write_text("", encoding="utf-8")

    print(f"wrote {len(manifests)} variant(s) into {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
