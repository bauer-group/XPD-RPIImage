#!/usr/bin/env bash
# Push local key material into this repository's GitHub Actions secrets.
#
# Release signing runs in CI, so the private key has to live in GitHub
# Actions secrets. This is the only supported way to put it there: doing it
# through the web UI means pasting a private key into a browser, and doing it
# with `gh secret set --body` puts it in the process arguments where every
# other process on the machine can read it. Everything here goes over stdin.
#
# MAINTENANCE
#
# The SECRETS table below is the only thing you edit. One line per secret:
#
#     "SECRET_NAME|path/to/file|kind"
#
# kind is `private` or `public`, and it is checked rather than trusted - the
# easiest mistake in this whole area is uploading the .pub by accident and
# believing signing is configured.
#
#   bash scripts/push-secrets.sh --dry-run    # what would be pushed
#   bash scripts/push-secrets.sh              # do it
#   bash scripts/push-secrets.sh --list       # what is configured now
set -euo pipefail

# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------
# BGRPIIMAGE_SIGNING_KEY is what the release workflow signs bundle manifests
# with. Devices verify against the matching public key shipped in the image.
#
# If you later add a second keypair whose private half is kept OFFLINE - the
# one that lets you re-establish trust if this one is ever compromised - it
# does not belong here: only its public half goes into the image tree. A key
# held in CI cannot double as the recovery for a compromise of CI.
SECRETS=(
    "BGRPIIMAGE_SIGNING_KEY|.secrets/bgrpiimage-recovery.key|private"
)

# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CY=$'\033[1;36m'; GR=$'\033[1;32m'; YE=$'\033[1;33m'; RD=$'\033[1;31m'; NC=$'\033[0m'
[[ -t 1 ]] || { CY=''; GR=''; YE=''; RD=''; NC=''; }
info() { echo "${CY}[*]${NC} $*"; }
ok()   { echo "${GR}[+]${NC} $*"; }
warn() { echo "${YE}[!]${NC} $*" >&2; }
die()  { echo "${RD}[x]${NC} $*" >&2; exit 1; }

DRY=0; LIST=0; REPO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) DRY=1 ;;
        --list|-l)    LIST=1 ;;
        --repo)       shift; REPO="${1:-}"; [[ -n "$REPO" ]] || die "--repo needs OWNER/NAME" ;;
        -h|--help)    sed -n '2,26p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)            die "unknown argument '$1'" ;;
    esac
    shift
done

command -v gh >/dev/null || die "the GitHub CLI (gh) is required: https://cli.github.com"
gh auth status >/dev/null 2>&1 || die "not logged in - run: gh auth login"
command -v openssl >/dev/null || die "openssl is required to validate the key"

if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
        || die "could not determine the repository - pass --repo OWNER/NAME"
fi

if [[ "$LIST" -eq 1 ]]; then
    info "secrets currently set on ${REPO}"
    gh secret list --repo "$REPO"
    exit 0
fi

# A public-key fingerprint identifies WHICH key is in CI without ever
# revealing the key. Print it here and compare it later against the .pub that
# ships in the image, and you can answer "is the right key signing our
# releases" without touching the private half again.
fingerprint() { # <private-or-public-pem>
    # Piped, never captured in a variable: DER is binary and command
    # substitution silently drops null bytes, which would hash a truncated
    # key and print a fingerprint that looks fine and identifies nothing.
    local f="$1"
    if openssl pkey -in "$f" -noout >/dev/null 2>&1; then
        openssl pkey -in "$f" -pubout -outform DER 2>/dev/null
    else
        openssl pkey -pubin -in "$f" -outform DER 2>/dev/null
    fi | openssl dgst -sha256 -binary | openssl base64 | cut -c1-32
}

is_private() { openssl pkey -in "$1" -noout >/dev/null 2>&1; }
is_public()  { openssl pkey -pubin -in "$1" -noout >/dev/null 2>&1; }

pushed=0
for entry in "${SECRETS[@]}"; do
    IFS='|' read -r name file kind <<< "$entry"

    [[ -f "$file" ]] || die "$name: no such file: $file
    Generate it with:
      openssl genpkey -algorithm ed25519 -out $file
      openssl pkey -in $file -pubout -out ${file%.key}.pub"

    # Validate what it actually is, rather than trusting the table. Uploading
    # the public half and believing signing is configured is the failure this
    # catches, and it would only surface when a device rejects every release.
    case "$kind" in
        private)
            # The header check is the load-bearing one: `openssl pkey -in`
            # accepts a public PEM in some builds, so parseability alone does
            # not tell the halves apart - and uploading the .pub while
            # believing signing is configured would only surface when every
            # device rejects every release.
            if grep -q 'BEGIN PUBLIC KEY' "$file"; then
                die "$name: $file contains a PUBLIC key - refusing to push it as a signing secret"
            fi
            is_private "$file" || die "$name: $file is not a readable private key"
            ;;
        public)
            is_public "$file" || die "$name: $file is not a readable public key"
            warn "$name: pushing a PUBLIC key as a secret is unusual - it belongs in the image tree"
            ;;
        *) die "$name: unknown kind '$kind' (use private or public)" ;;
    esac

    fp=$(fingerprint "$file")
    crlf=""
    grep -qU $'\r' "$file" 2>/dev/null && crlf=" ${YE}(CRLF will be normalised)${NC}"

    if [[ "$DRY" -eq 1 ]]; then
        info "would set ${CY}${name}${NC} on ${REPO} from ${file}${crlf}"
        echo "      key fingerprint: ${fp}"
        continue
    fi

    # stdin, never --body: an argument is visible in /proc and in shell
    # history. tr strips the CR bytes a Windows-generated PEM carries, which
    # the Linux runner would otherwise feed to openssl verbatim.
    tr -d '\r' < "$file" | gh secret set "$name" --repo "$REPO" \
        || die "$name: gh secret set failed"
    ok "set ${CY}${name}${NC} on ${REPO}"
    echo "      key fingerprint: ${fp}"
    pushed=$((pushed + 1))
done

if [[ "$DRY" -eq 1 ]]; then
    info "dry run - nothing was sent"
    exit 0
fi

echo
info "secrets on ${REPO}"
gh secret list --repo "$REPO"
echo
ok "${pushed} secret(s) updated"
echo "    The fingerprints above identify which key CI now signs with."
echo "    The matching public key belongs in the image, not in a secret."
