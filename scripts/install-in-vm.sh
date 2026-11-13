#!/usr/bin/env bash
#
# install-in-vm.sh — install a locally built Arch package into the system that is
# installed on docker/vdisk.qcow2: the only place in this project with an
# installed system to install into.
#
#   ./scripts/install-in-vm.sh ../package-installer/dist/aelum-package-installer-0.5.9-2-x86_64.pkg.tar.zst
#   ./scripts/install-in-vm.sh <pkg> --sync        # also pacman -Sy in the target
#   ./scripts/install-in-vm.sh <pkg> --keep-vm     # leave the live session running
#   LUKS_PASS=… ./scripts/install-in-vm.sh <pkg>   # the disk holds a LUKS install
#   make -C docker install-pkg PKG=<path>          # the same thing through the Makefile
#
# This is how an app that ships through the [aelum] repository is smoke-tested
# before it is published: the channel only ever serves what was already published,
# so `pacman -S` inside the guest can never bring the change under test. The
# artifact has to be named on disk.
#
# What it does, in order:
#
#   1. reads .PKGINFO out of the archive (its first member, so the read stops
#      there) to learn what it is about to install, then copies the archive into
#      shared/ — the host side of the guest's /shared 9p bridge. A signature goes
#      with it: pacman checks a local `-U` install too and looks for
#      `<file>.sig` in *binary* form, so a build script's armored `.asc` is
#      dearmored on the way rather than copied.
#   2. reuses the live session if one is up on the SSH port, and otherwise boots
#      it (scripts/test-install.sh MODE=boot).
#   3. mounts the installed system's root whatever its shape is — plain, LUKS,
#      LVM, or LUKS under LVM — with no `subvol=` on btrfs, because the default
#      subvolume is the system the installer wrote.
#   4. runs `pacman -U` through arch-chroot, so the package's own hooks run in
#      the target and not in the live session, then asks the target's pacman what
#      it has installed.
#   5. unmounts what it mounted, powers off a session it booted, and points the
#      UEFI boot order at the install, so the next `make run-disk` opens the
#      desktop that has the change in it.
#
# The installed system is throwaway: this changes the test disk, not the source.
# A fresh `make test-one` replaces whatever this installed.
#
# Requirements: the same as test-install.sh (qemu-system-x86_64, ssh, sshpass),
# plus tar with zstd; gpg to dearmor a signature.

set -uo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DISTRO_DIR="$(cd "$PROFILE_DIR/.." && pwd)"
SHARED_DIR="${SHARED_DIR:-$DISTRO_DIR/shared}"
ISO="${ISO:-$(find "$PROFILE_DIR/output" -maxdepth 1 -name "*.iso" 2>/dev/null | sort | tail -1)}"
SSH_PORT="${SSH_PORT:-2222}"
ROOT_PASS="${ROOT_PASS:-}"             # the live session's root SSH uses an empty password
LUKS_PASS="${LUKS_PASS:-aelum-luks}"   # the passphrase test-install.sh encrypts with
KEEP_UP="${KEEP_UP:-0}"                # leave the live session running afterwards: 0 | 1
SYNC="${SYNC:-0}"                      # also refresh the target's databases: 0 | 1

log()  { printf '[install] %s\n' "$*"; }
err()  { printf '[install] ERROR: %s\n' "$*" >&2; }
fail() { err "$*"; exit 1; }
# The header comment *is* the help: printed until the first non-comment line.
# The exit test comes first because sub() rewrites $0, and the rewritten line no
# longer looks like a comment — the first version of this stopped after one line.
usage() { awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

PKG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sync)    SYNC=1 ;;
        --keep-vm) KEEP_UP=1 ;;
        -h | --help) usage; exit 0 ;;
        -*)        fail "unknown option: $1 (see --help)" ;;
        *)         [ -z "$PKG" ] || fail "more than one package given"; PKG="$1" ;;
    esac
    shift
done

[ -n "$PKG" ] || fail "usage: $(basename "$0") <path to .pkg.tar.zst> [--sync] [--keep-vm]"
[ -f "$PKG" ] || fail "no such file: $PKG"
PKG="$(readlink -f "$PKG")"

command -v ssh     >/dev/null 2>&1 || fail "ssh not found"
command -v sshpass >/dev/null 2>&1 || fail "sshpass not found (pacman -S sshpass)"
command -v tar     >/dev/null 2>&1 || fail "tar not found"

# ── What is this package? ────────────────────────────────────────────────────
# .PKGINFO is the first member of the archive and --occurrence stops the read
# there, so this stays cheap for a package file of hundreds of MB. Its keys are
# `pkgname`/`pkgver` — the `%NAME%`/`%VERSION%` spelling belongs to pacman's
# database, not to the archive.
pkginfo="$(tar --zstd --occurrence=1 -xOf "$PKG" .PKGINFO 2>/dev/null | head -c 262144)"
PKG_NAME="$(sed -n 's/^pkgname[[:space:]]*=[[:space:]]*//p' <<<"$pkginfo" | head -1)"
PKG_VER="$(sed -n 's/^pkgver[[:space:]]*=[[:space:]]*//p' <<<"$pkginfo" | head -1)"
[ -n "$PKG_NAME" ] && [ -n "$PKG_VER" ] ||
    fail "cannot read .PKGINFO from $PKG — is it a built Arch package?"
PKG_BASE="$(basename "$PKG")"
case "$PKG_BASE" in
    *[![:alnum:]_.+-]* | . | ..) fail "not a name the bridge can hold: $PKG_BASE" ;;
esac
log "Package: $PKG_NAME $PKG_VER ($PKG_BASE)"

# ── Put it where the guest can read it ───────────────────────────────────────
mkdir -p "$SHARED_DIR" || fail "cannot create $SHARED_DIR"
cp -f "$PKG" "$SHARED_DIR/$PKG_BASE" || fail "cannot copy to $SHARED_DIR"
if [ -f "$PKG.sig" ]; then
    cp -f "$PKG.sig" "$SHARED_DIR/$PKG_BASE.sig"
elif [ -f "$PKG.asc" ] && command -v gpg >/dev/null 2>&1; then
    # An armored `.asc` copied under the `.sig` name answers "signature format
    # error"; the binary form is what pacman's SigLevel checks
    # (repo/publish-repo.sh signs that way for the same reason).
    gpg --dearmor < "$PKG.asc" > "$SHARED_DIR/$PKG_BASE.sig" ||
        fail "could not dearmor $PKG.asc"
elif [ -f "$PKG.asc" ]; then
    cp -f "$PKG.asc" "$SHARED_DIR/$PKG_BASE.sig"
else
    log "no .sig/.asc beside the package — the target's SigLevel may refuse it."
    log "sign it with:  gpg --detach-sign --output '$PKG.sig' '$PKG'"
fi

# ── Talking to the guest ─────────────────────────────────────────────────────
# One spelling of "run this as root in the live session". sshpass is what
# test-install.sh uses: the live session's root SSH has an empty password.
guest() {
    sshpass -p "$ROOT_PASS" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
        root@localhost "$@"
}
# Asks the target's own pacman what it has installed. Nonzero means "not
# installed", which is an answer, not a failure.
arch_query() { guest "arch-chroot /mnt pacman -Q '$1' 2>/dev/null"; }
guest_up()   { guest true >/dev/null 2>&1; }
vm_running() { pgrep -f "qemu-system-x86_64.*[v]disk.qcow2" >/dev/null 2>&1; }

started_vm=0
cleanup_done=0
finished=0
reached_guest=0
mnt_was=no
bind_was=no
mounted_by_us=0
bind_by_us=0
# Leaves the disk bootable and the mounts as they were found: only what this run
# mounted is taken away (a session left up for experiments may have its own
# mounts), a live session the user had already started is theirs to close, and
# OVMF's NVRAM belongs to whichever QEMU is running, so the boot order is only
# rewritten once the disk is free.
cleanup() {
    [ "$cleanup_done" = 1 ] && return
    cleanup_done=1
    vm_running || return
    [ "$bind_by_us" = 1 ] && guest 'umount /mnt/shared 2>/dev/null || true' >/dev/null 2>&1
    [ "$mounted_by_us" = 1 ] && guest 'umount -R /mnt 2>/dev/null || true' >/dev/null 2>&1
    if [ "$started_vm" = 1 ] && [ "$KEEP_UP" != 1 ]; then
        guest 'sync; poweroff' >/dev/null 2>&1
        for _ in $(seq 1 60); do vm_running || break; sleep 1; done
        "$PROFILE_DIR/scripts/boot-target.sh" disk >/dev/null ||
            log "WARN: no firmware entry for the install; 'make -C docker demo-snapshots' writes one"
        if [ "$finished" = 1 ]; then
            log "Next:  make -C docker run-disk"
        else
            log "The test disk was left as it was; fix the cause and run this again."
        fi
    elif [ "$started_vm" = 1 ]; then
        log "Left the live session running (--keep-vm); 'make run-disk' needs it off"
    elif [ "$reached_guest" = 1 ]; then
        log "Left the live session that was already up; power it off before 'make run-disk'"
    fi
}
trap cleanup EXIT

if guest_up; then
    # Only the live session can mount the installed system's root — the installed
    # system is the thing being mounted, and a booted desktop cannot mount itself.
    guest 'test -d /run/archiso/bootmnt' >/dev/null 2>&1 ||
        fail "port $SSH_PORT is a running system, but not the live session; power it off first"
    guest 'test -d /shared' >/dev/null 2>&1 ||
        fail "that live session has no /shared bridge; boot it with test-install.sh in boot mode"
    log "live session already up on :$SSH_PORT; using it"
elif vm_running; then
    fail "a VM holds the test disk but sshd is not answering on :$SSH_PORT.
       It may be sitting at the firmware prompt: power it off and run this again."
else
    [ -n "$ISO" ] && [ -f "$ISO" ] ||
        fail "no ISO in $PROFILE_DIR/output/ — build it first (make -C docker local-build)"
    # test-boot gates its ready check on /shared/aelum-installer-cli, so the
    # bridge needs the installer binaries before that gate can pass.
    if [ ! -x "$SHARED_DIR/aelum-installer-cli" ] && [ -x "$DISTRO_DIR/installer/build/bin/aelum-installer-cli" ]; then
        log "staging aelum-installer{,-cli} into shared/ (test-boot's ready gate) ..."
        cp "$DISTRO_DIR/installer/build/bin/aelum-installer"{,-cli} "$SHARED_DIR/"
    fi
    log "booting the live ISO ..."
    started_vm=1
    MODE=boot SSH_PORT="$SSH_PORT" "$PROFILE_DIR/scripts/test-install.sh" >/dev/null ||
        fail "the live session did not come up (see docker/logs/qemu.log)"
fi
log "guest is up on :$SSH_PORT with /shared mounted"
reached_guest=1

# What was already mounted stays mounted: a session left up for experiments may
# have its own mounts, and this script is not the one to take them away.
mnt_was="$(guest 'findmnt -M /mnt >/dev/null && echo yes || echo no')"
bind_was="$(guest 'findmnt -M /mnt/shared >/dev/null && echo yes || echo no')"

# ── Mount the installed system ───────────────────────────────────────────────
# The shape of the root is whatever the last install chose. LUKS always sits
# below LVM, so: open the LUKS partition, activate a volume group only when an
# LVM2_member is actually visible (`lvs` exits 0 with none on the live session,
# which made the first version of this announce an LVM layout that was never
# there), then take the btrfs/ext4 filesystem — preferring an LV named *-root,
# because a real layout has a home LV of the same type beside it. No `subvol=`:
# the installer makes the factory snapshot the default subvolume, and pinning a
# name would read a system that is not the one that boots.
#
# PATH, not NAME: NAME is a bare `vda2`, which mount answers "Can't lookup
# blockdev" for, and an LV's name is not a path at all.
mount_root() {
    guest "bash -s -- $(printf '%q' "$LUKS_PASS")" <<'REMOTE'
set -uo pipefail
luks_pass="$1"
findmnt -M /mnt >/dev/null && { echo 'the installed system is already mounted at /mnt'; exit 0; }
part="$(lsblk -rno PATH,FSTYPE /dev/vda | awk '$2=="crypto_LUKS"{print $1; exit}')"
if [ -n "$part" ]; then
    printf '%s\n' "$luks_pass" | cryptsetup open "$part" aelum-vm-crypt \
        || { echo "could not open the LUKS partition $part (LUKS_PASS=…?)" >&2; exit 1; }
    echo "opened the LUKS partition $part"
fi
if lsblk -rno PATH,FSTYPE | grep -q 'LVM2_member'; then
    vgchange -ay >/dev/null && echo 'activated the volume group'
fi
cands="$(lsblk -rno PATH,FSTYPE | awk '$2=="btrfs"||$2=="ext4"{print $1}')"
root="$(printf '%s\n' "$cands" | grep -E -- '-root$' | head -1)"
[ -n "$root" ] || root="$(printf '%s\n' "$cands" | head -1)"
[ -n "$root" ] || { echo 'no btrfs or ext4 filesystem on the test disk' >&2; exit 3; }
mount "$root" /mnt || { echo "could not mount $root at /mnt" >&2; exit 1; }
[ -e /mnt/etc/pacman.conf ] || { echo '/mnt has no pacman.conf — not an installed system' >&2; exit 4; }
echo "mounted the installed system from $root"
REMOTE
}
mount_root || fail "could not mount the installed system. Is there one on the disk?
       Make one with:  make -C docker test-one FILESYSTEM=btrfs"
[ "$mnt_was" = yes ] || mounted_by_us=1

# ── Install, then ask the target what it has ─────────────────────────────────
# The transaction runs through arch-chroot so the package's own pacman hooks run
# in the target; -U names the file, because the [aelum] channel only carries what
# was already published.
before="$(arch_query "$PKG_NAME" || true)"
[ "$bind_was" = yes ] || bind_by_us=1
guest "bash -s -- '$PKG_BASE'" <<'REMOTE' || fail "the transaction failed — the target is left as it was."
set -uo pipefail
base="$1"
findmnt -M /mnt/shared >/dev/null || { mkdir -p /mnt/shared; mount --bind /shared /mnt/shared; }
arch-chroot /mnt pacman -U --noconfirm "/shared/$base"
REMOTE

after="$(arch_query "$PKG_NAME" || true)"
[ -n "$after" ] || fail "the target does not report $PKG_NAME after the transaction"
if [ -n "$before" ]; then
    log "target now has: $after  (was: $before)"
else
    log "target now has: $after  (was: not installed)"
fi

if [ "$SYNC" = 1 ]; then
    log "refreshing the target's databases (needs the guest's network) ..."
    guest 'arch-chroot /mnt pacman -Sy --noconfirm' >/dev/null ||
        log "the refresh failed; the app's own Refresh asks the same question"
fi

finished=1
