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
#   scripts/build.sh can-app                       # default variant
#   scripts/build.sh --env-file .env can-app
#   VARIANT=can-app scripts/build.sh
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
VARIANT="${VARIANT:-can-app}"
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

# Update build_dist symlinks inside CustomPiOS.
( cd "$ROOT/CustomPiOS/src" && bash update "$ROOT/src" )

# Use guysoft/custompios container to run the build with loop device access.
DOCKER_IMAGE="${DOCKER_IMAGE:-guysoft/custompios:devel}"
WORKSPACE="$ROOT/src/workspace"
mkdir -p "$WORKSPACE" dist

echo "[build] launching container $DOCKER_IMAGE"
docker run --rm --privileged \
    --volume "$ROOT":/distro \
    --workdir /distro/src \
    "$DOCKER_IMAGE" \
    bash -c "./build_dist"

# CustomPiOS leaves the image in src/workspace.
IMG=$(ls -1 "$WORKSPACE"/*.img 2>/dev/null | head -n1 || true)
if [[ -z "$IMG" ]]; then
    echo "error: no .img produced in $WORKSPACE" >&2
    exit 1
fi

OUT="dist/bgos-${VARIANT}-$(date +%Y%m%d).img"
cp -v "$IMG" "$OUT"
echo "[build] compressing"
xz -T0 -f "$OUT"
echo "[build] done -> ${OUT}.xz"
