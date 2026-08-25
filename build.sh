#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install essential build packages (git, base-devel)

echo "Installing essential build packages..."
pacman -Sy --noconfirm git base-devel

# Clone live-iso profile

LIVE_ISO_DIR="${SCRIPT_DIR}/live-iso"
if [ ! -d "$LIVE_ISO_DIR/.git" ]; then
    echo "Cloning live-iso profile..."
    git clone https://gitlab.com/aestheticos/live-iso.git "$LIVE_ISO_DIR"
fi

PACKAGES_FILE="${LIVE_ISO_DIR}/packages.x86_64"
AUR_PACKAGES_FILE="${LIVE_ISO_DIR}/packages.aur.x86_64"

# Read packages (skip empty lines and comments)
mapfile -t PACKAGES < <(grep -v '^\s*$' "$PACKAGES_FILE" | grep -v '^\s*#')
mapfile -t AUR_PACKAGES < <(grep -v '^\s*$' "$AUR_PACKAGES_FILE" | grep -v '^\s*#')

echo "Official packages: ${#PACKAGES[@]}"
echo "AUR packages: ${#AUR_PACKAGES[@]}"

# Download official packages with dependencies

BLANK_DB=/tmp/blankdb-pacman
mkdir -p "$BLANK_DB/sync"

echo "Downloading official packages..."
pacman -Syw --noconfirm --dbpath "$BLANK_DB" --cachedir /var/cache/pacman/pkg "${PACKAGES[@]}"
echo "Downloaded: $(ls /var/cache/pacman/pkg/*.pkg.tar.zst 2>/dev/null | wc -l)"

# Build and install AUR packages

if [ ${#AUR_PACKAGES[@]} -gt 0 ]; then
    useradd -m -s /bin/bash makepkg 2>/dev/null || true
    echo 'makepkg ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/makepkg

    mkdir -p /home/makepkg/aurbuild
    chown -R makepkg:makepkg /home/makepkg/aurbuild
    cd /home/makepkg/aurbuild

    for pkg in "${AUR_PACKAGES[@]}"; do
        echo "Building $pkg..."
        git clone "https://aur.archlinux.org/$pkg.git"
        chown -R makepkg:makepkg "$pkg"
        cd "$pkg"
        sudo -u makepkg env BUILDDIR=/home/makepkg/aurbuild makepkg -si --noconfirm --skipinteg || true
    done
    echo "AUR packages are built and installed."
fi

# Copy all packages to live-iso offline mirror

MIRROR_DIR="${LIVE_ISO_DIR}/airootfs/var/cache/aestheticos/offline-mirror"
mkdir -p "$MIRROR_DIR"

cp /var/cache/pacman/pkg/*.pkg.tar.zst "$MIRROR_DIR/"

REPO_DB="$MIRROR_DIR/aestheticos-offline.db"
repo-add "$REPO_DB" "$MIRROR_DIR"/*.pkg.tar.zst 2>/dev/null || true

echo ""
echo "Mirror: $MIRROR_DIR"
echo "Packages: $(ls "$MIRROR_DIR"/*.pkg.tar.zst 2>/dev/null | wc -l)"
echo "Database: $REPO_DB"
