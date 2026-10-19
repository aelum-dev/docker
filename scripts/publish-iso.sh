#!/usr/bin/env bash
# Upload the latest Aelum ISO to Cloudflare R2 and publish the release metadata.
#
# This is the upload half of the automated release pipeline. It:
#
#   1. Uploads the ISO + checksums + GPG signature + signing key to R2
#      (public-read), same as before.
#   2. Builds latest.json (machine-readable release metadata) and uploads it to
#      the bucket root, served publicly at /latest.json (public R2 bucket).
#   3. Generates the website's src/lib/release.ts so the download links update
#      automatically (see docker/scripts/build-release-metadata.sh).
#
# After this runs, trigger the website build (commit release.ts to the website
# repo's main branch, or run scripts/publish-website.sh) and GitHub Pages will
# redeploy with the new links.
#
# Setup (one time):
#   1. Create an R2 bucket named "aelum".
#   2. Create an R2 API token (Storage & databases > R2 > Overview > Manage
#      in API Tokens > Create Account API token > Object Read & Write >
#      Apply to specific buckets: aelum). Copy Access Key ID,
#      Secret Access Key, and your Account ID (top-right of dashboard).
#   3. Install rclone:  pacman -S rclone   (Arch)
#   4. Export credentials (the script builds a throwaway rclone config from
#      these, so nothing is written to your main rclone.conf):
#          export R2_ACCOUNT_ID=xxxx
#          export R2_ACCESS_KEY=yyy
#          export R2_SECRET_KEY=zzz
#      (No interactive `rclone config` named remote required.)
#      Config uses provider = Cloudflare + no_check_bucket = true, which is
#      required for bucket/Object-scoped API tokens (avoids CreateBucket 403).
#
# Usage:
#   scripts/publish-iso.sh v2026.08.27 output/aelum-2026.08.27-x86_64.iso
#
# If no tag/file is given, it auto-selects the newest *.iso in output/.
#
# Requires the signed assets to already exist next to the ISO (run
# scripts/release-iso.sh first). Optional env to describe the signing key and
# set the public CDN base for the asset URLs:
#          export AELUM_SIGNING_UID="Ivan Kornienko <ik.workmail39@gmail.com>"
#          export AELUM_SIGNING_FP="A675F61C22C26FCE187262E448CC48FDFD881E0D"
#          export AELUM_SIGNING_FP_TOP="A675 F61C 22C2 6FCE 1872"
#          export AELUM_SIGNING_FP_BOT="62E4 48CC 48FD FD88 1E0D"
#          export AELUM_SIGNING_EXPIRES="2029-08-27"
#          export R2_PUBLIC_BASE="https://cdn.aelum.dev"

set -euo pipefail

# Scripts live in scripts/; the project root (output/) is the parent dir.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local secrets (gitignored) if present, so `make release-upload` works
# standalone the same way it does through release.sh.
if [ -f "$ROOT_DIR/release.env" ]; then
    set -a; . "$ROOT_DIR/release.env"; set +a
fi

R2_BUCKET="${R2_BUCKET:-aelum}"
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
R2_ACCESS_KEY="${R2_ACCESS_KEY:-}"
R2_SECRET_KEY="${R2_SECRET_KEY:-}"
if [[ -z "${R2_ACCOUNT_ID}${R2_ACCESS_KEY}${R2_SECRET_KEY}" ]]; then
    echo "ERROR: required R2 credentials not set. Copy release.env.example to release.env (see RELEASE.md), or export R2_ACCOUNT_ID, R2_ACCESS_KEY, R2_SECRET_KEY." >&2
    exit 1
fi
R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"

TAG="${1:?usage: publish-iso.sh <tag> [iso-path]}"
ISO_PATH="${2:-$(ls -1t "$ROOT_DIR"/output/*.iso 2>/dev/null | head -1)}"

if [[ ! -f "$ISO_PATH" ]]; then
  echo "ERROR: no ISO found at $ISO_PATH" >&2
  exit 1
fi

# Build a throwaway rclone config from env vars so credentials never touch
# your main rclone.conf and no named remote needs to be pre-created.
TMP_CONFIG="$(mktemp)"
trap 'rm -f "$TMP_CONFIG"' EXIT
cat > "$TMP_CONFIG" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
# Your token is bucket/Object-scoped, so rclone must skip its
# CreateBucket existence check (that call is denied for such tokens).
no_check_bucket = true
acl = public-read
EOF

# Upload the ISO and every release asset into the tag folder. The destination
# ends with a slash so rclone uses the source basename as the exact object key
# (rclone treats a no-slash destination as a directory and appends the filename).
BASE="$(basename "$ISO_PATH")"
DIR="$(dirname "$ISO_PATH")"
TAG_DIR="r2:${R2_BUCKET}/${TAG}/"

for extra in "$ISO_PATH" "$DIR/$BASE.sha256" "$DIR/$BASE.sha512" "$DIR/$BASE.asc" "$DIR/aelum-release-key.asc"; do
  if [[ -f "$extra" ]]; then
    echo "Uploading $(basename "$extra") -> ${TAG_DIR}$(basename "$extra")"
    rclone copy "$extra" "$TAG_DIR" \
      --config="$TMP_CONFIG" \
      --progress
  fi
done

# ── Publish release metadata ──────────────────────────────────────────────────
# The signed assets (checksums, signature, signing key) must already sit next to
# the ISO. Build latest.json + the website's release.ts, then upload latest.json
# to the bucket root so it is served publicly at /latest.json.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$(mktemp -d)"
trap 'rm -f "$TMP_CONFIG"; rm -rf "$META_DIR"' EXIT

# Derive the signing-key fields from the .asc/.asc sidecar if not provided.
SIGNING_UID="${AELUM_SIGNING_UID:-}"
if [[ -z "$SIGNING_UID" && -f "$ISO_PATH.asc" ]]; then
  SIGNING_UID="$(grep -m1 'uid=' "$ISO_PATH.asc" | sed -E 's/.*uid="?([^"]+)"?.*/\1/')"
fi

bash "$SCRIPT_DIR/build-release-metadata.sh" \
  --iso "$ISO_PATH" \
  --tag "$TAG" \
  --bucket "$R2_BUCKET" \
  --public-base "${R2_PUBLIC_BASE:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}" \
  --signing-uid "$SIGNING_UID" \
  --signing-fp "${AELUM_SIGNING_FP:-}" \
  --signing-fp-top "${AELUM_SIGNING_FP_TOP:-}" \
  --signing-fp-bot "${AELUM_SIGNING_FP_BOT:-}" \
  --expires "${AELUM_SIGNING_EXPIRES:-}" \
  --out-dir "$META_DIR"

META_JSON="$META_DIR/latest.json"
META_TS="$META_DIR/release.ts"

echo
# latest.json goes at the bucket root (served publicly at /latest.json).
echo "Uploading latest.json -> r2:${R2_BUCKET}/ (root)"
rclone copy "$META_JSON" "r2:${R2_BUCKET}/" \
  --config="$TMP_CONFIG" \
  --progress

# Keep the generated website module where the release job can commit it.
cp "$META_TS" "$ROOT_DIR/release.ts"

echo
echo "==> Done."
echo "    R2 bucket:     $R2_BUCKET"
echo "    latest.json:   https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/latest.json"
echo "    release.ts:    $ROOT_DIR/release.ts (commit to the website repo to update links)"
echo "    Asset folder:  ${R2_PUBLIC_BASE%/}/${TAG}/"
