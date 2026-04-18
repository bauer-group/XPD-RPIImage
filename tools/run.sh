#!/usr/bin/env bash
# =============================================================================
# BAUER GROUP XPD-RPIImage - tools container launcher (Linux/macOS/WSL)
# =============================================================================
set -euo pipefail

# Prevent Git Bash (MSYS/MINGW) on Windows from translating POSIX-looking
# arguments (/workspace, /var/run/docker.sock) into Windows paths.
# No-op on real Linux/macOS.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TOOLS_DIR")"
IMAGE_NAME="${BGRPIIMAGE_TOOLS_IMAGE:-bgrpiimage-tools}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

show_help() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  validate [variant]      Validate JSON (default: all variants)
  render <variant>        Render CustomPiOS module artifacts for a variant
  build <variant>         Full image build (runs privileged custompios sibling)
  shell                   Open an interactive bash inside the tools container
  clean                   Wipe generated + build workspace artifacts
  help                    Show this help

Options:
  --build, -b             Force rebuild of the tools image before running
  --env-file <path>       Pass a .env file (forwarded to generator and build.sh)

Examples:
  $0 validate
  $0 render canbus-plattform
  $0 build canbus-plattform --env-file ../.env
  $0 shell -b
EOF
    exit 0
}

die() { echo -e "${RED}[ERROR] $*${NC}" >&2; exit 1; }
info() { echo -e "${CYAN}[INFO] $*${NC}"; }

docker info >/dev/null 2>&1 || die "Docker is not running. Please start Docker first."

COMMAND=""; VARIANT=""; BUILD_IMAGE=false; ENV_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        validate|render|build|shell|clean|help) COMMAND="$1"; shift ;;
        --build|-b) BUILD_IMAGE=true; shift ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --help|-h) show_help ;;
        -*) die "unknown option: $1" ;;
        *)  if [[ -z "$VARIANT" ]]; then VARIANT="$1"; shift; else die "unexpected arg: $1"; fi ;;
    esac
done
[[ -z "$COMMAND" || "$COMMAND" == "help" ]] && show_help

if $BUILD_IMAGE || ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    info "building tools image '$IMAGE_NAME'..."
    cp "$PROJECT_DIR/scripts/requirements.txt" "$TOOLS_DIR/requirements.txt"
    docker build -t "$IMAGE_NAME" "$TOOLS_DIR"
fi

RUN_ARGS=(--rm -v "$PROJECT_DIR:/workspace" -w /workspace)
# Interactive only when stdin is a TTY.
if [[ -t 0 && -t 1 ]]; then RUN_ARGS+=(-it); fi
# build/shell need the host docker socket.
if [[ "$COMMAND" == "build" || "$COMMAND" == "shell" ]]; then
    RUN_ARGS+=(-v "/var/run/docker.sock:/var/run/docker.sock")
fi
# env-file propagation (generator reads the same flag).
PY_ENV_ARGS=()
if [[ -n "$ENV_FILE" ]]; then
    [[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
    RUN_ARGS+=(--env-file "$ENV_FILE")
    PY_ENV_ARGS=(--env-file ".env")
    cp "$ENV_FILE" "$PROJECT_DIR/.env"
fi

case "$COMMAND" in
    validate)
        if [[ -n "$VARIANT" ]]; then
            docker run "${RUN_ARGS[@]}" "$IMAGE_NAME" \
                python scripts/generate.py "config/variants/${VARIANT}.json" --dry-run >/dev/null
            info "ok: $VARIANT"
        else
            docker run "${RUN_ARGS[@]}" "$IMAGE_NAME" bash -c '
                set -e
                for f in config/variants/*.json; do
                    echo -e "\033[0;36m-- $f --\033[0m"
                    python scripts/generate.py "$f" --dry-run > /dev/null
                    echo -e "\033[0;32mok\033[0m"
                done'
        fi
        ;;
    render)
        [[ -n "$VARIANT" ]] || die "render needs a variant name"
        docker run "${RUN_ARGS[@]}" "$IMAGE_NAME" \
            python scripts/generate.py "config/variants/${VARIANT}.json" "${PY_ENV_ARGS[@]}"
        ;;
    build)
        [[ -n "$VARIANT" ]] || die "build needs a variant name"
        info "building image for variant '$VARIANT' (this invokes a privileged sibling container)"
        BUILD_ARGS=()
        [[ -n "$ENV_FILE" ]] && BUILD_ARGS+=(--env-file .env)
        docker run "${RUN_ARGS[@]}" "$IMAGE_NAME" \
            bash scripts/build.sh "${BUILD_ARGS[@]}" "$VARIANT"
        ;;
    shell)
        echo -e "${GREEN}-------------------------------------------${NC}"
        echo -e "${GREEN} bgRPIImage tools container${NC}"
        echo -e "${GREEN}-------------------------------------------${NC}"
        echo "  make validate             validate all variants"
        echo "  make render VARIANT=can.. render generated files"
        echo "  make build VARIANT=..     full image build"
        echo "  exit                      leave container"
        echo -e "${GREEN}-------------------------------------------${NC}"
        docker run "${RUN_ARGS[@]}" "$IMAGE_NAME"
        ;;
    clean)
        docker run "${RUN_ARGS[@]}" "$IMAGE_NAME" make clean
        ;;
esac
