#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
BAUER GROUP XPD-RPIImage - Pages site + RPi Imager catalog renderer.

Loads HTML templates from disk (site/*.tmpl) and substitutes {{placeholders}}.
No Jinja or other heavy deps - keeps the Pages workflow dependency-free
beyond what the build scripts already need.

Input:
    --manifests DIR     directory with one *.manifest.json per variant
    --tag       vX.Y.Z  release tag to display
    --repo      owner/name
    --catalog-url URL   public URL of the rpi-imager.json
    --templates DIR     directory containing index.html.tmpl + card.html.tmpl
    --out       DIR     destination directory for the rendered site

Output (in --out):
    rpi-imager.json   catalog consumed by RPi Imager's Custom Repository
    index.html        human-facing landing page
    .nojekyll         disables Jekyll on GitHub Pages (we ship pre-rendered HTML)

`styles.css` and `CNAME` are copied by the workflow, not rendered here.
"""
from __future__ import annotations

import argparse
import html
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# RPi Imager device names - maps our JSON targets to Imager's identifiers.
TARGET_TO_IMAGER_DEVICE = {
    "rpi4": "pi4-64bit",
    "rpi5": "pi5",
    "cm4":  "cm4",
    "cm5":  "cm5",
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


def substitute(template: str, values: dict[str, str]) -> str:
    """Replace every `{{key}}` with `values[key]`.

    Values that are missing are kept as-is so typos are visible in the
    rendered output rather than silently expanding to empty. No nested
    substitution, no conditionals - if the template grows logic beyond
    this, promote to Jinja2 with a proper test suite.
    """
    out = template
    for key, value in values.items():
        out = out.replace("{{" + key + "}}", value)
    return out


def render_rpi_imager_json(manifests: list[dict[str, Any]], tag: str) -> dict[str, Any]:
    os_list: list[dict[str, Any]] = []
    for m in manifests:
        variant = m["variant"]
        img = m["image"]
        devices = [TARGET_TO_IMAGER_DEVICE[t] for t in m["targets"] if t in TARGET_TO_IMAGER_DEVICE]
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


def render_card(template: str, manifest: dict[str, Any], tag: str) -> str:
    img = manifest["image"]
    sha256_url   = img["url"] + ".sha256"
    # bgrpiimage-<variant>-vX.Y.Z.img.xz → bgrpiimage-<variant>-vX.Y.Z.manifest.json
    manifest_url = img["url"].rsplit(".img.xz", 1)[0] + ".manifest.json"
    values = {
        "variant":         html.escape(manifest["variant"]),
        "tag":             html.escape(tag),
        "description":     html.escape(manifest.get("description") or ""),
        "hostname":        html.escape(manifest.get("hostname") or "-"),
        "targets":         html.escape(", ".join(manifest["targets"])),
        "download_mib":    f"{img['download_size'] / 1024 / 1024:,.1f}",
        "extract_mib":     f"{img['extract_size']  / 1024 / 1024:,.1f}",
        "release_date":    html.escape(manifest.get("release_date") or "-"),
        "download_sha256": html.escape(img["download_sha256"]),
        "extract_sha256":  html.escape(img["extract_sha256"]),
        "image_url":       html.escape(img["url"]),
        "sha256_url":      html.escape(sha256_url),
        "manifest_url":    html.escape(manifest_url),
    }
    return substitute(template, values)


def render_index_html(
    index_template: str,
    card_template: str,
    manifests: list[dict[str, Any]],
    tag: str,
    repo: str,
    catalog_url: str,
) -> str:
    cards = "\n".join(render_card(card_template, m, tag) for m in manifests)
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return substitute(index_template, {
        "tag":         html.escape(tag),
        "repo":        html.escape(repo),
        "catalog_url": html.escape(catalog_url),
        "cards":       cards,
        "generated":   html.escape(generated),
    })


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifests",   required=True, type=Path)
    p.add_argument("--tag",         required=True)
    p.add_argument("--repo",        required=True)
    p.add_argument("--catalog-url", required=True)
    p.add_argument("--templates",   required=True, type=Path,
                   help="directory with index.html.tmpl + card.html.tmpl")
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
    index_tmpl = (args.templates / "index.html.tmpl").read_text(encoding="utf-8")
    card_tmpl  = (args.templates / "card.html.tmpl").read_text(encoding="utf-8")
    html_text = render_index_html(index_tmpl, card_tmpl, manifests,
                                   args.tag, args.repo, args.catalog_url)
    (args.out / "index.html").write_text(html_text, encoding="utf-8")

    # --- .nojekyll -----------------------------------------------------------
    (args.out / ".nojekyll").write_text("", encoding="utf-8")

    print(f"wrote {len(manifests)} variant(s) into {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
