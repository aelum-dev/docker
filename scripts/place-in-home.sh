#!/usr/bin/env bash
#
# place-in-home.sh — put a freshly built file into the aelum home of the
# installed system on the test disk, through the live session:
#
#   ./scripts/place-in-home.sh ../package-installer/target/release/package-installer
#
# The file crosses to the guest through shared/ (the 9p bridge at /shared),
# lands in /home/aelum owned by aelum with the source's mode, and the copy is
# verified against the source's sha256 before anything is torn down.
#
# The default install layout is assumed: btrfs root on /dev/vda2 with @home as
# a separate subvolume — no LUKS, no LVM. A live session that is already up
# (test-boot) is reused and left up; one this script boots is powered off
# again, so the disk and the SSH port stay free.
#
# Requirements: the same as test-install.sh (qemu-system-x86_64, ssh, sshpass).

set -uo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DISTRO_DIR="$(cd "$PROFILE_DIR/.." && pwd)"
SHARED_DIR="${SHARED_DIR:-$DISTRO_DIR/shared}"
SSH_PORT="${SSH_PORT:-2222}"

log() { printf '[place] %s\n' "$*"; }
fail() { log "$*" >&2; exit 1; }

[ $# -eq 1 ] || fail "usage: place-in-home.sh <file>"
SRC="$1"
[ -f "$SRC" ] && [ -r "$SRC" ] || fail "not a readable file: $SRC"
SRC="$(readlink -f "$SRC")"
NAME="$(basename "$SRC")"
case "$NAME" in
    *[![:alnum:]_.+-]* | . | ..) fail "not a name a directory can hold: $NAME" ;;
esac
SRC_SHA="$(sha256sum "$SRC" | cut -d' ' -f1)"

ssh_root() {
    ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 root@localhost "$@"
}
guest_up() { ssh_root true >/dev/null 2>&1; }

BOOTED_BY_US=0
if guest_up; then
    # The port can also hold a booted installed system (run-disk): its root is
    # /dev/vda2 itself, and placing a file "into its /mnt" is not this job.
    ssh_root 'test -d /run/archiso/bootmnt' >/dev/null 2>&1 \
        || fail "port $SSH_PORT is a running system, but not the live session; power it off first"
    ssh_root 'test -d /shared' >/dev/null 2>&1 \
        || fail "that live session has no /shared bridge; boot it with test-install.sh in boot mode"
    log "live session already up on :$SSH_PORT; using it"
else
    # test-boot gates its ready check on /shared/aelum-installer-cli, so the
    # installer binaries have to be in the bridge before that gate can pass.
    mkdir -p "$SHARED_DIR"
    if [ ! -x "$SHARED_DIR/aelum-installer-cli" ]; then
        [ -x "$DISTRO_DIR/installer/build/bin/aelum-installer-cli" ] \
            || fail "no aelum-installer-cli in $SHARED_DIR and installer/build/bin has nothing to stage it from; build the installer first"
        log "staging aelum-installer{,-cli} into shared/ (test-boot's ready gate) ..."
        cp "$DISTRO_DIR/installer/build/bin/aelum-installer"{,-cli} "$SHARED_DIR/"
    fi
    log "booting the live ISO ..."
    MODE=boot "$PROFILE_DIR/scripts/test-install.sh" || fail "the live session did not come up"
    BOOTED_BY_US=1
fi

# What was already mounted stays mounted: a session left up for experiments may
# have its own mounts, and this script is not the one to take them away.
ROOT_WAS="$(ssh_root 'findmnt -M /mnt >/dev/null && echo yes || echo no')"
HOME_WAS="$(ssh_root 'findmnt -M /mnt/home >/dev/null && echo yes || echo no')"

log "copying $NAME into the bridge ..."
cp "$SRC" "$SHARED_DIR/$NAME"

log "placing $NAME in the installed system's aelum home ..."
ssh_root "bash -s -- '$NAME' '$SRC_SHA'" <<'REMOTE' || fail "placing $NAME failed"
set -uo pipefail
name="$1"; want="$2"
findmnt -M /mnt >/dev/null || mount /dev/vda2 /mnt \
    || { echo "could not mount /dev/vda2 at /mnt — is there a default (btrfs, no LUKS/LVM) install on the test disk?" >&2; exit 1; }
findmnt -M /mnt/home >/dev/null || mount -o subvol=@home /dev/vda2 /mnt/home
grep '^aelum:' /mnt/etc/passwd >/dev/null \
    || { echo "the installed system has no aelum user" >&2; exit 1; }
IFS=: read -r _ _ uid gid _ <<<"$(grep '^aelum:' /mnt/etc/passwd)"
mkdir -p /mnt/home/aelum
cp -f "/shared/$name" "/mnt/home/aelum/$name"
chmod --reference="/shared/$name" "/mnt/home/aelum/$name"
chown "$uid:$gid" "/mnt/home/aelum/$name"
got="$(sha256sum "/mnt/home/aelum/$name" | cut -d' ' -f1)"
[ "$got" = "$want" ] || { echo "sha256 mismatch: guest $got, host $want" >&2; exit 1; }
ls -la "/mnt/home/aelum/$name"
REMOTE

[ "$HOME_WAS" = yes ] || ssh_root 'umount /mnt/home'
[ "$ROOT_WAS" = yes ] || ssh_root 'umount /mnt'

if [ "$BOOTED_BY_US" = 1 ]; then
    log "powering the live session off ..."
    ssh_root 'sync; poweroff' >/dev/null 2>&1
    for _ in $(seq 1 60); do
        guest_up || break
        sleep 1
    done
    guest_up && fail "the live session is still up after poweroff"
fi

log "placed /home/aelum/$NAME on the installed system (sha256 $SRC_SHA)"
