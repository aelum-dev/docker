#!/usr/bin/env bash
#
# Headless-diagnostic QEMU launcher with a VISIBLE window (SDL).
#
# Use this to watch the Aelum ISO boot live instead of test.sh's display-less
# run. Same machine/disk/net setup as run.sh / test.sh, minus -display none.
#
#   bash test_graphical.sh
#
# Ctrl+A then X (or close the window) to quit QEMU.

set -uo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO="${ISO:-$(find "$PROFILE_DIR/output" -maxdepth 1 -name "*.iso" 2>/dev/null | sort | tail -1)}"
VDISK="${VDISK:-$PROFILE_DIR/vdisk.qcow2}"
OVMF_VARS="${OVMF_VARS:-$PROFILE_DIR/OVMF_VARS.fd}"
SSH_PORT="${SSH_PORT:-2222}"
QEMU_QVM="${QEMU_QVM:-1}"

[ -n "$ISO" ] && [ -f "$ISO" ] || { echo "ERROR: no ISO found in $PROFILE_DIR/output/" >&2; exit 1; }
[ -f "$VDISK" ] || { echo "ERROR: vdisk not found: $VDISK (run 'make build' / test.sh first)" >&2; exit 1; }

OVMF_CODE=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_CODE*.fd" 2>/dev/null | grep -v secboot | head -1)
[ -n "$OVMF_CODE" ] || { echo "ERROR: OVMF_CODE not found (install edk2-ovmf)" >&2; exit 1; }
# Reset UEFI NVRAM from the system template before each boot so the boot records
# start clean (same effect as manually deleting OVMF_VARS.fd to reset boot order).
OVMF_VARS_SRC=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_VARS*.fd" 2>/dev/null | grep -v secboot | head -1)
[ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF_VARS source not found" >&2; exit 1; }
cp "$OVMF_VARS_SRC" "$OVMF_VARS"
echo "[view] reset OVMF_VARS.fd from $OVMF_VARS_SRC"

QEMU_ARGS=(
    -display sdl,gl=on
    -nodefaults
    -machine q35
    -smp 4,sockets=1,cores=4,threads=1
    -m 4G
    -cdrom "$ISO"
    -boot d
    -device virtio-vga
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    -drive id=vdisk,file="$VDISK",if=none,format=qcow2,cache=writeback,aio=io_uring
    -device virtio-blk-pci,drive=vdisk
    -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0
)
if [ "$QEMU_QVM" = "1" ] && [ -e /dev/kvm ]; then
    QEMU_ARGS=(-enable-kvm -cpu host "${QEMU_ARGS[@]}")
else
    echo "[view] KVM unavailable; running in software emulation (slower)"
fi

qemu-system-x86_64 "${QEMU_ARGS[@]}"
