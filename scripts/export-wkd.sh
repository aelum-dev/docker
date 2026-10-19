#!/usr/bin/env bash
#
# export-wkd.sh — publish the Aelum release key via Web Key Directory (WKD).
#
# WKD (draft-koch-openpgp-webkey-service, the protocol GnuPG actually
# implements) serves the key over **HTTPS** at a well-known path:
#
#   https://<domain>/.well-known/openpgpkey/hu/<zbase32(sha1(local-part))>
#
# with a companion `policy` file next to it. That is the "direct method";
# it needs no DNS changes at all. GnuPG's `--auto-key-locate wkd` tries the
# "advanced method" first (openpgpkey.<domain>, which does not exist for
# aelum.dev, so it falls through) and then the direct method above.
#
# NOTE: an earlier version of this script emitted a DNS TXT record
# (_openpgp.keybase.txt.<domain>, v=pgdk1:...) from an abandoned Keybase
# draft. GnuPG never implemented that scheme, so `gpg --locate-keys` could
# not resolve the key. Do not go back to it.
#
# The generated tree is written into the website's `public/` directory, so
# GitHub Pages serves it from https://aelum.dev/.well-known/openpgpkey/.
#
# Usage:
#   AELUM_GPG_KEY="Aelum Release <release@aelum.dev>" \
#       bash docker/scripts/export-wkd.sh
#
# Optional env:
#   AELUM_GPG_PRIVATE_KEY / AELUM_GPG_PRIVATE_KEY_B64 — import a key from the
#                       environment first (clean/CI machine, same as
#                       sign-iso.sh).
#   WKD_OUT_DIR         — where to write the tree; defaults to
#                       <repo>/website/public/.well-known/openpgpkey.
#
# Verify after deploying:
#   curl -sI 'https://aelum.dev/.well-known/openpgpkey/hu/<hash>?l=release'
#   gpg --auto-key-locate wkd --locate-keys release@aelum.dev
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$ROOT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

# Load local secrets (gitignored) if present, so the key id is picked up the
# same way the other release scripts read release.env.
if [ -f "$ROOT_DIR/release.env" ]; then
    set -a; . "$ROOT_DIR/release.env"; set +a
fi

# ── Config ────────────────────────────────────────────────────────────────────
AELUM_GPG_KEY="${AELUM_GPG_KEY:-}"
DEFAULT_OUT_DIR="$PROJECT_DIR/website/public/.well-known/openpgpkey"
WKD_OUT_DIR="${WKD_OUT_DIR:-$DEFAULT_OUT_DIR}"

# ── Sanity ────────────────────────────────────────────────────────────────────
command -v gpg >/dev/null 2>&1 || { echo "Error: gpg not found." >&2; exit 1; }
command -v gpg-wks-client >/dev/null 2>&1 || {
    echo "Error: gpg-wks-client not found (install gnupg)." >&2; exit 1; }
if [[ -z "$AELUM_GPG_KEY" ]]; then
    echo "Error: set AELUM_GPG_KEY (a key id or 'Name <email>')." >&2
    echo "  Copy release.env.example to release.env (see RELEASE.md), or export it." >&2
    echo "  List keys:  gpg --list-keys --keyid-format=long" >&2
    exit 1
fi

# ── Import the signing key from the environment (optional, for CI) ───────────
if [[ -n "${AELUM_GPG_PRIVATE_KEY:-}" || -n "${AELUM_GPG_PRIVATE_KEY_B64:-}" ]]; then
    KEY_ARMOR="${AELUM_GPG_PRIVATE_KEY:-}"
    if [[ -n "${AELUM_GPG_PRIVATE_KEY_B64:-}" ]]; then
        KEY_ARMOR="$(printf '%s' "$AELUM_GPG_PRIVATE_KEY_B64" | base64 -d)"
    fi
    echo "==> Importing signing key..."
    printf '%s' "$KEY_ARMOR" | gpg --import --batch 2>&1 | tail -2
fi

# ── Locate the website repo ──────────────────────────────────────────────────
# WKD must be served from the email domain (https://aelum.dev/...), which is the
# website's GitHub Pages site — not the R2 CDN.
if [[ "$WKD_OUT_DIR" == "$DEFAULT_OUT_DIR" && ! -d "$PROJECT_DIR/website/public" ]]; then
    echo "Error: website repo not found at $PROJECT_DIR/website." >&2
    echo "  Set WKD_OUT_DIR to the target .well-known/openpgpkey directory." >&2
    exit 1
fi

# ── Resolve fingerprint + email ──────────────────────────────────────────────
# `--with-colons` is the stable, parseable format (the armored export has no
# "uid=" lines, which is why the old version's domain detection silently
# always fell back to the hard-coded default).
FPR="$(gpg --with-colons --list-keys "$AELUM_GPG_KEY" 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}')"
if [[ -z "$FPR" ]]; then
    echo "Error: no key found for '$AELUM_GPG_KEY'. Is it in your keyring?" >&2
    exit 1
fi

# Prefer an address given explicitly as "Name <email>"; otherwise take the
# first UID from the keyring (percent-decoding the colons format).
EMAIL=""
if [[ "$AELUM_GPG_KEY" =~ \<([^>]+@[^>]+)\> ]]; then
    EMAIL="${BASH_REMATCH[1]}"
else
    EMAIL="$(gpg --with-colons --list-keys "$FPR" 2>/dev/null \
        | awk -F: '/^uid:/ {print $10; exit}' \
        | sed -e 's/\\x3a/:/g' -e 's/\\x3c/</g' -e 's/\\x3e/>/g')"
    EMAIL="$(printf '%s' "$EMAIL" | sed -nE 's/.*<([^>]+@[^>]+)>.*/\1/p')"
fi
if [[ -z "$EMAIL" ]]; then
    echo "Error: could not determine an email address for '$AELUM_GPG_KEY'." >&2
    exit 1
fi

DOMAIN="${EMAIL##*@}"
echo "==> Key:   $FPR"
echo "==> Email: $EMAIL"
echo "==> Domain: $DOMAIN"

# ── Generate the WKD tree ────────────────────────────────────────────────────
# gpg-wks-client writes the *advanced* layout (<dir>/<domain>/hu/<hash> plus
# <dir>/<domain>/policy). The direct method serves those two paths from the
# domain root, so the per-domain directory is flattened away below.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Generating WKD tree..."
gpg-wks-client --install-key --directory="$TMP_DIR" "$FPR" "$EMAIL"

if [[ ! -d "$TMP_DIR/$DOMAIN" ]]; then
    echo "Error: gpg-wks-client did not produce a tree for $DOMAIN." >&2
    exit 1
fi

HASH="$(gpg-wks-client --print-wkd-hash "$EMAIL" | awk '{print $1}')"
if [[ ! -f "$TMP_DIR/$DOMAIN/hu/$HASH" ]]; then
    echo "Error: expected key file hu/$HASH was not generated." >&2
    exit 1
fi

# ── Install into the website's public/ tree (direct method layout) ───────────
mkdir -p "$WKD_OUT_DIR/hu"
install -m 644 "$TMP_DIR/$DOMAIN/hu/$HASH" "$WKD_OUT_DIR/hu/$HASH"
# RFC requires a policy file to be served, even if empty.
if [[ -f "$TMP_DIR/$DOMAIN/policy" ]]; then
    install -m 644 "$TMP_DIR/$DOMAIN/policy" "$WKD_OUT_DIR/policy"
else
    printf '# Policy flags for domain %s\n' "$DOMAIN" > "$WKD_OUT_DIR/policy"
    chmod 644 "$WKD_OUT_DIR/policy"
fi

echo "==> Wrote:"
echo "    $WKD_OUT_DIR/hu/$HASH"
echo "    $WKD_OUT_DIR/policy"

# ── Sanity-check the published bytes ────────────────────────────────────────
# The file must be the binary key, byte-for-byte what `gpg --export` emits.
if gpg --export "$FPR" | cmp -s - "$WKD_OUT_DIR/hu/$HASH"; then
    echo "==> Key bytes match 'gpg --export' (binary, as WKD requires)."
else
    echo "Warning: published key differs from 'gpg --export'." >&2
fi

cat <<EOF

============================================================
 Next steps
============================================================
 The tree is written into the website repo, so commit it:

     cd website && git add public/.well-known && git commit -m "wkd: publish release key"

 GitHub Pages serves it at:

     https://${DOMAIN}/.well-known/openpgpkey/hu/${HASH}?l=${EMAIL%@*}
     https://${DOMAIN}/.well-known/openpgpkey/policy

 After the deploy, verify (must succeed with no local copy of the key):

     curl -sI 'https://${DOMAIN}/.well-known/openpgpkey/hu/${HASH}?l=${EMAIL%@*}'
     gpg --auto-key-locate wkd --locate-keys ${EMAIL}

 There is no DNS record to add for the direct method. If you previously
 published the obsolete _openpgp.keybase.txt TXT record, delete it — GnuPG
 never supported it.
============================================================
EOF
