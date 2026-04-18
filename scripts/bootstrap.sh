#!/usr/bin/env bash
# Clone/update CustomPiOS into ./CustomPiOS (gitignored).
# Pin via CUSTOMPIOS_REF env var for reproducible builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUSTOMPIOS_DIR="$ROOT/CustomPiOS"
CUSTOMPIOS_URL="${CUSTOMPIOS_URL:-https://github.com/guysoft/CustomPiOS.git}"
# Pin the upstream scripts: we test against this specific tag.  Keep this
# in lock-step with the :1.5.0 docker tooling image.  Override via env.
CUSTOMPIOS_REF="${CUSTOMPIOS_REF:-1.5.0}"

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
