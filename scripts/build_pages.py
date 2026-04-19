#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
BAUER GROUP XPD-RPIImage - Pages site + RPi Imager catalog renderer.

Input:
    --manifests DIR   directory with one `*.manifest.json` per variant
                      (produced by build.yml's checksum step)
    --tag      vX.Y.Z tag to display on the landing page
    --repo     owner/name   e.g. bauer-group/XPD-RPIImage
    --out      DIR    destination directory for the rendered site

Output (in --out):
    rpi-imager.json   catalog consumed by RPi Imager's Custom Repository
    index.html        human-facing landing page (rich info + direct flash links)
    styles.css        minimal, framework-free styling
    .nojekyll         disables Jekyll on GitHub Pages

CNAME is NOT rendered here - the workflow copies it from site/CNAME so the
custom domain lives in git instead of being re-generated on every run.
"""
from __future__ import annotations

import argparse
import html
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# RPi Imager devices names - mapping our JSON `targets` enum to Imager's
# board identifiers. Entries left out here will be hidden on unknown boards.
TARGET_TO_IMAGER_DEVICE = {
    "rpi4": "pi4-64bit",
    "rpi5": "pi5",
    "cm4":  "cm4",
    "cm5":  "cm5",
}


def load_manifests(directory: Path) -> list[dict[str, Any]]:
    """Read every `*.manifest.json` in `directory`, sorted by variant name."""
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
    """Produce the RPi Imager Custom Repository JSON."""
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


def render_index_html(manifests: list[dict[str, Any]], tag: str, repo: str, catalog_url: str) -> str:
    """Produce the standalone landing page."""
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    cards = []
    for m in manifests:
        variant = m["variant"]
        img = m["image"]
        targets = ", ".join(m["targets"])
        download_mb = img["download_size"] / 1024 / 1024
        extract_mb = img["extract_size"] / 1024 / 1024
        card = f"""
        <article class="card">
          <header>
            <h2>{html.escape(variant)}</h2>
            <span class="tag">{html.escape(tag)}</span>
          </header>
          <p class="description">{html.escape(m.get('description') or '')}</p>
          <dl class="meta">
            <dt>Hostname</dt><dd><code>{html.escape(m.get('hostname') or '-')}</code></dd>
            <dt>Targets</dt><dd>{html.escape(targets)}</dd>
            <dt>Download size</dt><dd>{download_mb:,.1f} MiB</dd>
            <dt>Extracted size</dt><dd>{extract_mb:,.1f} MiB</dd>
            <dt>Release date</dt><dd>{html.escape(m.get('release_date') or '-')}</dd>
          </dl>
          <div class="checksums">
            <div><span class="label">SHA-256 (.img.xz)</span><code>{html.escape(img['download_sha256'])}</code></div>
            <div><span class="label">SHA-256 (.img)</span><code>{html.escape(img['extract_sha256'])}</code></div>
          </div>
          <div class="actions">
            <a class="btn primary" href="{html.escape(img['url'])}">⬇ Download .img.xz</a>
            <a class="btn"         href="{html.escape(img['url'])}.sha256">.sha256</a>
            <a class="btn"         href="{html.escape(img['url']).rsplit('.img.xz', 1)[0]}.manifest.json">manifest.json</a>
          </div>
        </article>
        """
        cards.append(card)

    cards_html = "\n".join(cards)
    catalog_copy_id = "catalog-url"
    safe_repo = html.escape(repo)
    safe_tag = html.escape(tag)
    safe_catalog = html.escape(catalog_url)
    safe_generated = html.escape(generated)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>BAUER GROUP RPIImage – latest release {safe_tag}</title>
  <meta name="description" content="Declarative, reproducible Raspberry Pi OS images by BAUER GROUP. RPi Imager catalog + direct downloads." />
  <link rel="stylesheet" href="styles.css" />
  <link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20viewBox%3D%220%200%20100%20100%22%3E%3Crect%20width%3D%22100%22%20height%3D%22100%22%20rx%3D%2220%22%20fill%3D%22%23e80d2e%22%2F%3E%3Ctext%20x%3D%2250%22%20y%3D%2268%22%20font-family%3D%22sans-serif%22%20font-size%3D%2258%22%20font-weight%3D%22900%22%20fill%3D%22white%22%20text-anchor%3D%22middle%22%3EB%3C%2Ftext%3E%3C%2Fsvg%3E" />
</head>
<body>
  <header class="hero">
    <div class="inner">
      <h1>📦 BAUER GROUP <span class="accent">RPIImage</span></h1>
      <p class="subtitle">Declarative, reproducible, CI-built Raspberry Pi OS images for production and development.</p>
      <p class="release">Current release: <a href="https://github.com/{safe_repo}/releases/tag/{safe_tag}"><strong>{safe_tag}</strong></a></p>
    </div>
  </header>

  <main>
    <section class="pitch">
      <h2>🛠 Add this repo to Raspberry Pi Imager</h2>
      <ol class="steps">
        <li>Install <a href="https://www.raspberrypi.com/software/">Raspberry Pi Imager</a> (v1.8.5 or later).</li>
        <li>Open it and go to <strong>Settings</strong> (the ⚙ icon) → <strong>Custom repository</strong>.</li>
        <li>Paste the catalog URL below and close the settings dialog:
          <div class="copyrow">
            <code id="{catalog_copy_id}">{safe_catalog}</code>
            <button type="button" onclick="navigator.clipboard.writeText(document.getElementById('{catalog_copy_id}').innerText)">Copy</button>
          </div>
        </li>
        <li>Restart Imager. Our variants now appear under <strong>Operating System → BAUER GROUP</strong>.</li>
        <li>Pick your target device → pick an image → flash.</li>
      </ol>

      <h3>🧷 Flashing a Compute Module (CM4 / CM5 eMMC)</h3>
      <ol>
        <li>Put the carrier board in <strong>rpiboot mode</strong>:
          <ul>
            <li><strong>CM4 IO-Board</strong>: fit the jumper on <code>J2</code> (Disable eMMC Boot).</li>
            <li><strong>CM5 IO-Board</strong>: bridge the <code>nRPIBOOT</code> test pad (or set the fit-jumper where provided).</li>
          </ul>
        </li>
        <li>Connect the <strong>USB-C slave port</strong> (not the host USB) to your machine.</li>
        <li>Power the board. RPi Imager (≥ 1.8.5) detects the CM as <em>"RPi"</em> mass storage via its built-in <code>rpiboot</code>.</li>
        <li>Flash as usual.</li>
        <li>Remove the jumper, re-power, boot.</li>
      </ol>
    </section>

    <section class="variants">
      <h2>🧩 Variants in this release</h2>
      <div class="cards">
        {cards_html}
      </div>
    </section>

    <section class="security">
      <h2>🔐 Default credentials</h2>
      <p>These images ship with <strong>demo credentials</strong> - safe only on an isolated lab network:</p>
      <ul>
        <li><code>admin</code> password → <code>12345678</code></li>
        <li>WiFi PSK for <code>IOT @ BAUER-GROUP</code> → <code>12345678</code></li>
      </ul>
      <p>Bake real values at build time via <code>.env</code>, or change them post-flash with:</p>
      <pre><code>sudo bgrpiimage-setup password
sudo bgrpiimage-setup wifi "MyNet" "s3cret" DE
sudo bgrpiimage-setup ip eth0 static 10.0.0.5/24 10.0.0.1 1.1.1.1</code></pre>
    </section>

    <section class="meta-links">
      <h2>📚 More</h2>
      <ul>
        <li><a href="https://github.com/{safe_repo}">Repository on GitHub</a></li>
        <li><a href="https://github.com/{safe_repo}/releases">All releases</a></li>
        <li><a href="https://github.com/{safe_repo}/blob/main/docs/hardware.md">Hardware reference</a></li>
        <li><a href="https://github.com/{safe_repo}/blob/main/docs/flash.md">Flashing guide</a></li>
        <li><a href="https://github.com/{safe_repo}/blob/main/docs/configuration.md">JSON configuration reference</a></li>
      </ul>
    </section>
  </main>

  <footer>
    <p>© BAUER GROUP · <a href="https://github.com/{safe_repo}/blob/main/LICENSE">MIT</a> · generated {safe_generated}</p>
  </footer>
</body>
</html>
"""


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifests", required=True, type=Path)
    p.add_argument("--tag",       required=True)
    p.add_argument("--repo",      required=True)
    p.add_argument("--catalog-url", required=True,
                   help="Public URL where rpi-imager.json will be served.")
    p.add_argument("--out",       required=True, type=Path)
    args = p.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    manifests = load_manifests(args.manifests)

    catalog = render_rpi_imager_json(manifests, args.tag)
    (args.out / "rpi-imager.json").write_text(
        json.dumps(catalog, indent=2) + "\n", encoding="utf-8"
    )

    html_text = render_index_html(manifests, args.tag, args.repo, args.catalog_url)
    (args.out / "index.html").write_text(html_text, encoding="utf-8")

    # .nojekyll disables the default Jekyll build on GitHub Pages - we ship
    # pre-rendered HTML and don't want Jekyll to mangle it.
    (args.out / ".nojekyll").write_text("", encoding="utf-8")

    print(f"wrote {len(manifests)} variant(s) into {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
