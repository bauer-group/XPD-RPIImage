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
chmod +x "$ROOT/src/build_dist"
mkdir -p dist

# ---------------------------------------------------------------------------
# Download + pre-extract the raspios base image.
#
# CustomPiOS itself only understands `.zip` bundles (see its
# variants/raspios_lite_arm64/config: `ls -t *-{raspbian,raspios}-*.zip`),
# while current Raspberry Pi OS is distributed as `.img.xz`.  Easiest fix:
# do the fetch + unxz ourselves and drop the raw `.img` directly into the
# workspace that CustomPiOS then picks up via `pushd $BASE_WORKSPACE;
# [ -e *.img ]`.  Cached in src/image-cache/ so re-runs are fast.
# ---------------------------------------------------------------------------
WORKSPACE="$ROOT/src/workspace-${VARIANT}"
mkdir -p "$WORKSPACE"
if ! ls "$WORKSPACE"/*.img >/dev/null 2>&1; then
    echo "[build] preparing base image for '$VARIANT'"
    IMAGE_URL=$(python3 - <<PY
import json
cfg = json.load(open("$CONFIG_JSON"))
# extends chain is resolved lazily by the generator - but for the URL we
# need to walk it by hand since we are not loading the full renderer here.
from pathlib import Path
seen = set()
while "extends" in cfg and str(Path("$CONFIG_JSON").resolve()) not in seen:
    seen.add(str(Path("$CONFIG_JSON").resolve()))
    parent_rel = cfg["extends"]
    cfg.pop("extends")
    parent_path = (Path("$CONFIG_JSON").resolve().parent / parent_rel).resolve()
    parent = json.load(open(parent_path))
    # shallow: take parent's base_image only if child does not set one.
    parent.update({k: v for k, v in cfg.items() if v is not None})
    cfg = parent
print(cfg["base_image"]["url"])
PY
    )
    echo "[build] URL: $IMAGE_URL"

    CACHE="$ROOT/src/image-cache"
    mkdir -p "$CACHE"
    IMG_XZ="$CACHE/$(basename "$IMAGE_URL")"
    IMG_RAW="${IMG_XZ%.xz}"

    if [[ ! -f "$IMG_XZ" && ! -f "$IMG_RAW" ]]; then
        echo "[build] downloading $IMG_XZ"
        curl -fSL --retry 3 -o "$IMG_XZ.partial" "$IMAGE_URL"
        mv "$IMG_XZ.partial" "$IMG_XZ"
    fi
    if [[ -f "$IMG_XZ" && ! -f "$IMG_RAW" ]]; then
        echo "[build] unxz $IMG_XZ"
        xz -d --keep "$IMG_XZ"
    fi

    cp -v "$IMG_RAW" "$WORKSPACE/"
    echo "[build] placed $(basename "$IMG_RAW") into $WORKSPACE"
fi

# Two build paths:
#   BGRPI_NATIVE_BUILD=yes  -> run directly on the host (CI runners, bare
#                              Linux dev boxes). No image pull, no privileged
#                              sibling container. Assumes qemu-user-static /
#                              kpartx / xz / sfdisk are already installed.
#   unset / no              -> run inside guysoft/custompios sibling container.
#                              For local dev on macOS, Windows, or when the
#                              host lacks build tooling.
if [[ "${BGRPI_NATIVE_BUILD:-no}" == "yes" ]]; then
    echo "[build] native mode (no docker) for variant '$VARIANT'"
    bash "$ROOT/CustomPiOS/src/update-custompios-paths" "$ROOT/src"
    ( cd "$ROOT/src" && bash ./build_dist "$VARIANT" )
else
    DOCKER_IMAGE="${DOCKER_IMAGE:-guysoft/custompios:devel}"
    echo "[build] launching container $DOCKER_IMAGE for variant '$VARIANT'"
    # update-custompios-paths must run INSIDE the container so the
    # custompios_path sidecar records /distro/CustomPiOS/src (the bind-mount
    # path) instead of the host's absolute path.
    docker run --rm --privileged \
        --volume "$ROOT":/distro \
        --workdir /distro/src \
        "$DOCKER_IMAGE" \
        bash -c "bash /distro/CustomPiOS/src/update-custompios-paths /distro/src \
                 && ./build_dist ${VARIANT}"
fi

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

OUT="dist/bgrpiimage-${VARIANT}-v${VERSION}${SUFFIX}.img"
cp -v "$IMG" "$OUT"
echo "[build] compressing"
xz -T0 -f "$OUT"
echo "[build] done -> ${OUT}.xz"
