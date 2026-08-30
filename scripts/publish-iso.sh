#!/usr/bin/env bash
# Upload the latest Aelum ISO to Cloudflare R2 and print the public link.
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

set -euo pipefail

# Scripts live in scripts/; the project root (output/) is the parent dir.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

R2_BUCKET="${R2_BUCKET:-aelum}"
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID (top-right of Cloudflare dashboard)}"
R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"
R2_ACCESS_KEY="${R2_ACCESS_KEY:?set R2_ACCESS_KEY (Access Key ID from API token)}"
R2_SECRET_KEY="${R2_SECRET_KEY:?set R2_SECRET_KEY (Secret Access Key from API token)}"

TAG="${1:?usage: publish-iso.sh <tag> [iso-path]}"
ISO_PATH="${2:-$(ls -1t "$ROOT_DIR"/output/*.iso 2>/dev/null | head -1)}"

if [[ ! -f "$ISO_PATH" ]]; then
  echo "ERROR: no ISO found at $ISO_PATH" >&2
  exit 1
fi

ISO_NAME="$(basename "$ISO_PATH")"

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

echo "Uploading $ISO_PATH ($ISO_NAME) -> r2:$R2_BUCKET/$ISO_NAME"
rclone copy "$ISO_PATH" "r2:${R2_BUCKET}/${ISO_NAME}" \
  --config="$TMP_CONFIG" \
  --progress
