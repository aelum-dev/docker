#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install essential build packages (git, base-devel, archiso...)

echo "Installing essential build packages..."
pacman -Sy --noconfirm git base-devel archiso go nodejs-lts-jod npm gtk3 webkit2gtk-4.1 libsoup3 grub memtest86+

# Clone live-iso profile

LIVE_ISO_DIR="/app/live-iso"
TMP_ISO="/tmp/live-iso-clone"
rm -rf "$TMP_ISO"
mkdir -p "$LIVE_ISO_DIR"
echo "Cloning live-iso profile..."
git clone --depth 1 https://gitlab.com/aestheticos/live-iso.git "$TMP_ISO"
cp -a "$TMP_ISO"/* "$TMP_ISO"/.[!.]* "$TMP_ISO"/..?* "$LIVE_ISO_DIR/" 2>/dev/null || true
rm -rf "$TMP_ISO"

# Clone and build installer

INSTALLER_DIR="/app/installer"
TMP_INSTALLER="/tmp/installer-clone"
rm -rf "$TMP_INSTALLER"
mkdir -p "$INSTALLER_DIR"
echo "Cloning installer..."
git clone --depth 1 https://gitlab.com/aestheticos/installer.git "$TMP_INSTALLER"
cp -a "$TMP_INSTALLER"/* "$TMP_INSTALLER"/.[!.]* "$TMP_INSTALLER"/..?* "$INSTALLER_DIR/" 2>/dev/null || true
rm -rf "$TMP_INSTALLER"

export PATH="$HOME/go/bin:$PATH"

echo "Building installer..."
cd "$INSTALLER_DIR"
make build

echo "Copying installer binaries..."
mkdir -p "${LIVE_ISO_DIR}/airootfs/usr/local/bin"
cp "$INSTALLER_DIR/build/bin/aestheticos-installer" "${LIVE_ISO_DIR}/airootfs/usr/local/bin/"
cp "$INSTALLER_DIR/build/bin/aestheticos-installer-cli" "${LIVE_ISO_DIR}/airootfs/usr/local/bin/"
echo "Installer binaries copied."

PACKAGES_FILE="${LIVE_ISO_DIR}/packages.x86_64"
AUR_PACKAGES_FILE="${LIVE_ISO_DIR}/packages.aur.x86_64"

# Read packages (skip empty lines and comments)
mapfile -t PACKAGES < <(grep -v '^\s*$' "$PACKAGES_FILE" | grep -v '^\s*#')
mapfile -t AUR_PACKAGES < <(grep -v '^\s*$' "$AUR_PACKAGES_FILE" | grep -v '^\s*#')

echo "Official packages: ${#PACKAGES[@]}"
echo "AUR packages: ${#AUR_PACKAGES[@]}"

# Download official packages with dependencies

OFFLINE_CACHE=/tmp/offline-cache-pacman
BLANK_DB=/tmp/blankdb-pacman
mkdir -p "$OFFLINE_CACHE" "$BLANK_DB/sync"

echo "Downloading official packages..."
pacman -Syw --noconfirm --dbpath "$BLANK_DB" --cachedir "$OFFLINE_CACHE" --disable-sandbox "${PACKAGES[@]}"
echo "Downloaded: $(ls "$OFFLINE_CACHE"/*.pkg.tar.zst 2>/dev/null | wc -l)"

# Download and build aur packages

if [ ${#AUR_PACKAGES[@]} -gt 0 ]; then
    useradd -m -s /bin/bash makepkg 2>/dev/null || true
    echo 'makepkg ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/makepkg

    rm -rf /home/makepkg/aurbuild
    mkdir -p /home/makepkg/aurbuild
    chown -R makepkg:makepkg /home/makepkg/aurbuild

    # Configure makepkg to save built packages to a writable dir for offline mirror
    sed -i 's|^#*PKGDEST=.*|PKGDEST=/home/makepkg/pkg|' /etc/makepkg.conf
    sed -i 's|^#*SRCDEST=.*|SRCDEST=/home/makepkg/src|' /etc/makepkg.conf
    mkdir -p /home/makepkg/pkg
    chown makepkg:makepkg /home/makepkg/pkg

    cd /home/makepkg/aurbuild

    for pkg in "${AUR_PACKAGES[@]}"; do
        echo "Building $pkg..."
        git clone "https://aur.archlinux.org/$pkg.git"
        chown -R makepkg:makepkg "$pkg"
        cd "$pkg"
        sudo -u makepkg env BUILDDIR=/home/makepkg/aurbuild makepkg -s --noconfirm --skipinteg || true
        cd ..
    done
    echo "AUR packages are downloaded and built."
fi

# Copy all packages to live-iso offline mirror

MIRROR_DIR="${LIVE_ISO_DIR}/airootfs/var/cache/aestheticos/offline-mirror"
mkdir -p "$MIRROR_DIR"

cp "$OFFLINE_CACHE"/*.pkg.tar.zst "$MIRROR_DIR/"
cp /home/makepkg/pkg/*.pkg.tar.zst "$MIRROR_DIR/" 2>/dev/null || true

REPO_DB="$MIRROR_DIR/aestheticos-offline.db.tar.zst"
repo-add "$REPO_DB" "$MIRROR_DIR"/*.pkg.tar.zst &>/dev/null || true

echo ""
echo "Mirror: $MIRROR_DIR"
echo "Packages: $(ls "$MIRROR_DIR"/*.pkg.tar.zst 2>/dev/null | wc -l)"
echo "Database: $REPO_DB"

# Clean work directory before build
rm -rf "${LIVE_ISO_DIR}/work"

# Build ISO

echo "Building ISO..."
cd "$LIVE_ISO_DIR"
mkarchiso -v -w work -o output -C pacman-offline.conf -m iso .

echo ""
echo "=== ISO build complete ==="
echo "Output: $LIVE_ISO_DIR/output/"
ls -lh "$LIVE_ISO_DIR/output/"*.iso 2>/dev/null || echo "No ISO found"
