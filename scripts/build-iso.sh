#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# When set to 1, skip cloning installer/ and live-iso/ from GitHub and use the
# host repos mounted into the container instead (see `make dev SKIP_REPO_CLONE=1`).
# This lets you build an ISO from your local, unpushed changes.
SKIP_REPO_CLONE="${SKIP_REPO_CLONE:-0}"

# Build toolchain (git, base-devel, archiso, go, nodejs, gtk3, webkit2gtk,
# grub, memtest86+) is provided by the docker image. See ./Dockerfile.

# Clone live-iso profile

LIVE_ISO_DIR="/app/live-iso"
TMP_ISO="/tmp/live-iso-clone"
rm -rf "$TMP_ISO"
mkdir -p "$LIVE_ISO_DIR"
if [ "$SKIP_REPO_CLONE" = "1" ]; then
    echo "SKIP_REPO_CLONE=1: using local live-iso repo at $LIVE_ISO_DIR (no git clone)"
else
    echo "Cloning live-iso profile..."
    git clone --depth 1 https://github.com/aelum-dev/live-iso.git "$TMP_ISO"
    cp -a "$TMP_ISO"/* "$TMP_ISO"/.[!.]* "$TMP_ISO"/..?* "$LIVE_ISO_DIR/" 2>/dev/null || true
    rm -rf "$TMP_ISO"
fi

# Clone and build installer

INSTALLER_DIR="/app/installer"
TMP_INSTALLER="/tmp/installer-clone"
rm -rf "$TMP_INSTALLER"
mkdir -p "$INSTALLER_DIR"
if [ "$SKIP_REPO_CLONE" = "1" ]; then
    echo "SKIP_REPO_CLONE=1: using local installer repo at $INSTALLER_DIR (no git clone)"
else
    echo "Cloning installer..."
    git clone --depth 1 https://github.com/aelum-dev/installer.git "$TMP_INSTALLER"
    cp -a "$TMP_INSTALLER"/* "$TMP_INSTALLER"/.[!.]* "$TMP_INSTALLER"/..?* "$INSTALLER_DIR/" 2>/dev/null || true
    rm -rf "$TMP_INSTALLER"
fi

# Fresh clones are dropped into the same directories the local-repo build
# bind-mounts (see make local-build). Either way the rest of the script works on
# /app/live-iso + /app/installer.

# Local builds (`make local-build`) bind-mount staged host trees into the
# container. This script runs as root and writes into them (offline mirror,
# work/, build/bin), so hand them back to the host user on exit — including on
# failure — or the next staging pass cannot replace root-owned files.
if [ "${CHOWN_WORKTREES:-0}" = "1" ]; then
    OUT_UID="${OUTPUT_UID:-1000}"
    OUT_GID="${OUTPUT_GID:-1000}"
    chown_worktrees() {
        chown -R "${OUT_UID}:${OUT_GID}" "$LIVE_ISO_DIR" "$INSTALLER_DIR" 2>/dev/null || true
    }
    trap chown_worktrees EXIT
    # Bash does not run EXIT traps on SIGTERM/SIGINT by default; turn both into
    # a normal exit so an interrupted `make local-build` still hands the staged
    # trees back (otherwise the next staging pass needs the container fallback).
    trap 'exit 143' TERM INT

    # The bind-mounted repos are owned by the host user while this script runs
    # as root. Without this, git reports "dubious ownership", `git describe`
    # yields nothing, and `go build`'s VCS stamping aborts the installer build.
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0=safe.directory
    export GIT_CONFIG_VALUE_0="$LIVE_ISO_DIR"
    export GIT_CONFIG_KEY_1=safe.directory
    export GIT_CONFIG_VALUE_1="$INSTALLER_DIR"
fi

export PATH="$HOME/go/bin:$PATH"

# Refresh the base system and sync database before anything else.
pacman -Syu --noconfirm

echo "Building installer..."
cd "$INSTALLER_DIR"
make build

echo "Copying installer binaries..."
mkdir -p "${LIVE_ISO_DIR}/airootfs/usr/local/bin"
cp "$INSTALLER_DIR/build/bin/aelum-installer" "${LIVE_ISO_DIR}/airootfs/usr/local/bin/"
cp "$INSTALLER_DIR/build/bin/aelum-installer-cli" "${LIVE_ISO_DIR}/airootfs/usr/local/bin/"
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

    # makepkg -s installed each AUR package's dependencies into the live system,
    # not into $OFFLINE_CACHE. Re-download each built package plus its dependency
    # tree into the offline cache so they are available in the ISO.
    shopt -s nullglob
    aur_built=(/home/makepkg/pkg/*.pkg.tar.zst)
    shopt -u nullglob

    if [ ${#aur_built[@]} -gt 0 ]; then
        echo "Downloading AUR packages and their dependencies into offline cache (download-only)..."

        # Expose the built AUR packages as a local repo so pacman can resolve
        # each package by name and pull its runtime dependencies from the
        # official mirrors. Include = /etc/pacman.conf keeps the real mirrors.
        # repo-add creates aur-local.db.tar.zst plus an 'aur-local.db' symlink,
        # which is what pacman's file:// retrieval requests.
        repo-add /home/makepkg/pkg/aur-local.db.tar.zst /home/makepkg/pkg/*.pkg.tar.zst 2>/dev/null
        cat > /tmp/offline-pacman.conf <<'EOF'
            Include = /etc/pacman.conf

            [aur-local]
            Server = file:///home/makepkg/pkg
            # Built AUR packages have no .sig files; scope signature-skipping to this repo
            # only, so the official mirrors still enforce their SigLevel.
            SigLevel = Never
EOF

        # Read each package's name from its file (reliable regardless of messy
        # version strings), then download it together with its dependency tree
        # into --cachedir. -w keeps this download-only: nothing is extracted
        # into the container, matching the original -Syw intent.
        mapfile -t aur_names < <(
            for f in "${aur_built[@]}"; do
                # pacman -Qp prints "<name> <version>" per package; take the name.
                pacman -Qp "$f" | awk '{print $1}'
            done
        )
        pacman -Syw --noconfirm --disable-sandbox \
            --config /tmp/offline-pacman.conf \
            --dbpath "$BLANK_DB" --cachedir "$OFFLINE_CACHE" \
            "${aur_names[@]}"
    fi
fi

# Copy all packages to live-iso offline mirror

MIRROR_DIR="${LIVE_ISO_DIR}/airootfs/var/cache/aelum/offline-mirror"
mkdir -p "$MIRROR_DIR"

cp "$OFFLINE_CACHE"/*.pkg.tar.zst "$MIRROR_DIR/"
cp /home/makepkg/pkg/*.pkg.tar.zst "$MIRROR_DIR/" 2>/dev/null || true

REPO_DB="$MIRROR_DIR/aelum-offline.db.tar.zst"
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

# The build runs as root, so files written into the mounted output dir would
# otherwise be root-owned on the host. Hand them back to the host user (passed
# in via docker-compose environment, defaulting to a standard non-root id).
OUT_UID="${OUTPUT_UID:-1000}"
OUT_GID="${OUTPUT_GID:-1000}"
chown -R "${OUT_UID}:${OUT_GID}" "$LIVE_ISO_DIR/output"
echo "Output owned by ${OUT_UID}:${OUT_GID}"

echo ""
echo "=== ISO build complete ==="
echo "Output: $LIVE_ISO_DIR/output/"
ls -lh "$LIVE_ISO_DIR/output/"*.iso 2>/dev/null || echo "No ISO found"
