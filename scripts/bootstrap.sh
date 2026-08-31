#!/usr/bin/env bash
# Clone/update CustomPiOS into ./CustomPiOS (gitignored).
#
# CUSTOMPIOS_REF pins the upstream revision. Prefer a full 40-char commit
# SHA: upstream's tags are lightweight and can be force-moved, a SHA cannot.
# Branch names and tags are accepted too, but they float by definition.
#
# Why this script is more than a `git clone`: `git clone --branch` rejects a
# bare SHA, and a `git fetch <tag>` on a shallow clone writes only FETCH_HEAD
# without creating a local ref - so the naive `fetch && checkout <ref>` pair
# silently keeps the OLD tree. That is exactly how CI sat frozen on CustomPiOS
# 1.5.0 for 20 months while claiming to track master. We therefore fetch the
# ref explicitly, check out FETCH_HEAD, and verify the resulting HEAD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUSTOMPIOS_DIR="$ROOT/CustomPiOS"
CUSTOMPIOS_URL="${CUSTOMPIOS_URL:-https://github.com/guysoft/CustomPiOS.git}"
# CustomPiOS 2.0.0. Moving this ref is a deliberate act: v2 requires the
# python3-git / python3-yaml host packages installed by the CI workflow.
CUSTOMPIOS_REF="${CUSTOMPIOS_REF:-d293309aac2f606c609645b441962c8f02b6e8c3}"

# A 40-char hex string is a commit SHA; anything else is a branch or tag name.
is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# Already at the requested revision? Nothing to do. This is the cache-hit
# path and must stay cheap - no network round-trip.
if [[ -d "$CUSTOMPIOS_DIR/.git" ]] \
   && is_sha "$CUSTOMPIOS_REF" \
   && [[ "$(git -C "$CUSTOMPIOS_DIR" rev-parse HEAD 2>/dev/null || true)" == "$CUSTOMPIOS_REF" ]]; then
    echo "[bootstrap] CustomPiOS already at $CUSTOMPIOS_REF"
    exit 0
fi

if [[ ! -d "$CUSTOMPIOS_DIR/.git" ]]; then
    echo "[bootstrap] initialising CustomPiOS from $CUSTOMPIOS_URL"
    rm -rf "$CUSTOMPIOS_DIR"
    git init -q "$CUSTOMPIOS_DIR"
    git -C "$CUSTOMPIOS_DIR" remote add origin "$CUSTOMPIOS_URL"
fi

echo "[bootstrap] fetching $CUSTOMPIOS_REF"
# GitHub serves arbitrary reachable SHAs (uploadpack.allowAnySHA1InWant), so a
# depth-1 fetch of an exact commit works. For a branch/tag name the same call
# resolves it server-side; either way the result lands in FETCH_HEAD.
git -C "$CUSTOMPIOS_DIR" fetch --depth 1 --quiet origin "$CUSTOMPIOS_REF"
git -C "$CUSTOMPIOS_DIR" checkout -q -f FETCH_HEAD

HEAD_SHA="$(git -C "$CUSTOMPIOS_DIR" rev-parse HEAD)"

# Fail loudly on drift. The previous version ended in `|| true`, which is how
# a broken update went unnoticed for 20 months.
if is_sha "$CUSTOMPIOS_REF" && [[ "$HEAD_SHA" != "$CUSTOMPIOS_REF" ]]; then
    echo "[bootstrap] ERROR: HEAD is $HEAD_SHA but $CUSTOMPIOS_REF was requested" >&2
    exit 1
fi

echo "[bootstrap] CustomPiOS HEAD: $HEAD_SHA"
