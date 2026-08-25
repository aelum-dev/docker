#!/usr/bin/env bash
set -euo pipefail

# Step 0: Install foundational packages (git, base, base-devel)

FOUNDRY_PACKAGES=(git base base-devel)

echo "Installing foundational packages..."
pacman -Sy --noconfirm "${FOUNDRY_PACKAGES[@]}"
echo "Foundational packages installed."

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

echo "Downloaded packages: $(ls /var/cache/pacman/pkg/*.pkg.tar.zst 2>/dev/null | wc -l)"

# Step 2: Download AUR packages from packages.aur.x86_64

AUR_PACKAGES_FILE="${SCRIPT_DIR}/packages.aur.x86_64"

mapfile -t AUR_PACKAGES < <(grep -v '^\s*$' "$AUR_PACKAGES_FILE" | grep -v '^\s*#')

echo "AUR packages to download:"
printf '%s\n' "${AUR_PACKAGES[@]}"
echo ""

if [ ${#AUR_PACKAGES[@]} -gt 0 ]; then
    # Create non-root user for makepkg
    useradd -m -s /bin/bash makepkg
    echo 'makepkg ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/makepkg

    mkdir -p /home/makepkg/aurbuild
    chown -R makepkg:makepkg /home/makepkg/aurbuild
    cd /home/makepkg/aurbuild
    for pkg in "${AUR_PACKAGES[@]}"; do
        echo "Downloading $pkg..."
        git clone "https://aur.archlinux.org/$pkg.git"
        chown -R makepkg:makepkg "$pkg"
        cd "$pkg"
        sudo -u makepkg env BUILDDIR=/home/makepkg/aurbuild makepkg -si --noconfirm --skipinteg || true
        cd ..
    done
    echo "AUR packages built and installed."
else
    echo "No AUR packages to download."
fi

# Step 3: Create local repository database from cached packages

echo "Creating local repository database..."
REPO_DIR="${SCRIPT_DIR}/repo"
mkdir -p "$REPO_DIR"

# Copy all .pkg.tar.zst files to repo directory
cp /var/cache/pacman/pkg/*.pkg.tar.zst "$REPO_DIR/"

# Create the database using repo-add
REPO_DB="$REPO_DIR/aestheticos.db"
repo-add "$REPO_DB" "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null || true

echo "Local repository created at $REPO_DIR"
echo "Repository contains: $(ls "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | wc -l) packages"
echo "Database: $REPO_DB"
