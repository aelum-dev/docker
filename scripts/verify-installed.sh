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
#   REUSE_ESP   0 | 1          the ESP was pre-created and reused (dualboot)
#
# The installed system is mounted read-only; every check is reported and the
# script exits non-zero if any check fails.

set -u

FILESYSTEM="${FILESYSTEM:-btrfs}"
LUKS="${LUKS:-0}"
LVM="${LVM:-0}"
LUKS_PASS="${LUKS_PASS:-aelum-luks}"
DISK_PATH="${DISK_PATH:-/dev/vda}"
REUSE_ESP="${REUSE_ESP:-0}"

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

# The installed system mounts the ESP at /efi and its per-install boot
# directory (aelum/<id>) at /boot. Mount the ESP at the path fstab uses so
# rEFInd files and this install's kernel images are reachable directly.
root_uuid="$(blkid -o value -s UUID "$rootdev")"
install_id="$(printf '%s' "$root_uuid" | tr -d '[:punct:]' | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
mkdir -p "$MNT/efi"
# Name the filesystem type: the kernel probe can miss a FAT partition when the
# vfat module has not been loaded yet.
mount -t vfat -o ro "$ESP" "$MNT/efi" 2>/dev/null \
    || echo "  note - could not mount ESP read-only; boot-entry checks may fail"
boot_dir="$MNT/efi/aelum/$install_id"

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
esp_uuid="$(blkid -o value -s UUID "$ESP")"
check "fstab mounts the ESP at /efi as vfat" fstab_has "^UUID=$esp_uuid[[:space:]]+/efi[[:space:]]+vfat"
check "fstab bind-mounts this install's boot dir at /boot" \
    fstab_has "^/efi/aelum/$install_id[[:space:]]+/boot[[:space:]]+none[[:space:]]+bind"
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

# ── Bootloader (rEFInd) ───────────────────────────────────────────────────────
section "bootloader"
refind_dir="$MNT/efi/EFI/refind"
check "rEFInd binary exists at EFI/refind/refind_x64.efi" test -f "$refind_dir/refind_x64.efi"
conf="$refind_dir/refind.conf"
check "rEFInd config exists at EFI/refind/refind.conf" test -f "$conf"
# Each Aelum install owns a menu fragment under EFI/refind/aelum, keyed by a
# short form of its root filesystem UUID, so two installs can share one ESP.
entry="$refind_dir/aelum/$install_id.conf"
check "rEFInd config includes this install's menu entry (aelum/$install_id.conf)" \
    grep -Eq "^[[:space:]]*include[[:space:]]+aelum/$install_id\\.conf" "$conf"
check "rEFInd menu entry exists at EFI/refind/aelum/$install_id.conf" test -f "$entry"
expected_title="Aelum ($(basename "$ROOT_PART"))"
check "rEFInd menu entry is titled \"$expected_title\"" grep -Fq "menuentry \"$expected_title\"" "$entry"
# Kernel and initramfs live in this install's own directory on the ESP, so a
# second Aelum install cannot overwrite them.
check "rEFInd entry loads this install's kernel (aelum/$install_id)" \
    grep -Eq "^[[:space:]]*loader[[:space:]]+/aelum/$install_id/vmlinuz" "$entry"
check "rEFInd entry loads this install's initramfs (aelum/$install_id)" \
    grep -Eq "^[[:space:]]*initrd[[:space:]]+/aelum/$install_id/initramfs" "$entry"
check "this install's kernel exists on the ESP" compgen -G "$boot_dir/vmlinuz-*" >/dev/null
check "this install's initramfs exists on the ESP" compgen -G "$boot_dir/initramfs-*.img" >/dev/null
check "rEFInd config includes the Aelum theme" grep -Eq '^[[:space:]]*include[[:space:]]+themes/aelum/theme\.conf' "$conf"
theme_dir="$refind_dir/themes/aelum"
check "Aelum theme config exists" test -f "$theme_dir/theme.conf"
check "Aelum theme background exists" test -f "$theme_dir/background.png"
check "Aelum theme font exists" test -f "$theme_dir/font.png"
check "Aelum theme has a 2x font (4K/HiDPI)" test -f "$theme_dir/font-2x.png"
check "Aelum theme icon exists" test -f "$theme_dir/icons/os_arch.png"
check "Aelum theme selection highlight exists" test -f "$theme_dir/selection_big.png"
check "rEFInd config sets a menu timeout" grep -Eq '^[[:space:]]*timeout[[:space:]]+[0-9]+' "$conf"
check "rEFInd sets an explicit or maximum display resolution" grep -Eq '^[[:space:]]*resolution[[:space:]]+([0-9]+[[:space:]]+[0-9]+|max)' "$conf"
# Without this, rEFInd switches to text mode and prints "Booting ..." and
# "Using load options ..." over a black screen before the kernel starts.
check "rEFInd launches Linux in graphics mode (no pre-launch text)" \
    grep -Eq '^[[:space:]]*use_graphics_for[[:space:]]+.*linux' "$conf"
# rEFInd tokenizes refind.conf: unquoted options would be truncated to the first
# word (dropping rw/splash and rewriting slashes), so require the quoted form.
check "rEFInd entry options are quoted" grep -Eq '^[[:space:]]*options[[:space:]]+"' "$entry"
# The Aelum stanza's kernel command line (indented `options` line).
opts="$(grep -E '^[[:space:]]*options[[:space:]]+' "$entry" 2>/dev/null | head -1)"
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
# NVRAM registration is best-effort during install, but in the UEFI test VM it
# should have succeeded: the firmware needs an entry to launch rEFInd on boot.
if command -v efibootmgr >/dev/null 2>&1; then
    check "firmware boot entry points at rEFInd" has "$(efibootmgr -v 2>/dev/null)" '\\EFI\\refind\\refind_x64\.efi'
fi

# ── Reused ESP (dualboot) ─────────────────────────────────────────────────────
# REUSE_ESP=1 pre-creates the ESP with a marker and stale memtest86+ binaries
# before the install. If the installer formatted the ESP (the bug this scenario
# guards against), the marker is gone.
if [ "$REUSE_ESP" = "1" ]; then
    section "reused ESP (dualboot)"
    check "pre-existing ESP marker survived (ESP was not formatted)" test -f "$MNT/efi/dualboot-marker.txt"
    check "pre-existing ESP marker contents intact" grep -qx 'aelum-dualboot-marker' "$MNT/efi/dualboot-marker.txt"
    check "pre-existing memtest was backed up" test -f "$MNT/efi/memtest86+/memtest86x64.efi.aelum-backup"
    check "packaged memtest was installed" test -f "$MNT/efi/memtest86+/memtest86x64.efi"
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
