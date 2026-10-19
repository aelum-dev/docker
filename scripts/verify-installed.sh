#!/usr/bin/env bash
#
# verify-installed.sh — independently inspect an Aelum install on the target
# disk. It runs inside the live ISO (as root) after test-install.sh performs an
# install. It never calls the installer, so it validates the on-disk result
# rather than the code that produced it.
#
# Inputs (environment, supplied by test-install.sh):
#   FILESYSTEM  ext4 | btrfs   filesystem on the LVs / root partition
#   LUKS        0 | 1          root partition is LUKS2-encrypted
#   LVM         0 | 1          root+home are logical volumes in the `aelum` VG
#   LUKS_PASS   LUKS2 passphrase (LUKS=1)
#   DISK_PATH   target disk inside the guest (default /dev/vda)
#
# The installed system is mounted read-only; every check is reported and the
# script exits non-zero if any check fails.

set -u

FILESYSTEM="${FILESYSTEM:-btrfs}"
LUKS="${LUKS:-0}"
LVM="${LVM:-0}"
LUKS_PASS="${LUKS_PASS:-aelum-luks}"
DISK_PATH="${DISK_PATH:-/dev/vda}"

MNT=/mnt
ESP="${DISK_PATH}1"
ROOT_PART="${DISK_PATH}2"
# Reuse the installer's mapper name (shared.LuksMapperName) so LVM re-discovers
# the PV on the same device path it was created on, even with a devices file.
LUKS_MAPPER=aelum

fails=0
section() { echo; echo "== $* =="; }
ok()  { echo "  ok   - $*"; }
bad() { echo "  FAIL - $*"; fails=$((fails + 1)); }
# check "<description>" <command...> — runs the command, records pass/fail.
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
# has "<haystack>" "<ERE>" / hasnt — substring match on captured output.
has()   { grep -qE "$2" <<<"$1"; }
hasnt() { ! grep -qE "$2" <<<"$1"; }
# fstab_has "<ERE>" / fstab_not "<mount point>"
fstab_has() { grep -Eq "$1" "$MNT/etc/fstab"; }
fstab_not() { ! grep -Eq "[[:space:]]$1[[:space:]]" "$MNT/etc/fstab"; }
# pkg_installed "<pacman root>" "<pkgname>" — true when the pacman local db has it.
pkg_installed() { compgen -G "$1/var/lib/pacman/local/$2-*" >/dev/null; }

cleanup() {
    umount -R "$MNT" 2>/dev/null
    [ "$LVM" = 1 ]  && vgchange -an aelum 2>/dev/null
    [ "$LUKS" = 1 ] && cryptsetup close "$LUKS_MAPPER" 2>/dev/null
    return 0
}
trap cleanup EXIT

echo "Verifying install on $DISK_PATH (fs=$FILESYSTEM luks=$LUKS lvm=$LVM)"

# ── Open LUKS / activate the VG ───────────────────────────────────────────────
pv="$ROOT_PART"
if [ "$LUKS" = 1 ]; then
    # Clear any mapper left open by a failed cleanup before reopening it.
    cryptsetup close "$LUKS_MAPPER" 2>/dev/null || true
    if ! printf '%s' "$LUKS_PASS" | cryptsetup open --type luks2 "$ROOT_PART" "$LUKS_MAPPER" 2>/dev/null; then
        echo "FATAL: could not open LUKS2 on $ROOT_PART"
        exit 1
    fi
    udevadm settle 2>/dev/null || true
    pv="/dev/mapper/$LUKS_MAPPER"
fi

rootdev="$pv"
homedev=""
if [ "$LVM" = 1 ]; then
    if ! vgchange -ay aelum >/dev/null 2>&1; then
        echo "FATAL: could not activate volume group 'aelum'"
        exit 1
    fi
    udevadm settle 2>/dev/null || true
    rootdev=/dev/mapper/aelum-root
    homedev=/dev/mapper/aelum-home
fi

# ── LVM structure ─────────────────────────────────────────────────────────────
if [ "$LVM" = 1 ]; then
    section "LVM"
    vg_names="$(vgs --noheadings -o vg_name 2>/dev/null)"
    lv_names="$(lvs --noheadings -o lv_name aelum 2>/dev/null)"
    pv_names="$(pvs --noheadings -o pv_name 2>/dev/null)"
    check "volume group 'aelum' exists" has "$vg_names" '\baelum\b'
    check "root LV exists" has "$lv_names" '\broot\b'
    check "home LV exists" has "$lv_names" '\bhome\b'
    check "exactly two LVs (no swap LV)" [ "$(printf '%s' "$lv_names" | wc -w)" = 2 ]
    check "exactly one physical volume" [ "$(printf '%s' "$pv_names" | wc -w)" = 1 ]
    if [ "$LUKS" = 0 ]; then
        check "PV is $ROOT_PART" has "$pv_names" "$(basename "$ROOT_PART")"
    fi
    check "root LV device present" [ -e "$rootdev" ]
    check "home LV device present" [ -e "$homedev" ]
else
    section "LVM (expecting none)"
    check "no 'aelum' volume group" hasnt "$(vgs --noheadings -o vg_name 2>/dev/null)" '\baelum\b'
fi

# ── Mount the installed system read-only ──────────────────────────────────────
mkdir -p "$MNT"
if [ "$FILESYSTEM" = btrfs ]; then
    mount -o ro,subvol=@ "$rootdev" "$MNT" || { echo "FATAL: could not mount $rootdev (subvol=@)"; exit 1; }
else
    mount -o ro "$rootdev" "$MNT" || { echo "FATAL: could not mount $rootdev"; exit 1; }
fi
mkdir -p "$MNT/boot"
mount -o ro "$ESP" "$MNT/boot" 2>/dev/null \
    || echo "  note - could not mount ESP read-only; boot-entry checks may fail"

# ── Filesystems ───────────────────────────────────────────────────────────────
section "Filesystems"
check "root filesystem is $FILESYSTEM" [ "$(blkid -o value -s TYPE "$rootdev")" = "$FILESYSTEM" ]
check "ESP is vfat" [ "$(blkid -o value -s TYPE "$ESP")" = vfat ]
if [ "$LVM" = 1 ]; then
    check "home LV filesystem is $FILESYSTEM" [ "$(blkid -o value -s TYPE "$homedev")" = "$FILESYSTEM" ]
fi

# ── fstab ─────────────────────────────────────────────────────────────────────
section "fstab"
check "fstab exists and is non-empty" [ -s "$MNT/etc/fstab" ]
check "fstab mounts / as $FILESYSTEM" fstab_has "^UUID=[0-9a-fA-F-]+[[:space:]]+/[[:space:]]+$FILESYSTEM"
check "fstab mounts /boot as vfat" fstab_has "/boot[[:space:]]+vfat"
root_uuid="$(blkid -o value -s UUID "$rootdev")"
check "fstab references the root filesystem UUID" fstab_has "$root_uuid"
if [ "$LVM" = 1 ]; then
    home_uuid="$(blkid -o value -s UUID "$homedev")"
    check "fstab mounts /home as $FILESYSTEM on the home LV" fstab_has "^UUID=$home_uuid[[:space:]]+/home[[:space:]]+$FILESYSTEM"
    if [ "$FILESYSTEM" = btrfs ]; then
        check "/home uses the @home subvolume" fstab_has "^UUID=$home_uuid[[:space:]]+/home[[:space:]]+btrfs.*subvol=@home"
    fi
elif [ "$FILESYSTEM" = btrfs ]; then
    check "fstab mounts /home as the @home subvolume" fstab_has "^UUID=$root_uuid[[:space:]]+/home[[:space:]]+btrfs.*subvol=@home"
else
    check "fstab has no /home entry (ext4, no LVM)" fstab_not /home
fi

# ── initramfs hooks ───────────────────────────────────────────────────────────
section "initramfs"
hooks="$(grep -E '^HOOKS=' "$MNT/etc/mkinitcpio.conf" 2>/dev/null)"
echo "  HOOKS: $hooks"
if [ "$LVM" = 1 ]; then
    check "HOOKS include lvm2" has "$hooks" '(^|[^[:alnum:]_])lvm2([^[:alnum:]_]|$)'
else
    check "HOOKS exclude lvm2" hasnt "$hooks" '(^|[^[:alnum:]_])lvm2([^[:alnum:]_]|$)'
fi
if [ "$LUKS" = 1 ]; then
    check "HOOKS include an encrypt hook" has "$hooks" '(^|[^[:alnum:]_])(sd-encrypt|encrypt)([^[:alnum:]_]|$)'
fi

# ── Boot entry ────────────────────────────────────────────────────────────────
section "boot entry"
entry="$(ls "$MNT"/boot/loader/entries/*.conf 2>/dev/null | head -1)"
if [ -z "$entry" ]; then
    bad "systemd-boot entry exists under /boot/loader/entries/"
else
    opts="$(grep -E '^options' "$entry")"
    echo "  $opts"
    if [ "$LVM" = 1 ]; then
        check "entry roots at the root LV (/dev/mapper/aelum-root)" has "$opts" 'root=/dev/mapper/aelum-root'
    else
        check "entry roots at the root filesystem UUID" has "$opts" 'root=UUID='
    fi
    if [ "$LUKS" = 1 ]; then
        check "entry has rd.luks.name=" has "$opts" 'rd\.luks\.name='
    else
        check "entry has no rd.luks.name= (no LUKS)" hasnt "$opts" 'rd\.luks\.name='
    fi
    if [ "$FILESYSTEM" = btrfs ]; then
        check "entry has rootflags=subvol=@ (btrfs)" has "$opts" 'rootflags=subvol=@'
    else
        check "entry has no btrfs rootflags (ext4)" hasnt "$opts" 'rootflags=subvol='
    fi
fi

# ── Installed packages ────────────────────────────────────────────────────────
section "installed system"
check "system is populated (/etc/os-release present)" [ -s "$MNT/etc/os-release" ]
if [ "$LVM" = 1 ]; then
    check "lvm2 package installed" pkg_installed "$MNT" lvm2
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "VERIFY: PASS (fs=$FILESYSTEM luks=$LUKS lvm=$LVM)"
    exit 0
fi
echo "VERIFY: FAIL ($fails check(s) failed)"
exit 1
