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
    check "entry has rootflags=subvol=@ (btrfs)" has "$opts" 'rootflags=subvol=@'
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

    for cfg in root home; do
        case "$cfg" in
            root) subvol="@";   subvol_re='^SUBVOLUME="/"$'   ;;
            home) subvol="@home"; subvol_re='^SUBVOLUME="/home"$' ;;
        esac
        content="$(cat "$config_dir/$cfg" 2>/dev/null)"
        check "config $cfg snapshots $subvol" has "$content" "$subvol_re"
        check "config $cfg is a btrfs config" has "$content" '^FSTYPE="btrfs"$'
        check "config $cfg takes timeline snapshots" has "$content" '^TIMELINE_CREATE="yes"$'
        check "config $cfg keeps timeline history" has "$content" '^TIMELINE_CLEANUP="yes"$'
        check "config $cfg cleans pre/post pairs by count" has "$content" '^NUMBER_CLEANUP="yes"$'
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

    # ── Snapshots around pacman transactions ───────────────────────────────
    # A pre/post pair is the undo path for an update, so both halves must exist,
    # be ordered around the transaction, and be skipped when snapper is not there.
    pre_hook="$MNT/etc/pacman.d/hooks/90-aelum-snapper-pre.hook"
    post_hook="$MNT/etc/pacman.d/hooks/91-aelum-snapper-post.hook"
    for hook in "$pre_hook" "$post_hook"; do
        check "pacman hook $(basename "$hook") exists" [ -f "$hook" ]
        check "$(basename "$hook") is skipped when snapper is not installed" \
            grep -Eq '^Depends = snapper$' "$hook"
        check "$(basename "$hook") triggers on package transactions" \
            grep -Eq '^Target = \*$' "$hook"
        # pacman allows exactly one Type per hook: two declarations make it warn
        # and the last one silently wins.
        check "$(basename "$hook") declares exactly one Type" \
            [ "$(grep -c '^Type = ' "$hook")" = "1" ]
        check "$(basename "$hook") triggers on Type = Package" \
            grep -Eq '^Type = Package$' "$hook"
    done
    check "the pre hook snapshots @ before the transaction" \
        grep -Eq '^Exec = .* -c root create -t pre' "$pre_hook"
    check "the post hook pairs with the pre snapshot by number" \
        grep -Eq '^Exec = .*--pre-number' "$post_hook"

    # ── Snapshots in the boot menu ─────────────────────────────────────────
    # rEFInd shows exactly the stanzas its config contains, so the installed system
    # has to own a generator, a trigger, and a fragment to write. The fragment is
    # empty here (no snapshot has been taken yet); what matters is that the include
    # is in place and the pieces that fill it are executable.
    generator="$MNT/usr/local/bin/aelum-refind-snapshots"
    plugin="$MNT/usr/lib/snapper/plugins/10-aelum-refind-snapshots"
    check "snapshot menu generator exists and is executable" [ -x "$generator" ]
    check "generator writes this install's snapshot menu fragment" \
        grep -qF 'EFI/refind/aelum/$install_id-snapshots.conf' "$generator"
    check "generator copies the boot options from the install's own entry" \
        grep -qF 'rootflags=subvol=$subvol_base/$1/snapshot' "$generator"
    check "generator lists the snapshots inside one menu entry" \
        grep -qF 'submenuentry' "$generator"
    check "generator boots the snapshot taken before a change" \
        grep -qF '[ "$type" = pre ]' "$generator"
    check "snapper plugin exists and is executable" [ -x "$plugin" ]
    check "snapper plugin reacts to snapshot create and delete" \
        grep -qF 'create-snapshot-post|delete-snapshot-post' "$plugin"
    check "snapper plugin only follows the root config" grep -qF '[ "$2" = "/" ]' "$plugin"
    check "aelum-refind-snapshots.service is enabled" \
        systemctl --root="$MNT" is-enabled aelum-refind-snapshots.service
    check "snapshot menu unit runs the generator" \
        grep -qF 'ExecStart=/usr/local/bin/aelum-refind-snapshots' \
            "$MNT/etc/systemd/system/aelum-refind-snapshots.service"

    snapshot_entry="$refind_dir/aelum/$install_id-snapshots.conf"
    check "rEFInd snapshot menu fragment exists" [ -f "$snapshot_entry" ]
    check "rEFInd config includes the snapshot menu fragment" \
        grep -Eq "^[[:space:]]*include[[:space:]]+aelum/$install_id-snapshots\.conf" "$conf"
    check "the live system is still the default selection" \
        grep -Eq '^[[:space:]]*default_selection[[:space:]]+"' "$conf"

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
else
    section "snapshots (snapper)"
    check "snapper is not installed (ext4)" not pkg_installed snapper
    check "btrfs-assistant is not installed (ext4)" not pkg_installed btrfs-assistant
    check "no snapper configs (ext4)" [ ! -d "$MNT/etc/snapper/configs" ]
    check "no pacman snapshot hooks (ext4)" \
        bash -c '[[ ! -e "$1" && ! -e "$2" ]]' _ \
            "$MNT/etc/pacman.d/hooks/90-aelum-snapper-pre.hook" \
            "$MNT/etc/pacman.d/hooks/91-aelum-snapper-post.hook"
    check "no snapshot menu generator (ext4)" \
        [ ! -e "$MNT/usr/local/bin/aelum-refind-snapshots" ]
    check "no snapshot menu fragment (ext4)" \
        [ ! -e "$refind_dir/aelum/$install_id-snapshots.conf" ]
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "VERIFY: PASS (fs=$FILESYSTEM luks=$LUKS lvm=$LVM)"
    exit 0
fi
echo "VERIFY: FAIL ($fails check(s) failed)"
exit 1
