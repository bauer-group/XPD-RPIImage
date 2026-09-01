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
# CustomPiOS itself only understands `.zip` bundles (it shells out to 7za)
# while current Raspberry Pi OS is distributed as `.img.xz`.  We fetch the
# URL from the variant JSON ourselves, unxz once, and point BASE_ZIP_IMG
# at the cached raw `.img`.  CustomPiOS takes the ".img$" path (just cp)
# instead of the 7za extraction path - and crucially keeps our cached copy
# intact because it wipes `*.img` only from BASE_WORKSPACE.
# ---------------------------------------------------------------------------
echo "[build] preparing base image for '$VARIANT'"
# Resolve through generate.py rather than re-implementing the extends merge.
# The previous inline version merged with a shallow dict.update(), so a child
# variant that overrode only base_image.url replaced the whole base_image
# object and silently lost the inherited sha256 - which downgraded the
# integrity check below to a warning on exactly the variants most likely to
# point at a different image. generate.py deep-merges, and is the same
# resolver the build and CI already trust.
IMAGE_META=$(python3 scripts/generate.py "${PY_ARGS[@]}" --json | python3 -c '
import json, sys
img = json.load(sys.stdin)["base_image"]
print(img["url"])
print(img.get("sha256", ""))')
IMAGE_URL=$(sed -n '1p' <<<"$IMAGE_META")
IMAGE_SHA256=$(sed -n '2p' <<<"$IMAGE_META")
echo "[build] URL: $IMAGE_URL"

CACHE="$ROOT/src/image-cache"
mkdir -p "$CACHE"
IMG_XZ="$CACHE/$(basename "$IMAGE_URL")"
IMG_RAW="${IMG_XZ%.xz}"

# The declared base_image.sha256 covers the .img.xz, but the artifact
# CustomPiOS actually consumes is the extracted .img (see BASE_ZIP_IMG below).
# `xz -d --keep` leaves both files, so the steady state is a .img sitting
# next to its .xz - and verifying only the .xz would let a truncated or
# swapped .img through under a reassuring "verified" log line.
#
# So: verify the .xz against the declared hash, extract from the verified
# .xz, and record the resulting .img's own hash. A warm cache re-checks the
# .img against that record, which also catches an interrupted extraction
# (a SIGKILL during xz leaves a short .img beside an intact .xz).
STAMP="${IMG_RAW}.verified"

img_is_trusted() {
    [[ -n "$IMAGE_SHA256" && -f "$IMG_RAW" && -f "$STAMP" ]] || return 1
    local want_xz want_img
    read -r want_xz want_img < "$STAMP" || return 1
    # Re-extract when the config now pins a different upstream image.
    [[ "$want_xz" == "$IMAGE_SHA256" ]] || return 1
    [[ "$(sha256sum "$IMG_RAW" | cut -d' ' -f1)" == "$want_img" ]]
}

if img_is_trusted; then
    echo "[build] base image verified from cache: $(basename "$IMG_RAW")"
else
    if [[ ! -f "$IMG_XZ" ]]; then
        echo "[build] downloading $IMG_XZ"
        curl -fSL --retry 3 -o "$IMG_XZ.partial" "$IMAGE_URL"
        mv "$IMG_XZ.partial" "$IMG_XZ"
    fi

    if [[ -n "$IMAGE_SHA256" ]]; then
        echo "[build] verifying sha256 of $(basename "$IMG_XZ")"
        if ! echo "${IMAGE_SHA256}  ${IMG_XZ}" | sha256sum -c - >/dev/null 2>&1; then
            # Computed separately so a missing sha256sum cannot abort us
            # before the explanation is printed.
            actual=$(sha256sum "$IMG_XZ" 2>/dev/null | cut -d' ' -f1) \
                || actual="<could not compute>"
            echo "error: base image checksum mismatch - refusing to build" >&2
            echo "       expected: ${IMAGE_SHA256}" >&2
            echo "       actual:   ${actual}" >&2
            echo "       file:     ${IMG_XZ}" >&2
            echo "       if the upstream image was re-released, update" >&2
            echo "       base_image.sha256 in the variant config; otherwise" >&2
            echo "       delete the file and let it re-download." >&2
            exit 1
        fi
    else
        echo "[build] WARNING: no base_image.sha256 declared - image NOT verified" >&2
    fi

    echo "[build] unxz $IMG_XZ"
    rm -f "$IMG_RAW" "$STAMP"
    xz -d --keep "$IMG_XZ"
    if [[ -n "$IMAGE_SHA256" ]]; then
        printf '%s  %s\n' "$IMAGE_SHA256" \
            "$(sha256sum "$IMG_RAW" | cut -d' ' -f1)" > "$STAMP"
    fi
fi

# CustomPiOS's custompios script wipes *.img from BASE_WORKSPACE right at
# the start, so we MUST NOT put our cached copy there.  Instead hand it
# the path via BASE_ZIP_IMG; CustomPiOS sees the ".img$" suffix and falls
# into the `cp "$BASE_ZIP_IMG" .` branch, copying it into the workspace.
#
# config.local is sourced LAST by CustomPiOS (after dist-config, board,
# variant, flavor) so we override the auto-loaded raspios_lite_arm64
# variant which sets its own BASE_ZIP_IMG to an empty .zip glob.  The
# path uses $DIST_PATH so it resolves correctly in both native (host)
# and docker (container) runs.
CACHE_REL="image-cache/$(basename "$IMG_RAW")"
cat > "$ROOT/src/config.local" <<EOF
# Auto-generated by scripts/build.sh - do not edit, will be overwritten.
export BASE_ZIP_IMG="\${DIST_PATH}/${CACHE_REL}"
EOF
echo "[build] config.local: BASE_ZIP_IMG=\${DIST_PATH}/${CACHE_REL}"

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
    # ghcr.io, not Docker Hub: upstream moved its registry in CustomPiOS
    # commit 1027bcbd and guysoft/custompios:devel has been unmaintained
    # since 2025-02. Tag matches the CUSTOMPIOS_REF pin in bootstrap.sh -
    # the container only supplies OS deps (the bind-mounted checkout is what
    # actually executes), but a v2 checkout needs v2's python packages.
    DOCKER_IMAGE="${DOCKER_IMAGE:-ghcr.io/guysoft/custompios:sha-d293309}"
    echo "[build] launching container $DOCKER_IMAGE for variant '$VARIANT'"
    # The sibling container is launched against the HOST docker daemon, so the
    # --volume source must be a path the HOST can see. When we are ourselves
    # running inside the tools container, $ROOT is /workspace - which does not
    # exist on the host, so Docker would silently create an empty directory and
    # mount that. tools/run.* therefore export the real host path here.
    # The sibling is created by the HOST docker daemon, so --volume sources are
    # resolved by the daemon, never by us. Two cases:
    #
    #   in the tools container -> inherit our OWN mounts with --volumes-from.
    #       The daemon already knows them because it created them, so this
    #       needs no host-path translation at all and behaves identically on
    #       Windows, macOS and Linux. Bind-mounting $ROOT here instead would
    #       hand the daemon /workspace, which does not exist on the host - it
    #       would silently create an empty directory and mount that.
    #
    #   on a plain host -> bind the project at its OWN path, so the paths below
    #       are valid in both cases and the sibling never has to be told where
    #       the tree moved to.
    if [[ -n "${BGRPI_TOOLS_CONTAINER:-}" ]]; then
        echo "[build] inheriting mounts from tools container ${BGRPI_TOOLS_CONTAINER}"
        MOUNT_ARGS=(--volumes-from "$BGRPI_TOOLS_CONTAINER")
    else
        # A Windows (C:\...) or MSYS (/c/...) path means the daemon cannot see
        # this tree. Fail with a pointer instead of an empty mount.
        if [[ "$ROOT" != /* || "$ROOT" =~ ^/[a-zA-Z]/ ]]; then
            echo "error: the docker daemon cannot resolve '$ROOT'" >&2
            echo "       Run the build through tools/run.sh|ps1|cmd (which makes" >&2
            echo "       the sibling inherit the right mounts), or from WSL or a" >&2
            echo "       Linux host." >&2
            exit 2
        fi
        MOUNT_ARGS=(--volume "$ROOT:$ROOT")
    fi

    # update-custompios-paths must run INSIDE the sibling so the custompios_path
    # sidecar records the path as the sibling sees it.
    SIBLING_CMD="bash $(printf '%q' "$ROOT/CustomPiOS/src/update-custompios-paths")"
    SIBLING_CMD+=" $(printf '%q' "$ROOT/src")"
    SIBLING_CMD+=" && ./build_dist $(printf '%q' "$VARIANT")"

    docker run --rm --privileged \
        "${MOUNT_ARGS[@]}" \
        --workdir "$ROOT/src" \
        "$DOCKER_IMAGE" \
        bash -c "$SIBLING_CMD"
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

# When CI invokes us via `sudo -E` (needed for loop devices / kpartx /
# chroot), dist/ ends up owned by root. The next workflow steps
# (sha256sum, upload-artifact) run as the regular runner user and
# cannot write into dist/ - they fail with "Permission denied".
# Hand the output directory back to the invoking user so post-build
# steps work without another sudo. Also covers image-cache/ + workspace-*
# which contain many files the runner user might want to clean later.
if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    echo "[build] handing ownership back to ${SUDO_USER:-uid ${SUDO_UID}}"
    chown -R "${SUDO_UID}:${SUDO_GID}" dist "$ROOT/src/image-cache" "$ROOT/src/workspace-${VARIANT}" 2>/dev/null || true
fi
