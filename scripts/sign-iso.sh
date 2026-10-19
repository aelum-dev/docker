#!/usr/bin/env bash
#
# sign-iso.sh — sign + checksum the ISO for release. Part of the local
# release pipeline: release.sh → sign-iso.sh → publish-iso.sh →
# publish-website.sh (the website link update is automated, not by hand).
#
# It:
#
#   1. Picks the ISO to release (default: newest in ../output, or $1).
#   2. Generates SHA-256 and SHA-512 checksum files.
#   3. Produces a detached ASCII-armored GPG signature for the ISO (headless if
#      AELUM_GPG_PRIVATE_KEY_B64 + GPG_PASSPHRASE are set).
#   4. Exports the public signing key locally (users fetch it via WKD).
#   5. Verifies the checksums and signature before returning, so a bad release
#      fails fast.
#
# The signed assets (ISO, *.sha256, *.sha512, *.asc) are uploaded alongside the
# ISO to Cloudflare R2 by publish-iso.sh. The public key is distributed via WKD
# instead of a hosted file. Users verify with the commands printed at the end.
#
# Usage:
#   ./sign-iso.sh                    # release newest ISO in ../output
#   ./sign-iso.sh path/to.iso        # release a specific ISO
#   AELUM_GPG_KEY=0xABCD... ./sign-iso.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

# Load local secrets (gitignored) if present, so `make release-sign` works
# standalone the same way it does through release.sh.
if [ -f "$ROOT_DIR/release.env" ]; then
    set -a; . "$ROOT_DIR/release.env"; set +a
fi

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
    echo "  Copy release.env.example to release.env (see RELEASE.md), or export it." >&2
    echo "  List keys:  gpg --list-secret-keys --keyid-format=long" >&2
    exit 1
fi

# ── Import the signing key from the environment (optional, for CI) ───────────
# If the private key is provided via the environment, import it so this script
# runs in a clean environment with no pre-loaded keyring. Accepts an armored
# key directly (AELUM_GPG_PRIVATE_KEY) or base64-encoded (AELUM_GPG_PRIVATE_KEY_B64).
# Local use can skip this and rely on the key already in your keyring.
if [[ -n "${AELUM_GPG_PRIVATE_KEY:-}" || -n "${AELUM_GPG_PRIVATE_KEY_B64:-}" ]]; then
    KEY_ARMOR="${AELUM_GPG_PRIVATE_KEY:-}"
    if [[ -n "${AELUM_GPG_PRIVATE_KEY_B64:-}" ]]; then
        KEY_ARMOR="$(printf '%s' "$AELUM_GPG_PRIVATE_KEY_B64" | base64 -d)"
    fi
    echo "==> Importing signing key..."
    printf '%s' "$KEY_ARMOR" | gpg --import --batch 2>&1 | tail -2
    # Mark the key ultimately trusted so verification shows no 'untrusted' warning.
    printf 'trust\n5\ny\n' | gpg --command-fd 0 --batch --yes --edit-key "$AELUM_GPG_KEY" >/dev/null 2>&1 || true
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

# ── Headless signing setup ───────────────────────────────────────────────────
# In a clean environment (CI, no pre-loaded keyring) gpg-agent otherwise falls
# back to a tty-requiring pinentry. Allow loopback pinentry and restart the
# agent so the passphrase passed below is used non-interactively.
mkdir -p "${GNUPGHOME:-$HOME/.gnupg}"
AGENT_CONF="${GNUPGHOME:-$HOME/.gnupg}/gpg-agent.conf"
if ! grep -q 'allow-loopback-pinentry' "$AGENT_CONF" 2>/dev/null; then
    echo 'allow-loopback-pinentry' >> "$AGENT_CONF"
fi
gpgconf --kill gpg-agent 2>/dev/null || true

# ── GPG detached signature ────────────────────────────────────────────────────
# If GPG_PASSPHRASE is set, use loopback pinentry so this runs headlessly
# (CI, scripts). Otherwise fall back to the normal interactive prompt.
GPG_EXTRA=()
if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
    GPG_EXTRA=(--pinentry-mode loopback --passphrase "${GPG_PASSPHRASE}")
fi
SIG="$DIR/$BASE.asc"
gpg --local-user "$AELUM_GPG_KEY" \
    --armor --detach-sign --digest-algo=SHA512 \
    "${GPG_EXTRA[@]}" \
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

# ── Export the public key (local only, not published) ─────────────────────────
# Users fetch the key over WKD (https://aelum.dev/.well-known/openpgpkey/), so it
# is no longer uploaded as a sidecar. This export is just a local convenience for
# manual verification.
PUB_KEY="$DIR/aelum-release-key.asc"
gpg --export --armor "$AELUM_GPG_KEY" > "$PUB_KEY"
echo "==> Public key written locally (not published): $PUB_KEY"
echo

cat <<EOF

Release assets to upload to Cloudflare R2 (same folder as the ISO):

    $BASE
    $BASE.sha256
    $BASE.sha512
    $BASE.asc

EOF
