#!/usr/bin/env bash
#
# demo-snapshots.sh — put five snapshots on an Aelum install so the rEFInd
# snapshot menu has something to show.
#
# Run it inside the installed system, or from the live ISO against an installed
# system mounted at /mnt:
#
#   demo-snapshots.sh                # in the installed system (any terminal; the
#                                    # aelum user is in wheel and snapper allows wheel)
#   demo-snapshots.sh --root /mnt    # in the live ISO, with the install mounted at /mnt
#   demo-snapshots.sh --reset        # delete every snapshot first
#
# The five are chosen to cover the three things the menu labels differently: two
# pre/post pairs from a package transaction ("Before system update" / "After
# system update"), and one snapshot a person named, which the menu shows with
# those words. Each pair changes a file in between, so it is a real pair and not
# one that EMPTY_PRE_POST_CLEANUP would drop.
#
# The boot menu is written by the installed system: aelum-refind-snapshots.service
# runs at every boot and snapper's plugin starts it after every snapshot. With
# --root this script cannot run that generator (it resolves the ESP and the root
# filesystem from the live mount table), so the menu catches up when the installed
# system boots.
set -u

usage() {
    echo "usage: $(basename "$0") [--root <path>] [--reset]"
}

ROOT=""
RESET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ $# -ge 2 ] || { usage; exit 2; }
            ROOT=$2
            shift 2
            ;;
        --reset)
            RESET=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

command -v snapper >/dev/null || {
    echo "snapper is not installed. Is this a btrfs install?" >&2
    exit 1
}

# snapper's --root is how the live ISO talks to an installed system's config; it
# has to skip DBus, because snapperd there is not the one serving this root.
snap() {
    if [ -n "$ROOT" ]; then
        snapper --no-dbus --root="$ROOT" -c root "$@"
    else
        snapper -c root "$@"
    fi
}

snap list >/dev/null 2>&1 || {
    echo "no snapper config named 'root' (this install has no snapshotting)" >&2
    exit 1
}

# Files written between a pre and a post snapshot, so the pair has a difference
# to show. Under the root the config snapshots, which is $ROOT when given one.
demo_dir="$ROOT/root/aelum-demo"

take_pair() {
    local pre
    pre=$(snap create -t pre -p -c number -d pacman) || return 1
    mkdir -p "$demo_dir" 2>/dev/null || true
    printf 'changed at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$demo_dir/notes.txt" 2>/dev/null
    snap create -t post --pre-number "$pre" -p -c number -d pacman >/dev/null || return 1
}

if [ "$RESET" = 1 ]; then
    echo "=== deleting existing snapshots ==="
    # snapper pads a one-digit number with a space, so the number is matched
    # after any leading blanks. Highest first: a post snapshot may not outlive
    # the pre it is paired with.
    for n in $(snap list 2>/dev/null | sed -n 's/^ *\([0-9]\{1,\}\) .*/\1/p' | sort -rn); do
        [ "$n" = 0 ] && continue
        snap delete "$n" >/dev/null 2>&1 || echo "  could not delete $n"
    done
fi

echo "=== creating 5 demo snapshots ==="
take_pair
take_pair
snap create -t single -d "Before I changed the GPU driver"

echo
echo "=== snapshots ==="
snap list

# The menu fragment: readable here if the ESP is mounted, otherwise the installed
# system rebuilds it at its next boot.
if [ -z "$ROOT" ]; then
    systemctl start aelum-refind-snapshots.service 2>/dev/null ||
        echo "(run 'sudo systemctl start aelum-refind-snapshots.service' to rebuild the menu now)"
fi

fragment=""
for candidate in "$ROOT/efi" /efi /boot; do
    [ -d "$candidate/EFI/refind/aelum" ] || continue
    fragment=$(find "$candidate/EFI/refind/aelum" -maxdepth 1 -name '*-snapshots.conf' 2>/dev/null | head -n 1)
    [ -n "$fragment" ] && break
done

echo
if [ -n "$fragment" ]; then
    echo "=== boot menu entries ($fragment) ==="
    grep -E '^[[:space:]]*(menuentry|submenuentry)' "$fragment" | sed 's/^[[:space:]]*//'
else
    echo "(no ESP mounted here: the installed system writes the menu at its next boot)"
fi

echo
echo "Reboot into the Aelum boot menu, select the snapshot icon, press F2 to list them."
