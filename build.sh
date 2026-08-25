#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="${SCRIPT_DIR}/packages.x86_64"

# Read packages from file (skip empty lines and comments)
mapfile -t PACKAGES < <(grep -v '^\s*$' "$PACKAGES_FILE" | grep -v '^\s*#')

echo "Packages to install:"
printf '%s\n' "${PACKAGES[@]}"
echo ""

# Sync pacman and download packages with all dependencies
echo "Syncing pacman database..."
pacman -Sy --noconfirm

echo "Downloading packages and dependencies..."
pacman -S --noconfirm --downloadonly "${PACKAGES[@]}"

echo ""
echo "Downloaded packages:"
ls /var/cache/pacman/pkg/ | grep -E "^(${PACKAGES[*]// /|})" || true
