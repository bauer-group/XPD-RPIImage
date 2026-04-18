#!/usr/bin/env bash
# Clone/update CustomPiOS into ./CustomPiOS (gitignored).
# Pin via CUSTOMPIOS_REF env var for reproducible builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUSTOMPIOS_DIR="$ROOT/CustomPiOS"
CUSTOMPIOS_URL="${CUSTOMPIOS_URL:-https://github.com/guysoft/CustomPiOS.git}"
# Using master because 1.5.0 predates raspios's switch to .img.xz (its
# variants/raspios_lite_arm64/config still globs for *.zip only) and lacks
# the base_image_downloader.  OctoPi also tracks master.  For a reproducible
# build, pin to a specific commit via CUSTOMPIOS_REF=<sha>.
CUSTOMPIOS_REF="${CUSTOMPIOS_REF:-master}"

if [[ ! -d "$CUSTOMPIOS_DIR/.git" ]]; then
    echo "[bootstrap] cloning CustomPiOS from $CUSTOMPIOS_URL @ $CUSTOMPIOS_REF"
    git clone --depth 1 --branch "$CUSTOMPIOS_REF" "$CUSTOMPIOS_URL" "$CUSTOMPIOS_DIR"
else
    echo "[bootstrap] CustomPiOS already present - fetching $CUSTOMPIOS_REF"
    git -C "$CUSTOMPIOS_DIR" fetch origin "$CUSTOMPIOS_REF"
    git -C "$CUSTOMPIOS_DIR" checkout -f "$CUSTOMPIOS_REF"
    git -C "$CUSTOMPIOS_DIR" pull --ff-only origin "$CUSTOMPIOS_REF" || true
fi

echo "[bootstrap] CustomPiOS HEAD: $(git -C "$CUSTOMPIOS_DIR" rev-parse --short HEAD)"
