#!/usr/bin/env bash
#
# verify-installed.sh — independently inspect an Aelum install on the target
# disk. It runs inside the live ISO (as root) after test-install.sh performs an
# install. It never calls the installer, so it validates the on-disk result
# rather than the code that produced it.
#
# Inputs (environment, supplied by test-install.sh):
#   FILESYSTEM  ext4 | btrfs   filesystem on the root partition
#   LUKS        0 | 1          root partition is LUKS2-encrypted
#   LUKS_PASS   LUKS2 passphrase (LUKS=1)
#   LVM         0 | 1          root (and ext4 home) live on LVM logical volumes
#   DISK_PATH   target disk inside the guest (default /dev/vda)
#
# The installed system is mounted read-only; every check is reported and the
# script exits non-zero if any check fails.

set -u

FILESYSTEM="${FILESYSTEM:-btrfs}"
LUKS="${LUKS:-0}"
LUKS_PASS="${LUKS_PASS:-aelum-luks}"
LVM="${LVM:-0}"
DISK_PATH="${DISK_PATH:-/dev/vda}"

MNT=/mnt
ESP="${DISK_PATH}1"
ROOT_PART="${DISK_PATH}2"
# Reuse the installer's mapper name (shared.LuksMapperName).
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
# pkg_installed "<name>" — query the installed system's own package database.
pkg_installed() { pacman -Q --dbpath "$MNT/var/lib/pacman" "$1" >/dev/null 2>&1; }
# not <command...> — invert a command's exit status, for "must not be there" checks.
not() { if "$@" >/dev/null 2>&1; then return 1; else return 0; fi; }

cleanup() {
    umount -R "$MNT" 2>/dev/null
    # Deactivate the group before closing the mapper: an active LV holds the
    # encrypted device open.
    if [ "$LVM" = 1 ] && [ -n "${VG_NAME:-}" ]; then
        vgchange -an "$VG_NAME" 2>/dev/null
    fi
    [ "$LUKS" = 1 ] && cryptsetup close "$LUKS_MAPPER" 2>/dev/null
    return 0
}
trap cleanup EXIT

echo "Verifying install on $DISK_PATH (fs=$FILESYSTEM luks=$LUKS lvm=$LVM)"

# ── Open LUKS ─────────────────────────────────────────────────────────────────
rootdev="$ROOT_PART"
if [ "$LUKS" = 1 ]; then
    # Clear any mapper left open by a failed cleanup before reopening it.
    cryptsetup close "$LUKS_MAPPER" 2>/dev/null || true
    if ! printf '%s' "$LUKS_PASS" | cryptsetup open --type luks2 "$ROOT_PART" "$LUKS_MAPPER" 2>/dev/null; then
        echo "FATAL: could not open LUKS2 on $ROOT_PART"
        exit 1
    fi
    udevadm settle 2>/dev/null || true
    rootdev="/dev/mapper/$LUKS_MAPPER"
fi

# ── Activate LVM ──────────────────────────────────────────────────────────────
# The volume group name is derived from the PV (never hard-coded), and the root
# device becomes the root LV. This mirrors what the initramfs does at boot.
if [ "$LVM" = 1 ]; then
    vgchange -ay 2>/dev/null
    VG_NAME="$(pvs --noheadings -o vg_name "$rootdev" 2>/dev/null | tr -d ' ')"
    if [ -z "$VG_NAME" ]; then
        echo "FATAL: $rootdev is not an LVM physical volume"
        exit 1
    fi
    rootdev="/dev/$VG_NAME/root"
    home_lv="/dev/$VG_NAME/home"
fi

# ── Mount the installed system read-only ──────────────────────────────────────
mkdir -p "$MNT"
if [ "$FILESYSTEM" = btrfs ]; then
    # No subvol=: the system is whatever the filesystem's default subvolume is.
    # That is the contract the installer writes, and the pointer a rollback moves.
    mount -o ro "$rootdev" "$MNT" || { echo "FATAL: could not mount the default subvolume of $rootdev"; exit 1; }
    # The history is a separate mount, exactly as the installed system mounts it: a
    # snapshot never contains the subvolumes inside its parent, so the live root only
    # has an empty placeholder for this to land on.
    history_subvol="$(btrfs subvolume list "$MNT" 2>/dev/null | awk '$NF ~ /(^|\/)\.snapshots$/ { print $NF; exit }')"
    if [ -n "$history_subvol" ]; then
        mount -o ro,subvol="$history_subvol" "$rootdev" "$MNT/.snapshots" \
            || echo "  note - could not mount $history_subvol; snapshot checks may fail"
    fi
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

# ── fstab ─────────────────────────────────────────────────────────────────────
section "fstab"
check "fstab exists and is non-empty" [ -s "$MNT/etc/fstab" ]
check "fstab mounts / as $FILESYSTEM" fstab_has "^UUID=[0-9a-fA-F-]+[[:space:]]+/[[:space:]]+$FILESYSTEM"
esp_uuid="$(blkid -o value -s UUID "$ESP")"
check "fstab mounts the ESP at /efi as vfat" fstab_has "^UUID=$esp_uuid[[:space:]]+/efi[[:space:]]+vfat"
check "fstab bind-mounts this install's boot dir at /boot" \
    fstab_has "^/efi/aelum/$install_id[[:space:]]+/boot[[:space:]]+none[[:space:]]+bind"
check "fstab references the root filesystem UUID" fstab_has "$root_uuid"
if [ "$FILESYSTEM" = btrfs ]; then
    check "fstab mounts /home as the @home subvolume" fstab_has "^UUID=$root_uuid[[:space:]]+/home[[:space:]]+btrfs.*subvol=@home"
    # The root mount names no subvolume: the boot follows the filesystem's default
    # subvolume, and a rollback moves that pointer. A pinned subvol= here would make
    # the rollback change a state nothing mounts.
    check "fstab mounts / without naming a subvolume" \
        not fstab_has "^UUID=$root_uuid[[:space:]]+/[[:space:]]+btrfs.*subvol="
    # Without this mount the restored system has an empty .snapshots and snapper
    # stops working in it.
    check "fstab mounts the snapshot history at /.snapshots" \
        fstab_has "^UUID=$root_uuid[[:space:]]+/.snapshots[[:space:]]+btrfs.*subvol=.*\.snapshots"
elif [ "$LVM" = 1 ]; then
    # ext4 + LVM keeps /home on its own logical volume.
    home_uuid="$(blkid -o value -s UUID "$home_lv")"
    check "fstab mounts the home LV at /home" fstab_has "^UUID=$home_uuid[[:space:]]+/home[[:space:]]+ext4"
else
    check "fstab has no /home entry (ext4)" fstab_not /home
fi

# ── LVM ───────────────────────────────────────────────────────────────────────
if [ "$LVM" = 1 ]; then
    section "lvm"
    echo "  VG: $VG_NAME"
    check "volume group exists" vgs "$VG_NAME"
    check "root logical volume exists" lvs "$VG_NAME/root"
    if [ "$FILESYSTEM" = ext4 ]; then
        check "home logical volume exists (ext4)" lvs "$VG_NAME/home"
    fi
    check "fstab references the root LV filesystem UUID" fstab_has "$root_uuid"
fi

# ── initramfs hooks ───────────────────────────────────────────────────────────
section "initramfs"
hooks="$(grep -E '^HOOKS=' "$MNT/etc/mkinitcpio.conf" 2>/dev/null)"
echo "  HOOKS: $hooks"
if [ "$LUKS" = 1 ]; then
    check "HOOKS include an encrypt hook" has "$hooks" '(^|[^[:alnum:]_])(sd-encrypt|encrypt)([^[:alnum:]_]|$)'
fi
if [ "$LVM" = 1 ]; then
    check "HOOKS include the lvm2 hook" has "$hooks" '(^|[^[:alnum:]_])lvm2([^[:alnum:]_]|$)'
    if [ "$LUKS" = 1 ]; then
        # LUKS sits below LVM: sd-encrypt must run before lvm2.
        check "HOOKS order is sd-encrypt then lvm2" \
            bash -c '[[ "$1" =~ sd-encrypt.*lvm2 ]]' _ "$hooks"
    fi
fi

# ── Bootloader (rEFInd) ───────────────────────────────────────────────────────
section "bootloader"
refind_dir="$MNT/efi/EFI/refind"
check "rEFInd binary exists at EFI/refind/refind_x64.efi" test -f "$refind_dir/refind_x64.efi"
conf="$refind_dir/refind.conf"
check "rEFInd config exists at EFI/refind/refind.conf" test -f "$conf"
# Each Aelum install owns a menu fragment under EFI/refind/aelum, keyed by a
# short form of its root filesystem UUID, so its kernel and menu entry stay
# isolated from any other install.
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
# rEFInd falls back to its stock artwork for any name missing here, so require
# the full themed set: OS tiles, tools/functions, volume badges, and the
# arrow/mouse/boot chrome.
for icon in \
    os_arch os_artful os_bionic os_centos os_chakra os_chrome os_clover \
    os_crunchbang os_debian os_devuan os_elementary os_endeavouros os_fedora \
    os_freebsd os_frugalware os_gentoo os_gummiboot os_haiku os_hwtest \
    os_kubuntu os_legacy os_linux os_linuxmint os_lubuntu os_mac os_mageia \
    os_mandriva os_manjaro os_netbsd os_network os_opensuse os_redhat \
    os_refind os_refit os_slackware os_suse os_systemd os_trusty os_ubuntu \
    os_uefi os_unknown os_void os_win os_win8 os_xenial os_xubuntu os_zesty \
    os_ventoy os_vtoyefi \
    func_about func_bootorder func_csr_rotate func_exit func_firmware \
    func_hidden func_install func_reset func_shutdown \
    tool_apple_rescue tool_fwupdate tool_memtest tool_mok_tool tool_netboot \
    tool_part tool_rescue tool_shell tool_windows_rescue \
    vol_efi vol_external vol_internal vol_net vol_optical \
    arrow_left arrow_right mouse boot_linux boot_win transparent; do
    check "Aelum theme icon $icon.png exists" test -f "$theme_dir/icons/$icon.png"
done
check "Aelum and generic Linux icons are distinct" \
    [ "$(md5sum "$theme_dir/icons/os_arch.png" | cut -d' ' -f1)" != "$(md5sum "$theme_dir/icons/os_linux.png" | cut -d' ' -f1)" ]
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
check "entry roots at the root filesystem UUID" has "$opts" 'root=UUID='
if [ "$LUKS" = 1 ]; then
    check "entry has rd.luks.name=" has "$opts" 'rd\.luks\.name='
else
    check "entry has no rd.luks.name= (no LUKS)" hasnt "$opts" 'rd\.luks\.name='
fi
if [ "$LVM" = 1 ]; then
    # The root is selected by filesystem UUID; a device-mapper path would break
    # if the volume group were ever renamed.
    check "entry has no LVM device-mapper path" hasnt "$opts" '/dev/mapper/'
    entry_root="$(printf '%s' "$opts" | sed -nE 's/.*root=UUID=([^ "]+).*/\1/p')"
    check "entry root UUID is the root LV filesystem UUID" [ "$entry_root" = "$root_uuid" ]
fi
if [ "$FILESYSTEM" = btrfs ]; then
    # No rootflags= at all: the entry must let the kernel mount the filesystem's
    # default subvolume, so a rollback changes what boots without this entry ever
    # being rewritten.
    check "entry names no subvolume (btrfs)" hasnt "$opts" 'rootflags='
else
    check "entry has no btrfs rootflags (ext4)" hasnt "$opts" 'rootflags=subvol='
fi
# NVRAM registration is best-effort during install, but in the UEFI test VM it
# should have succeeded: the firmware needs an entry to launch rEFInd on boot.
if command -v efibootmgr >/dev/null 2>&1; then
    check "firmware boot entry points at rEFInd" has "$(efibootmgr -v 2>/dev/null)" '\\EFI\\refind\\refind_x64\.efi'
fi

# ── Installed packages ────────────────────────────────────────────────────────
section "installed system"
check "system is populated (/etc/os-release present)" [ -s "$MNT/etc/os-release" ]

# The resolver has to belong to the boot, not to the root it was installed into.
# A snapshot boot mounts a read-only subvolume as /, and NetworkManager updates
# /etc/resolv.conf by creating a temp file in the same directory and renaming it
# over - which such a root refuses. Linked into /run (a tmpfs in every boot, and
# the file NetworkManager always writes), the factory snapshot and every other
# snapshot resolve on the network they are actually running on.
check "resolver is a link into /run, not a file inside the root" \
    bash -c '[ -L "$1/etc/resolv.conf" ]' _ "$MNT"
check "the resolver link points at NetworkManager's runtime resolv.conf" \
    bash -c '[ "$(readlink "$1/etc/resolv.conf")" = "/run/NetworkManager/resolv.conf" ]' _ "$MNT"

# ── Snapshots (snapper) ───────────────────────────────────────────────────────
# The installer configures snapper for the btrfs layout only: separate
# subvolumes are what make a snapshot of @ cheap, and an ext4 install has no
# subvolume to snapshot, so it gets neither snapper nor btrfs-assistant.
if [ "$FILESYSTEM" = btrfs ]; then
    section "snapshots (snapper)"

    check "snapper is installed" pkg_installed snapper
    check "btrfs-assistant is installed" pkg_installed btrfs-assistant

    config_dir="$MNT/etc/snapper/configs"
    names="$(ls -1 "$config_dir" 2>/dev/null)"
    echo "  configs: $(printf '%s' "$names" | tr '\n' ' ')"
    check "exactly two snapper configs" [ "$(grep -c . <<<"$names")" -eq 2 ]

    # The qgroups the installer gives each config (configure.snapperRootQGroup /
    # snapperHomeQGroup): level-1 ids, which is the level snapper reserves for
    # aggregates, one per config.
    declare -A cfg_qgroup=([root]="1/0" [home]="1/1")
    for cfg in root home; do
        case "$cfg" in
            root) subvol="@";   subvol_re='^SUBVOLUME="/"$'   ;;
            home) subvol="@home"; subvol_re='^SUBVOLUME="/home"$' ;;
        esac
        content="$(cat "$config_dir/$cfg" 2>/dev/null)"
        check "config $cfg snapshots $subvol" has "$content" "$subvol_re"
        check "config $cfg is a btrfs config" has "$content" '^FSTYPE="btrfs"$'
        # Timeline snapshots are off for the root, as they are in openSUSE's own
        # default setup: the history of a system is the pairs its transactions take
        # and the snapshots a rollback leaves, not a timer that fired. It also keeps
        # a snapshot boot from adding to the history it booted from. Cleanup stays
        # on so a user who turns the timeline on gets one that stays bounded.
        check "config $cfg takes no timeline snapshots" has "$content" '^TIMELINE_CREATE="no"$'
        check "config $cfg still cleans timeline history" has "$content" '^TIMELINE_CLEANUP="yes"$'
        check "config $cfg cleans pre/post pairs by count" has "$content" '^NUMBER_CLEANUP="yes"$'
        # Every limit is a range. snapper skips its space-aware cleanup when a limit
        # is degenerated (min == max, client/utils/Range.h), so single numbers here
        # would make SPACE_LIMIT / FREE_LIMIT decorative.
        for key in NUMBER_LIMIT NUMBER_LIMIT_IMPORTANT TIMELINE_LIMIT_HOURLY TIMELINE_LIMIT_DAILY \
                   TIMELINE_LIMIT_WEEKLY TIMELINE_LIMIT_MONTHLY TIMELINE_LIMIT_YEARLY; do
            range_re="^${key}=\"[0-9]+-[0-9]+\"$"
            check "config $cfg bounds $key with a range" grep -qE "$range_re" "$config_dir/$cfg"
        done
        # QGROUP is the aggregate snapper measures a config's snapshots against.
        # Quotas alone are not enough: prepare_quota throws "qgroup not set" and the
        # cleanup falls back to counting. One group per config, because SPACE_LIMIT
        # belongs to a config - a shared group would let @home snapshots delete the
        # system's restore points.
        check "config $cfg names its qgroup" has "$content" "^QGROUP=\"${cfg_qgroup[$cfg]}\"$"
    done
    # @home shares the filesystem with @, so its history is the smaller one; and no
    # config may keep fewer important snapshots than ordinary ones, or a marked
    # snapshot would be cleaned before an unmarked one.
    limit_max() { sed -nE "s/^$2=\"[0-9]+-([0-9]+)\"$/\1/p" "$config_dir/$1" | head -1; }
    root_max="$(limit_max root NUMBER_LIMIT)"; home_max="$(limit_max home NUMBER_LIMIT)"
    echo "  limits: root NUMBER_LIMIT max=${root_max:-?}  home max=${home_max:-?}"
    check "the home history is smaller than the system's (same filesystem)" \
        bash -c '[[ -n "$1" && -n "$2" && "$2" -lt "$1" ]]' _ "$root_max" "$home_max"
    for cfg in root home; do
        ordinary="$(limit_max "$cfg" NUMBER_LIMIT)"
        important="$(limit_max "$cfg" NUMBER_LIMIT_IMPORTANT)"
        check "config $cfg keeps at least as many important ($important) as ordinary ($ordinary) snapshots" \
            bash -c '[[ -n "$1" && -n "$2" && "$2" -ge "$1" ]]' _ "$ordinary" "$important"
    done

    check "SNAPPER_CONFIGS lists both configs" \
        grep -Eq '^SNAPPER_CONFIGS="root home"' "$MNT/etc/conf.d/snapper"

    # Snapper refuses to work with a .snapshots that is not a subvolume, and a
    # plain directory would be copied into every snapshot of its parent.
    # Match on the parent subvolume id, not on the spelling of the path: btrfs
    # prints a nested subvolume relative to the mounted one (.snapshots) and one
    # it cannot see from this namespace top-level-relative (@home/.snapshots).
    subvols="$(btrfs subvolume list "$MNT" 2>/dev/null)"
    subvol_id() {
        sed -nE "s/^ID ([0-9]+) gen [0-9]+ top level [0-9]+ path $1$/\1/p" <<<"$subvols" | head -1
    }
    owns_snapshots() {
        local id
        id="$(subvol_id "$1")"
        [ -n "$id" ] && grep -qE "^ID [0-9]+ gen [0-9]+ top level $id path [^ ]*\.snapshots$" <<<"$subvols"
    }
    check "@ has its own .snapshots subvolume" owns_snapshots '@'
    check "@home has its own .snapshots subvolume" owns_snapshots '@home'
    check "only the snapshotted subvolumes have a .snapshots" \
        [ "$(grep -cE 'path [^ ]*\.snapshots$' <<<"$subvols")" -eq 2 ]

    echo "  quotas:"; btrfs quota status "$MNT" 2>/dev/null | sed 's/^/    /'
    check "btrfs quotas are enabled (snapper space limits)" \
        btrfs quota status --is-enabled "$MNT"
    # The groups the configs name must exist, or every cleanup says "quota not
    # working" and the limits never apply. A plain show lists them (with their
    # "<0 member qgroups>" placeholder: snapper fills a group when it first runs a
    # cleanup, not when the group is created). The path-filtering options do not:
    # -F lists only the qgroups of the given subvolume, which hides a level-1 group
    # that has no members yet.
    qgroups="$(btrfs qgroup show "$MNT" 2>/dev/null | awk '{ print $1 }')"
    echo "  qgroups: $(printf '%s' "$qgroups" | tr '\n' ' ')"
    check "the qgroup the root config names exists" grep -qx '1/0' <<<"$qgroups"
    check "the qgroup the home config names exists" grep -qx '1/1' <<<"$qgroups"

    for unit in snapperd snapper-timeline.timer snapper-cleanup.timer; do
        check "$unit is enabled" systemctl --root="$MNT" is-enabled "$unit"
    done

    # The file checks above say what was written; these say it works. Snapper
    # lists only the configs named in SNAPPER_CONFIGS, and with --root it reads
    # and opens the installed system's own configs and subvolumes from here.
    list_configs="$(snapper --no-dbus --root="$MNT" list-configs 2>&1)"
    check "snapper loads both configs of the installed system" \
        bash -c '[[ "$1" == *"root"* && "$1" == *"/home"* ]]' _ "$list_configs"
    check "snapper reads the root config's snapshot store" \
        snapper --no-dbus --root="$MNT" -c root list

    # ── The layout snapper's rollback needs ───────────────────────────────
    # snapper names the running system by the filesystem's default subvolume and only
    # accepts it as one of its own numbered snapshots (Btrfs::getDefault -> idToNum).
    # The installer installs into .snapshots/1/snapshot under @ and points the default
    # subvolume at it, which is the sequence snapper's own installation-helper runs.
    # Without this, `snapper rollback` refuses to run on the layout at all.
    default_subvol="$(btrfs subvolume get-default "$MNT" 2>/dev/null)"
    echo "  default subvolume: $default_subvol"
    check "the default subvolume is a numbered snapshot" \
        has "$default_subvol" 'path [^ ]*\.snapshots/[0-9]+/snapshot$'
    check "the history is mounted where the live root can read it" \
        findmnt -n -o SOURCE "$MNT/.snapshots"
    check "the snapshot the system was installed into is described" \
        grep -q 'first root filesystem' "$MNT/.snapshots"/[0-9]*/info.xml
    check "the state this installer produced is snapshotted" \
        grep -q 'after installation' "$MNT/.snapshots"/[0-9]*/info.xml

    # That snapshot has to be the *finished* system, because it is the state a user
    # restores to and the one the snapshot menu offers first. An enable step that
    # runs after it is simply absent from it: measured on a real install, the
    # factory snapshot had no display-manager.service and no NetworkManager, and
    # booting it came up at a text login instead of the greeter.
    factory_info="$(grep -l 'after installation' "$MNT/.snapshots"/[0-9]*/info.xml 2>/dev/null | head -1)"
    factory=""
    [ -n "$factory_info" ] && factory="$(dirname "$factory_info")/snapshot"
    check "the factory snapshot is a tree on disk" test -d "$factory"
    check "the factory snapshot boots the greeter" \
        test -e "$factory/etc/systemd/system/display-manager.service"
    check "the factory snapshot has NetworkManager enabled" \
        test -e "$factory/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
    # The same ordering, one step further: a snapshot boots the unit files the
    # snapshot contains, so anything a snapshot boot needs has to be inside it.
    check "the factory snapshot can rebuild its own boot menu" \
        test -x "$factory/usr/local/bin/aelum-refind-snapshots"
    check "the factory snapshot has the writable state dirs a snapshot boot needs" \
        test -x "$factory/usr/lib/systemd/system-generators/aelum-snapshot-state"

    # ── Snapshots around pacman transactions ───────────────────────────────
    # A pre/post pair is the undo path for an update, so both halves must exist,
    # be ordered around the transaction, and be skipped when snapper is not there.
    pre_hook="$MNT/etc/pacman.d/hooks/90-aelum-snapper-pre.hook"
    post_hook="$MNT/etc/pacman.d/hooks/91-aelum-snapper-post.hook"
    important_hook="$MNT/etc/pacman.d/hooks/92-aelum-snapper-important-post.hook"
    for hook in "$pre_hook" "$post_hook" "$important_hook"; do
        check "pacman hook $(basename "$hook") exists" [ -f "$hook" ]
        check "$(basename "$hook") is skipped when snapper is not installed" \
            grep -Eq '^Depends = snapper$' "$hook"
        # pacman allows exactly one Type per hook: two declarations make it warn
        # and the last one silently wins.
        check "$(basename "$hook") declares exactly one Type" \
            [ "$(grep -c '^Type = ' "$hook")" = "1" ]
        check "$(basename "$hook") triggers on Type = Package" \
            grep -Eq '^Type = Package$' "$hook"
        # --no-dbus: the default path asks snapperd, and a masked or crashed
        # snapperd would drop the undo path silently - no message, no log, and an
        # install that reported success. The hooks run as root.
        check "$(basename "$hook") runs snapper directly, not through snapperd" \
            grep -Eq 'snapper --no-dbus -c root' "$hook"
    done
    check "the pre and post hooks trigger on every package transaction" \
        bash -c 'grep -qE "^Target = \*$" "$1" && grep -qE "^Target = \*$" "$2"' _ "$pre_hook" "$post_hook"
    check "the pre hook snapshots @ before the transaction" \
        grep -Eq '^Exec = .* -c root create -t pre' "$pre_hook"
    check "the post hook pairs with the pre snapshot by number" \
        grep -Eq '^Exec = .*--pre-number' "$post_hook"
    # A transaction killed between its two hooks leaves a number behind. Without
    # clearing it the next transaction pairs with it, and the pair's diff spans two
    # transactions.
    check "the pre hook clears the state of an interrupted transaction" \
        grep -Eq '^Exec = .*rm -f /run/aelum-snapper/pacman\.pre /run/aelum-snapper/pacman\.pair' "$pre_hook"
    # The third half marks the pair the other two made: kernel, glibc, systemd,
    # mkinitcpio, boot and display-driver transactions go in the important quota so
    # a run of unrelated updates cannot evict the state a rollback is for.
    check "the important hook marks the pair it did not create" \
        grep -Eq '^Exec = .*modify -u important=yes' "$important_hook"
    check "the important hook triggers only on system-changing packages" \
        bash -c '! grep -qE "^Target = \*$" "$1" && grep -qE "^Target = [^#]*linux-lts[^#]*mkinitcpio[^#]*glibc[^#]*systemd" "$1"' _ "$important_hook"

    # ── Snapshots in the boot menu ─────────────────────────────────────────
    # rEFInd shows exactly the stanzas its config contains, so something has to own
    # a generator, a trigger, and a fragment to write. The installer runs the
    # generator itself at the end of the install (against the target, with --root),
    # so the fragment is already filled here: an install whose first boot shows no
    # recovery entry is a menu that was written one boot too late.
    generator="$MNT/usr/local/bin/aelum-refind-snapshots"
    plugin="$MNT/usr/lib/snapper/plugins/10-aelum-refind-snapshots"
    check "snapshot menu generator exists and is executable" [ -x "$generator" ]
    check "generator writes this install's snapshot menu fragment" \
        grep -qF 'EFI/refind/aelum/$install_id-snapshots.conf' "$generator"
    check "generator copies the boot options from the install's own entry" \
        grep -qF 'rootflags=subvol=$subvol_base/$1/snapshot' "$generator"
    check "generator derives the history from the default subvolume" \
        grep -qF 'btrfs subvolume get-default "$root"' "$generator"
    check "generator can be run against a system it is not booted in" \
        grep -qF -- '--root)' "$generator"
    check "generator leaves the menu alone when the history is not mounted" \
        grep -qF 'findmnt -n -o SOURCE "$snapshot_dir"' "$generator"
    check "generator lists the snapshots inside one menu entry" \
        grep -qF 'submenuentry' "$generator"
    check "generator boots the snapshot taken before a change" \
        grep -qF '[ "$type" = pre ]' "$generator"
    check "generator prefers a snapshot marked important over a newer one" \
        grep -qF '[ "$important" = yes ]' "$generator"
    # A timeline snapshot is a timer that fired, not a state anyone chose to be
    # able to return to: it stays in the submenu and never becomes the entry.
    check "generator never makes a timeline snapshot the recovery entry" \
        grep -qF 'case "$cleanup" in timeline) continue ;; esac' "$generator"
    # The default subvolume is what this install's own entry boots and what a
    # rollback moves; offering it would offer the user the state they are in.
    check "generator does not offer the snapshot that is the current system" \
        grep -qF 'if [ "$number" = "$default_number" ]; then' "$generator"
    check "snapper plugin exists and is executable" [ -x "$plugin" ]
    # Not only create and delete: a transactional rollback changes the default
    # subvolume and creates no snapshot, and snapper modify rewrites the description
    # and important= marking a menu title is built from.
    check "snapper plugin reacts to every change the menu shows" \
        grep -qF 'create-snapshot-post|delete-snapshot-post|set-default-snapshot-post|modify-snapshot-post|set-read-only-post' "$plugin"
    check "snapper plugin only follows the root config" grep -qF '[ "$2" = "/" ]' "$plugin"
    check "aelum-refind-snapshots.service is enabled" \
        systemctl --root="$MNT" is-enabled aelum-refind-snapshots.service
    check "snapshot menu unit runs the generator" \
        grep -qF 'ExecStart=/usr/local/bin/aelum-refind-snapshots' \
            "$MNT/etc/systemd/system/aelum-refind-snapshots.service"

    snapshot_entry="$refind_dir/aelum/$install_id-snapshots.conf"
    check "rEFInd snapshot menu fragment exists" [ -f "$snapshot_entry" ]
    check "the menu is written before this install's first boot" \
        grep -Eq '^[[:space:]]*menuentry ' "$snapshot_entry"
    check "the menu offers the state this installer produced" \
        grep -q 'after installation' "$snapshot_entry"
    # Every snapshot entry has to name a subvolume that is really in the filesystem
    # tree. A history path derived from the wrong root (".snapshots/2/snapshot"
    # instead of "@/.snapshots/2/snapshot") reads fine, is listed in the menu, and
    # boots nothing: the kernel cannot mount a root that is not there. btrfs reports
    # these paths from the tree root whatever is mounted, so this is the same list
    # the entries are naming paths in.
    subvols=$(btrfs subvolume list "$MNT" 2>/dev/null | awk '{ print $NF }')
    entry_roots=$(grep -oE 'rootflags=subvol=[^ "]+' "$snapshot_entry" | sed 's/^rootflags=subvol=//')
    bad_roots=""
    for want in $entry_roots; do
        grep -qxF "$want" <<<"$subvols" || bad_roots="$bad_roots $want"
    done
    if [ -z "$entry_roots" ]; then
        bad "no snapshot entry names a root subvolume"
    elif [ -n "$bad_roots" ]; then
        bad "snapshot entries name subvolumes that are not in the filesystem tree:$bad_roots"
    else
        ok "every snapshot entry names a subvolume that exists ($(printf '%s\n' "$entry_roots" | wc -l) of them)"
    fi

    check "rEFInd config includes the snapshot menu fragment" \
        grep -Eq "^[[:space:]]*include[[:space:]]+aelum/$install_id-snapshots\.conf" "$conf"
    check "the live system is still the default selection" \
        grep -Eq '^[[:space:]]*default_selection[[:space:]]+"' "$conf"
    # …and the menu does not offer it back: the entry above already boots it, and
    # a snapshot listed here is meant to be a state to go *back to*.
    default_root="$(printf '%s' "$default_subvol" | sed -n 's/.*path //p')"
    if [ -n "$default_root" ] && grep -qF "rootflags=subvol=$default_root" "$snapshot_entry"; then
        bad "the snapshot menu offers the subvolume the system already is ($default_root)"
    else
        ok "the snapshot menu does not offer the current system ($default_root)"
    fi

    # An entry and its snapshots have to be listed together, in that order: a
    # plain filename sort would put "-snapshots.conf" before ".conf".
    entry_line=$(grep -En "^[[:space:]]*include[[:space:]]+aelum/$install_id\.conf" \
        "$conf" | head -n1 | cut -d: -f1)
    snapshot_line=$(grep -En "^[[:space:]]*include[[:space:]]+aelum/$install_id-snapshots\.conf" \
        "$conf" | head -n1 | cut -d: -f1)
    check "the snapshot menu is listed after the system it belongs to" \
        bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$entry_line" "$snapshot_line"

    # The generated entry points at the theme's history glyph. If the theme does
    # not ship it, the menu shows a fallback icon and snapshots look like systems.
    check "the theme ships the snapshot icon the menu uses" \
        [ -f "$refind_dir/themes/aelum/icons/os_snapshot.png" ]

    # ── A snapshot boot reaches the greeter ────────────────────────────────
    # A snapshot entry boots a read-only btrfs subvolume as /. systemd-logind's
    # state directories are inside that root, and without them logind fails at
    # STATE_DIRECTORY, hits its start limit and the boot lands in a text login -
    # a recovery entry a user cannot use. The installer writes a systemd generator
    # that emits a tmpfs mount for each of them, so a snapshot boot gets back the
    # directories it lost and an ordinary boot gets nothing.
    state_gen="$MNT/usr/lib/systemd/system-generators/aelum-snapshot-state"
    check "snapshot state generator exists and is executable" [ -x "$state_gen" ]
    check "state generator is a systemd generator (writes units into the directory it is given)" \
        grep -qF 'gen_dir=${1:-}' "$state_gen"
    # The detector, which is the definition of the feature and not a guess at it:
    # the subvolume the root is on, against the one the system boots by default.
    # A writability probe cannot be used here - measured on a real boot, the root
    # is mounted read-only for the whole generator phase of an ordinary boot too.
    check "state generator reads the subvolume the root is on" \
        bash -c 'grep -qF "/proc/self/mountinfo" "$1" && grep -qF "subvolid=" "$1"' _ "$state_gen"
    check "state generator reads the subvolume the system boots by default" \
        grep -qF 'btrfs subvolume get-default /' "$state_gen"
    check "state generator writes units only when those two differ" \
        grep -qF '[ "$root_subvol" != "$default_subvol" ] || exit 0' "$state_gen"
    check "state generator covers the directories a snapshot boot needs" \
        bash -c 'grep -qF "/var/lib/systemd /var/lib/greeter" "$1"' _ "$state_gen"
    check "state generator emits a tmpfs mount unit" \
        bash -c 'grep -qF "echo \"Type=tmpfs\"" "$1"' _ "$state_gen"
    # A mount unit is started by whatever requires it. Measured on a real snapshot
    # boot: /var/lib/systemd was mounted only because systemd-logind and four other
    # units have RequiresMountsFor= on it, and /var/lib/greeter - which nobody asks
    # for - stayed inactive while tmpfiles.d failed to chmod it. The generator has
    # to do what systemd-fstab-generator does and link its units in.
    check "state generator links its mounts into local-fs.target.requires" \
        bash -c 'grep -qF "local-fs.target.requires" "$1" && grep -qF "ln -sf" "$1"' _ "$state_gen"
    # The window a fstab mount gets, plus the unit this exists for: ordered after
    # the mount it lands the tmpfs before local-fs.target and therefore before
    # systemd-logind starts.
    check "state generator orders the mount before local-fs.target and logind" \
        grep -qF 'Before=local-fs.target systemd-logind.service' "$state_gen"
    # Measured, not assumed: ConditionPathIsReadWrite=!/ is unmet in a real
    # snapshot boot, because a btrfs read-only subvolume mounted with rw looks
    # read-write to the mount table. Using it would silently turn this off.
    check "state generator does not decide with ConditionPathIsReadWrite" \
        not bash -c 'grep -qE "^[[:space:]]*[^#]*ConditionPathIsReadWrite" "$1"' _ "$state_gen"
    # Also measured: systemd passes a generator three arguments, and a bare $2
    # under set -u failed the script on every boot - the same as having no
    # generator. And ": > file" is a redirection on a special builtin, which exits
    # the shell when the write fails.
    check "state generator does not read a positional systemd need not pass" \
        not bash -c 'grep -qE "^[[:space:]]*[^#]*\$[23]" "$1"' _ "$state_gen"
    check "state generator does not redirect into a special builtin" \
        not bash -c 'grep -qE "^[[:space:]]*[^#]*: > " "$1"' _ "$state_gen"

    # ── Restoring a booted snapshot ────────────────────────────────────────
    # A user who chose a snapshot in the menu is standing in a previous state; the
    # restore path is what turns "you can go back" into a button. All the pieces
    # are checked: the helper (the rollback, wrapped once), the polkit action its
    # pkexec resolves to (policy refuses, local rule grants only the local active
    # session of an admin - the person who pressed OK), and the desktop prompt
    # (a Quickshell dialog, gated on the boot marker).
    # The helper and the authorization files are root-side and must be inside the
    # factory snapshot - a snapshot runs the binaries and rules it contains.
    restore_helper="$MNT/usr/local/bin/aelum-snapshot-restore"
    polkit_policy="$MNT/usr/share/polkit-1/actions/dev.aelum.snapshot.restore.policy"
    polkit_rules="$MNT/etc/polkit-1/rules.d/aelum-snapshot-restore.rules"
    check "state generator announces the snapshot boot for the prompt" \
        grep -qF '/run/aelum-snapshot-boot' "$state_gen"
    check "snapshot restore helper exists and is executable" [ -x "$restore_helper" ]
    check "restore helper runs the rollback for the booted snapshot" \
        grep -qF 'snapper --no-dbus -c root rollback' "$restore_helper"
    check "restore helper refuses a boot that is not a snapshot" \
        grep -qF '/run/aelum-snapshot-boot' "$restore_helper"
    check "restore helper reboots without rolling back twice (the prompt's last button)" \
        grep -qF -- '--reboot-only)' "$restore_helper"
    check "the OK button's pkexec resolves to a defined polkit action" \
        bash -c 'grep -qF "<action id=\"dev.aelum.snapshot.restore\">" "$1" &&
                 grep -qF "org.freedesktop.policykit.exec.path" "$1" &&
                 grep -qF "/usr/local/bin/aelum-snapshot-restore" "$1"' _ "$polkit_policy"
    check "the polkit policy refuses the action everywhere by default" \
        bash -c 'grep -qF "<allow_any>no</allow_any>" "$1" &&
                 grep -qF "<allow_inactive>no</allow_inactive>" "$1" &&
                 grep -qF "<allow_active>no</allow_active>" "$1"' _ "$polkit_policy"
    check "the grant is scoped to the local active session of an admin" \
        bash -c 'grep -qF "polkit.addRule" "$1" && grep -qF "subject.local" "$1" &&
                 grep -qF "subject.active" "$1" && grep -qF "polkit.user_is_admin" "$1"' _ "$polkit_rules"
    check "the sudo mechanism is gone (no NOPASSWD drop-in for the helper)" \
        [ ! -e "$MNT/etc/sudoers.d/aelum-snapshot-restore" ]
    check "the factory snapshot carries the restore helper" \
        test -x "$factory/usr/local/bin/aelum-snapshot-restore"
    check "the factory snapshot carries the polkit policy and rule" \
        bash -c 'test -f "$1/usr/share/polkit-1/actions/dev.aelum.snapshot.restore.policy" &&
                 test -f "$1/etc/polkit-1/rules.d/aelum-snapshot-restore.rules"' _ "$factory"
    # The prompt is system-side config, not per-user: /etc/xdg/quickshell is a
    # Quickshell config directory for every user, and /etc/systemd/user is a unit
    # load path of every user manager. The prompt therefore belongs to the system
    # - a user created later, or recreated after deletion, has it too - and it is
    # inside the root like the helper: a snapshot boots the prompt it contains.
    prompt_qml="$MNT/etc/xdg/quickshell/aelum-snapshot/shell.qml"
    prompt_unit="$MNT/etc/systemd/user/aelum-snapshot-prompt.service"
    check "the snapshot prompt config is installed system-side" test -f "$prompt_qml"
    check "the prompt runs the installed helper, not a copy of its logic" \
        grep -qF '/usr/local/bin/aelum-snapshot-restore' "$prompt_qml"
    check "the prompt offers CANCEL as well as OK" \
        bash -c 'grep -qF "CANCEL" "$1" && grep -qF "OK" "$1"' _ "$prompt_qml"
    check "the prompt unit exists" test -f "$prompt_unit"
    # The pull-in is per-home on purpose: the wants link is seeded into every
    # real home by /etc/skel (the same way dms.service is started), and there
    # must be no system-side link - the greeter runs a Hyprland session too
    # (dms-greeter --command hyprland), is not in wheel, and did not choose a
    # snapshot, so it must not be asked. Its home is never seeded from skel.
    # The link is asserted with -L, not -e: its target is an absolute path,
    # and in a mounted (not booted) tree that resolves against the live ISO,
    # where the unit does not exist. The link resolving is what the booted
    # system's own session does, and test-snapshot-rollback.sh asserts it there.
    check "the prompt is pulled in by the seeded home, not by the system" \
        bash -c 'test -L "$1/etc/skel/.config/systemd/user/hyprland-session.target.wants/aelum-snapshot-prompt.service" &&
                 [ ! -L "$1/etc/systemd/user/hyprland-session.target.wants/aelum-snapshot-prompt.service" ] &&
                 [ ! -e "$1/var/lib/greeter/.config/systemd" ]' _ "$MNT"
    check "the prompt runs only on a snapshot boot" \
        grep -qF 'ConditionPathExists=/run/aelum-snapshot-boot' "$prompt_unit"
    check "the prompt reads the snapshot number from the boot marker" \
        grep -qF 'EnvironmentFile=/run/aelum-snapshot-boot' "$prompt_unit"
    check "the factory snapshot carries the prompt" \
        bash -c 'test -f "$1/etc/xdg/quickshell/aelum-snapshot/shell.qml" &&
                 test -f "$1/etc/systemd/user/aelum-snapshot-prompt.service" &&
                 test -L "$1/etc/skel/.config/systemd/user/hyprland-session.target.wants/aelum-snapshot-prompt.service"' \
            _ "$factory"

    # ── A transaction pair can actually be taken ───────────────────────────
    # Everything above asserts files. This runs the commands the hooks run, on the
    # installed system, and removes what it made. The failure it is looking for is the
    # one with no message: a pair that never happens - snapperd masked, a config that
    # cannot create, a hook that silently no-ops - leaving an install that reported
    # success and a boot menu that never gains a "Before system update" entry.
    #
    # Every other check reads a read-only mount; this one has to write, so it
    # remounts and puts the read-only mount back.
    section "a transaction pair can be taken"
    if mount -o remount,rw "$MNT" >/dev/null 2>&1 && mount -o remount,rw "$MNT/.snapshots" >/dev/null 2>&1; then
        pre="$(snapper --no-dbus --root="$MNT" -c root create -t pre -p -c number -d verify 2>/dev/null | tail -1)"
        post=""
        [[ "$pre" =~ ^[0-9]+$ ]] && post="$(snapper --no-dbus --root="$MNT" -c root create -t post --pre-number "$pre" -p -c number -d verify 2>/dev/null | tail -1)"
        echo "  pair: pre=${pre:-none} post=${post:-none}"
        check "the installed system can take a pre/post pair" \
            bash -c '[[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]]' _ "$pre" "$post"
        if [[ "$post" =~ ^[0-9]+$ ]]; then
            # The third hook's command, applied to the pair the first two made:
            # marking is what keeps this state out of the ordinary count quota.
            snapper --no-dbus --root="$MNT" -c root modify -u important=yes "$pre" >/dev/null 2>&1
            check "a snapshot of the installed system can be marked important" \
                bash -c 'grep -q "<key>important</key>" "$1/.snapshots/$2/info.xml"' _ "$MNT" "$pre"
            snapper --no-dbus --root="$MNT" -c root delete "$post" "$pre" >/dev/null 2>&1 ||
                echo "  note - the verification pair was left behind; the number algorithm cleans it"
        fi
        mount -o remount,ro "$MNT/.snapshots" >/dev/null 2>&1
        mount -o remount,ro "$MNT" >/dev/null 2>&1
    else
        bad "could not remount the installed system read-write to take a test pair"
    fi
else
    section "snapshots (snapper)"
    check "snapper is not installed (ext4)" not pkg_installed snapper
    check "btrfs-assistant is not installed (ext4)" not pkg_installed btrfs-assistant
    check "no snapper configs (ext4)" [ ! -d "$MNT/etc/snapper/configs" ]
    check "no pacman snapshot hooks (ext4)" \
        bash -c '[[ ! -e "$1" && ! -e "$2" && ! -e "$3" ]]' _ \
            "$MNT/etc/pacman.d/hooks/90-aelum-snapper-pre.hook" \
            "$MNT/etc/pacman.d/hooks/91-aelum-snapper-post.hook" \
            "$MNT/etc/pacman.d/hooks/92-aelum-snapper-important-post.hook"
    check "no snapshot menu generator (ext4)" \
        [ ! -e "$MNT/usr/local/bin/aelum-refind-snapshots" ]
    check "no snapshot menu fragment (ext4)" \
        [ ! -e "$refind_dir/aelum/$install_id-snapshots.conf" ]
    check "no snapshot state mounts (ext4)" \
        [ ! -e "$MNT/usr/lib/systemd/system-generators/aelum-snapshot-state" ]
    check "no snapshot restore helper (ext4)" \
        [ ! -e "$MNT/usr/local/bin/aelum-snapshot-restore" ]
    check "no snapshot restore polkit files (ext4)" \
        bash -c '[[ ! -e "$1" && ! -e "$2" ]]' _ \
            "$MNT/usr/share/polkit-1/actions/dev.aelum.snapshot.restore.policy" \
            "$MNT/etc/polkit-1/rules.d/aelum-snapshot-restore.rules"
    check "no snapshot prompt (ext4)" \
        bash -c '[[ ! -e "$1/etc/xdg/quickshell/aelum-snapshot" && ! -e "$1/etc/systemd/user/aelum-snapshot-prompt.service" ]]' \
            _ "$MNT"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "VERIFY: PASS (fs=$FILESYSTEM luks=$LUKS lvm=$LVM)"
    exit 0
fi
echo "VERIFY: FAIL ($fails check(s) failed)"
exit 1
