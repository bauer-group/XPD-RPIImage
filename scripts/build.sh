#!/usr/bin/env bash
# BAUER GROUP XPD-RPIImage - local image build driver.
#
# Steps:
#   1. Resolve variant JSON + render generated files into src/modules/*/files/_generated
#   2. Ensure CustomPiOS is cloned
#   3. Link ./src into CustomPiOS and invoke its build in a privileged Docker container
#   4. Copy the resulting .img[.xz] into ./dist/
#
# Usage:
#   scripts/build.sh canbus-plattform                       # default variant
#   scripts/build.sh --env-file .env canbus-plattform
#   VARIANT=canbus-plattform scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file) ENV_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
        *) VARIANT="$1"; shift ;;
    esac
done
VARIANT="${VARIANT:-canbus-plattform}"
CONFIG_JSON="config/variants/${VARIANT}.json"

if [[ ! -f "$CONFIG_JSON" ]]; then
    echo "error: $CONFIG_JSON not found" >&2
    exit 2
fi

echo "[build] rendering variant '$VARIANT'"
PY_ARGS=("$CONFIG_JSON")
[[ -n "$ENV_FILE" ]] && PY_ARGS=(--env-file "$ENV_FILE" "${PY_ARGS[@]}")
python3 scripts/generate.py "${PY_ARGS[@]}"

echo "[build] ensuring CustomPiOS"
bash scripts/bootstrap.sh

# Write custompios_path sidecar into our distro src/ so build_dist can find
# the CustomPiOS scripts. This replaces the old `bash update` command.
bash "$ROOT/CustomPiOS/src/update-custompios-paths" "$ROOT/src"
chmod +x "$ROOT/src/build_dist"

# Use guysoft/custompios container to run the build with loop device access.
DOCKER_IMAGE="${DOCKER_IMAGE:-guysoft/custompios:devel}"
mkdir -p dist

echo "[build] launching container $DOCKER_IMAGE for variant '$VARIANT'"
docker run --rm --privileged \
    --volume "$ROOT":/distro \
    --workdir /distro/src \
    "$DOCKER_IMAGE" \
    bash -c "./build_dist ${VARIANT}"

# CustomPiOS leaves the image in workspace-<variant> for non-default variants.
for ws in "$ROOT/src/workspace-${VARIANT}" "$ROOT/src/workspace"; do
    [[ -d "$ws" ]] || continue
    IMG=$(ls -1 "$ws"/*.img 2>/dev/null | head -n1 || true)
    [[ -n "$IMG" ]] && break
done
if [[ -z "${IMG:-}" ]]; then
    echo "error: no .img produced (looked in workspace-${VARIANT} and workspace)" >&2
    exit 1
fi

# Derive version + optional suffix for the output filename.
#   VERSION       - from env (CI sets it) or parsed from the variant JSON
#   IMAGE_SUFFIX  - appended after the version, e.g. '-abc1234' for push
#                   builds; empty for tag releases so the asset is clean.
if [[ -z "${VERSION:-}" ]]; then
    VERSION=$(python3 - <<PY
import json, sys
try:
    print(json.load(open("$CONFIG_JSON"))["variant"].get("version", "0.0.0"))
except Exception:
    print("0.0.0")
PY
)
fi
SUFFIX="${IMAGE_SUFFIX:-}"

OUT="dist/bgRPIImage-${VARIANT}-v${VERSION}${SUFFIX}.img"
cp -v "$IMG" "$OUT"
echo "[build] compressing"
xz -T0 -f "$OUT"
echo "[build] done -> ${OUT}.xz"
