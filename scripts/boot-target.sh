#!/usr/bin/env bash
#
# Which boot target the *next* QEMU run uses: the ISO, or the system installed on
# vdisk.qcow2.
#
# Why this exists: OVMF keeps its UEFI variables in OVMF_VARS.fd, and while a
# BootOrder variable lives in there it boots strictly in that order and ignores
# QEMU's -boot d completely. So `-cdrom x.iso -boot d` boots the installed disk
# if an install put its own entry first, and `make run-disk` boots the ISO if a
# test run promoted the DVD entry. This script edits that order instead of
# fighting it — the Boot#### entries themselves are never touched, so the other
# target stays one switch away.
#
#   ./scripts/boot-target.sh show    # what would boot now (default)
#   ./scripts/boot-target.sh iso     # boot the ISO next
#   ./scripts/boot-target.sh disk    # boot the installed system next
#   ./scripts/boot-target.sh reset   # retire BootOrder; OVMF rebuilds one
#
# run-iso.sh points the order at its own target on every run (BOOT_DISK=1 → disk,
# otherwise iso), so `make run` and `make run-disk` are correct on their own and a
# switch made here does not outlive the next one of those. Reach for it directly
# for a hand-written qemu-system command, or to see what a run would boot (show).
# Labels are what OVMF stores: the DVD entry it makes for the CD, and the entry the
# installed system registers. Override them with ISO_LABEL= / DISK_LABEL= for a
# machine whose entries are named differently.
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OVMF_VARS="${OVMF_VARS:-$PROFILE_DIR/OVMF_VARS.fd}"
ISO_LABEL="${ISO_LABEL:-QEMU DVD-ROM}"
DISK_LABEL="${DISK_LABEL:-Aelum}"

usage() {
    cat <<'EOF'
Usage: boot-target.sh [show|iso|disk|reset]   (default: show)

  show   print the UEFI boot order with its labels, and what would boot next
  iso    put the ISO's DVD entry at the head of the boot order
  disk   put the installed system's entry at the head of the boot order
  reset  retire BootOrder so OVMF rebuilds one on the next boot

Environment: OVMF_VARS (the NVRAM file), ISO_LABEL / DISK_LABEL (the entry
labels to promote). run-iso.sh points the order at its own target on every run,
so a switch made here only lasts until the next make run / run-disk — it is for
a hand-written qemu-system command, and for seeing why a run booted the wrong
thing (show).
EOF
}

case "${1:-show}" in
    -h | --help | help) usage; exit 0 ;;
    show | iso | disk | reset) target="${1:-show}" ;;
    *) echo "unknown target: $1"; echo; usage; exit 2 ;;
esac

if [ ! -f "$OVMF_VARS" ]; then
    echo "No NVRAM yet: $OVMF_VARS"
    echo "Nothing to switch — a fresh OVMF template holds no BootOrder, so QEMU's -boot decides."
    echo "run-iso.sh copies the template there on its next run."
    exit 0
fi

case "$target" in
    show)
        out="$(python3 "$PROFILE_DIR/scripts/uefi-vars.py" "$OVMF_VARS" order)"
        printf '%s\n' "$out"
        head_entry="$(printf '%s\n' "$out" | sed -n 's/^  0: Boot[0-9a-f]\{4\}  //p' | head -1)"
        case "$head_entry" in
            "<no such entry>"*) echo "→ the boot order is blanked: OVMF boots the devices present, and QEMU's -boot d picks the head" ;;
            *"$ISO_LABEL"*) echo "→ the next QEMU run boots the ISO" ;;
            *"$DISK_LABEL"*) echo "→ the next QEMU run boots the installed system" ;;
            "") echo "→ BootOrder is empty: QEMU's -boot decides" ;;
            *) echo "→ the next QEMU run boots: $head_entry" ;;
        esac
        printf '%s\n' "$out" | grep -q "$ISO_LABEL" \
            || echo "note: no DVD entry in this NVRAM, so 'iso' cannot promote one (boot the ISO once, or make run-clean)"
        printf '%s\n' "$out" | grep -q "$DISK_LABEL" \
            || echo "note: no installed entry in this NVRAM, so 'disk' cannot promote one (make demo-snapshots writes one)"
        ;;
    iso | disk)
        label="$ISO_LABEL"
        [ "$target" = disk ] && label="$DISK_LABEL"
        if python3 "$PROFILE_DIR/scripts/uefi-vars.py" "$OVMF_VARS" promote "$label"; then
            echo "Next QEMU run: $([ "$target" = disk ] && echo "the system installed on vdisk.qcow2" || echo "the ISO in output/")"
        elif [ "$target" = disk ]; then
            echo "no entry named *$label* in $OVMF_VARS — the installed system registers its own."
            echo "Boot the live ISO and let it write one:"
            echo "    make -C docker test-boot && make -C docker demo-snapshots"
            exit 1
        else
            # No CD entry to promote: OVMF deleted it on the last boot that had no CD
            # (and reused its number for a PXE entry). Nothing in the order can be
            # told to boot the CD, so blank the order for this run instead — no entry
            # is retired, OVMF finds nothing listed and boots the devices that are
            # present, where QEMU's -boot d puts the CD first. The install's entry
            # survives untouched, so `disk` puts the order back in one step.
            echo "no entry named *$ISO_LABEL* in $OVMF_VARS: OVMF deletes a CD's entry when the VM boots without a CD."
            echo "Blanking the boot order for this run — no entry is retired, so the CD is what is"
            echo "left to boot and the installed system's entry stays exactly as it was."
            python3 "$PROFILE_DIR/scripts/uefi-vars.py" "$OVMF_VARS" blank
            echo "Next QEMU run: the ISO in output/"
            echo "The next make run-disk points the order back at the install by itself."
        fi
        ;;
    reset)
        python3 "$PROFILE_DIR/scripts/uefi-vars.py" "$OVMF_VARS" drop BootOrder
        echo "OVMF will rebuild an order on the next boot — persisted OS entries first, then the CD."
        echo "To forget the whole NVRAM instead:  make -C docker run-clean"
        ;;
esac
