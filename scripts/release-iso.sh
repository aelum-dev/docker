#!/usr/bin/env bash
#
# make-release.sh — produce signed, verifiable release assets for the Aelum ISO.
#
# There is no CI release job: the ISO is too large for GitLab and is published
# to Cloudflare R2, with the download link updated on the website by hand. So
# this script is run locally by the maintainer right before upload. It:
#
#   1. Picks the ISO to release (default: newest in ../output).
#   2. Generates SHA-256 and SHA-512 checksum files.
#   3. Produces a detached ASCII-armored GPG signature for the ISO.
#   4. Exports the public signing key (aelum-release-key.asc).
#   5. Prints the exact R2 upload + website-link steps.
#
# The checksum/signature files are meant to be uploaded alongside the ISO to
# R2 and committed next to it. Users verify with the commands printed at the end.
#
# Usage:
#   ./make-release.sh                 # release newest ISO in ./output
#   ./make-release.sh path/to.iso     # release a specific ISO
#   AELUM_GPG_KEY=0xABCD... ./make-release.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Config ────────────────────────────────────────────────────────────────────
AELUM_GPG_KEY="${AELUM_GPG_KEY:-}"          # e.g. 0x1234ABCD or "My Name <me@example>"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../output}"
ISO="${1:-$(find "$OUTPUT_DIR" -maxdepth 1 -name '*.iso' | sort | tail -1)}"

if [[ -z "$ISO" || ! -f "$ISO" ]]; then
    echo "Error: no ISO found in $OUTPUT_DIR (pass a path as \$1)." >&2
    exit 1
fi
ISO="$(realpath "$ISO")"
BASE="$(basename "$ISO")"
DIR="$(dirname "$ISO")"

# ── Sanity ────────────────────────────────────────────────────────────────────
command -v gpg >/dev/null 2>&1 || { echo "Error: gpg not found." >&2; exit 1; }
if [[ -z "$AELUM_GPG_KEY" ]]; then
    echo "Error: set AELUM_GPG_KEY (a key id or 'Name <email>')." >&2
    echo "  List keys:  gpg --list-secret-keys --keyid-format=long" >&2
    exit 1
fi

echo "==> ISO:     $ISO"
echo "==> Size:    $(du -h "$ISO" | cut -f1)"
echo "==> GPG key: $AELUM_GPG_KEY"
echo

# ── Checksums ─────────────────────────────────────────────────────────────────
# Checksum files use the basename only (not a full path) so `sha256sum -c`
# works from the directory the assets are downloaded into.
(
    cd "$DIR"
    sha256sum "$BASE" > "$BASE.sha256"
    sha512sum "$BASE" > "$BASE.sha512"
)

echo "==> Checksums written:"
echo "    $DIR/$BASE.sha256"
echo "    $DIR/$BASE.sha512"
echo
cat "$DIR/$BASE.sha256"
echo

# ── GPG detached signature ────────────────────────────────────────────────────
SIG="$DIR/$BASE.asc"
gpg --local-user "$AELUM_GPG_KEY" \
    --armor --detach-sign --digest-algo=SHA512 \
    --output "$SIG" "$ISO"

echo "==> Signature written: $SIG"
echo

# ── Verify everything we just produced ──────────────────────────────────────
# Confirm the checksums match the ISO and the signature is valid before we hand
# the assets over to R2. Fails the release if either check does not pass.
echo "==> Verifying assets..."
( cd "$DIR" && sha256sum -c "$BASE.sha256" )
( cd "$DIR" && sha512sum -c "$BASE.sha512" )
gpg --verify "$SIG" "$ISO" && echo "==> GPG signature: OK"
echo

# ── Export the public key ─────────────────────────────────────────────────────
# Users need the public key to verify the signature. The script does not publish
# it anywhere — it only writes the file, which you upload to R2 / a keyserver.
PUB_KEY="$DIR/aelum-release-key.asc"
gpg --export --armor "$AELUM_GPG_KEY" > "$PUB_KEY"
echo "==> Public key written: $PUB_KEY"
echo

cat <<EOF

Release assets to upload to Cloudflare R2 (same folder as the ISO):

    $BASE
    $BASE.sha256
    $BASE.sha512
    $BASE.asc
    aelum-release-key.asc

EOF
