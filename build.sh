#!/usr/bin/env bash
set -euo pipefail

# Step 1: Download packages and deps from packages.x86_64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="${SCRIPT_DIR}/packages.x86_64"

# Read packages from file (skip empty lines and comments)
mapfile -t PACKAGES < <(grep -v '^\s*$' "$PACKAGES_FILE" | grep -v '^\s*#')

echo "Packages to download:"
printf '%s\n' "${PACKAGES[@]}"
echo ""

# Create blank dbpath so pacman resolves all deps fresh (no installed pkgs)
BLANK_DB=/tmp/blankdb-pacman
rm -rf "$BLANK_DB"
mkdir -p "$BLANK_DB/sync"

echo "Syncing and downloading packages with dependencies..."
pacman -Syw --noconfirm --dbpath "$BLANK_DB" --cachedir /var/cache/pacman/pkg "${PACKAGES[@]}"

# Cleanup
rm -rf "$BLANK_DB"

echo "Downloaded packages: $(ls /var/cache/pacman/pkg/*.pkg.tar.zst 2>/dev/null | wc -l)"
