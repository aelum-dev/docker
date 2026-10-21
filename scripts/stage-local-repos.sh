#!/usr/bin/env bash
# Stage the local live-iso/ and installer/ working trees for an ISO build.
#
# `make local-build` uses this instead of the GitHub clones in build-iso.sh, so
# an ISO can be built and booted from unpushed changes. The copies live in
# ${AELUM_LOCAL_STAGE:-/tmp/aelum-local-build} and are bind-mounted into the
# build container; your actual repos stay untouched.
#
# Build artifacts are excluded (the ISO build regenerates them). The live-iso
# work/ tree alone is ~11 GiB after a build, and the offline mirror is rebuilt
# from the package lists every run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGE="${AELUM_LOCAL_STAGE:-/tmp/aelum-local-build}"

# Sibling repos by default; override for a different checkout layout.
LIVE_ISO_SRC="${AELUM_LIVE_ISO_SRC:-$DISTRO_ROOT/live-iso}"
INSTALLER_SRC="${AELUM_INSTALLER_SRC:-$DISTRO_ROOT/installer}"

for src in "$LIVE_ISO_SRC" "$INSTALLER_SRC"; do
    if [ ! -d "$src" ]; then
        echo "ERROR: expected repo not found: $src" >&2
        echo "Run this from the distro workspace (installer/ + live-iso/ next to docker/) or set" >&2
        echo "AELUM_LIVE_ISO_SRC / AELUM_INSTALLER_SRC to the checkout paths." >&2
        exit 1
    fi
done

# A previous build runs as root inside the container; if it was killed before
# the chown-back trap, the stage can contain root-owned files. Remove them via
# the toolchain image so staging never requires sudo on the host.
if [ -e "$STAGE" ] && ! rm -rf "$STAGE" 2>/dev/null; then
    echo "Removing root-owned leftovers in $STAGE via aelum-image..."
    if ! docker run --rm -v "$STAGE:/stage" aelum-image rm -rf /stage; then
        echo "ERROR: could not clean $STAGE." >&2
        echo "Remove it manually, then retry: sudo rm -rf '$STAGE'" >&2
        exit 1
    fi
    rm -rf "$STAGE"
fi
mkdir -p "$STAGE"

# The build writes live-iso/work (several GiB) and the offline mirror into the
# stage. /tmp is a small tmpfs on some distros, so warn before the build dies
# halfway through.
avail_kib="$(df -Pk "$STAGE" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "${avail_kib:-}" ] && [ "$avail_kib" -lt $((15 * 1024 * 1024)) ]; then
    avail_human="$(df -Ph "$STAGE" 2>/dev/null | awk 'NR==2 {print $4}')"
    echo "WARNING: only ${avail_human} free in $STAGE; a full build needs ~15 GiB." >&2
    echo "         Use a larger filesystem if needed: LOCAL_STAGE=/var/tmp/aelum-local-build" >&2
fi

# cp -a equivalent without rsync: tar preserves modes/ownership (as the current
# user) and includes dotfiles. Excludes are anchored to the repo root.
copy_tree() {
    local src="$1" dst="$2"
    shift 2
    mkdir -p "$dst"
    tar -C "$src" --exclude=./.git "$@" -cf - . | tar -C "$dst" -xf -
}

echo "Staging local repos in $STAGE"

copy_tree "$LIVE_ISO_SRC" "$STAGE/live-iso" \
    --exclude=./work \
    --exclude=./output \
    --exclude='./airootfs/var/cache/aelum/offline-mirror/*' \
    --exclude='./airootfs/usr/local/bin/aelum-installer' \
    --exclude='./airootfs/usr/local/bin/aelum-installer-cli'

copy_tree "$INSTALLER_SRC" "$STAGE/installer" \
    --exclude=./build/bin \
    --exclude=./build/darwin \
    --exclude=./build/windows \
    --exclude=./frontend/node_modules \
    --exclude=./frontend/dist

# mkarchiso writes the ISO here (the bind-mounted host docker/output shadows
# this for the real build; it just has to exist).
mkdir -p "$STAGE/live-iso/output"

echo "Staged:"
du -sh "$STAGE/live-iso" "$STAGE/installer"
