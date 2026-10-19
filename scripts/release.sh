#!/usr/bin/env bash
#
# release.sh — one-shot entry point for the local release pipeline.
#
#   1. Loads local secrets from ../release.env (gitignored) if present.
#   2. Verifies required credentials and that an ISO exists.
#   3. Signs + checksums the ISO, uploads it to Cloudflare R2, and pushes the
#      updated website download links.
#
# Everything runs in this single shell, so the sourced env vars are visible to
# the checks and to the scripts below. This is what `make release` calls, but it
# also works standalone from any machine:
#
#   cp release.env.example release.env   # fill in your keys (gitignored)
#   ./scripts/release.sh                 # tag defaults to today (vYYYY.MM.DD)
#   ./scripts/release.sh v2026.10.04     # pin the tag
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. Load local secrets (gitignored) if present.
if [ -f "$ROOT_DIR/release.env" ]; then
    set -a; . "$ROOT_DIR/release.env"; set +a
fi

# Tag: explicit arg, else VERSION env, else today (vYYYY.MM.DD).
TAG="${1:-${VERSION:-v$(date +%Y.%m.%d)}}"

# 2a. Required credentials.
if [ -z "${R2_ACCOUNT_ID:-}${R2_ACCESS_KEY:-}${R2_SECRET_KEY:-}${AELUM_GPG_KEY:-}" ]; then
    echo "ERROR: required credentials not set. Copy release.env.example to release.env (see RELEASE.md), or export R2_* and AELUM_GPG_KEY." >&2
    exit 1
fi

# 2b. ISO must exist.
ISO="${ISO:-}"
if [ -z "$ISO" ]; then
    if ! ls "$ROOT_DIR"/output/*.iso >/dev/null 2>&1; then
        echo "ERROR: no ISO found in output/. Run 'make build' first." >&2
        exit 1
    fi
    ISO="$(ls -1t "$ROOT_DIR"/output/*.iso | head -1)"
fi

# 3. Run the pipeline.
echo "==> Release $TAG: $ISO"
"$SCRIPT_DIR/sign-iso.sh" "$ISO"
"$SCRIPT_DIR/publish-iso.sh" "$TAG" "$ISO"
"$SCRIPT_DIR/publish-website.sh"
echo "==> Done. $TAG published to R2 and website links updated."
