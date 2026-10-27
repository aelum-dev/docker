#!/usr/bin/env bash
set -euo pipefail

# Scripts live in scripts/; the project root (output/, firmware, vdisk) is the
# parent of this script.
PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shared/ (the VM's /shared mount) lives in the distro workspace above this repo.
DISTRO_DIR="$(cd "$PROFILE_DIR/.." && pwd)"

# BOOT_DISK=1 boots what is installed on vdisk.qcow2 instead of the ISO: no
# -cdrom, no -boot d, so OVMF follows its own boot order and the installed
# system's rEFInd is what answers. That is how the installed system's own boot
# menu - and its snapshot submenu - is looked at.
BOOT_DISK="${BOOT_DISK:-0}"

ISO=""
if [ "$BOOT_DISK" != 1 ]; then
    ISO="${1:-$(find "$PROFILE_DIR/output" -maxdepth 1 -name "*.iso" 2>/dev/null | sort | tail -1)}"
    if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
        echo "Error: ISO file not found in $PROFILE_DIR/output/"
        exit 1
    fi
    echo "Using ISO: $ISO"
else
    echo "Booting the system installed on: $PROFILE_DIR/vdisk.qcow2"
fi

# --- Shared Directory ---
SHARED_DIR="${SHARED_DIR:-$DISTRO_DIR/shared}"
mkdir -p "$SHARED_DIR"

# --- UEFI firmware setup ---
OVMF_CODE=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_CODE.4m.fd" 2>/dev/null | head -1)
[ -n "$OVMF_CODE" ] || OVMF_CODE=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_CODE*.fd" 2>/dev/null | head -1)

[ -n "$OVMF_CODE" ] || { echo "Error: OVMF_CODE not found. Install edk2-ovmf package."; exit 1; }

OVMF_VARS="$PROFILE_DIR/OVMF_VARS.fd"
if [ ! -f "$OVMF_VARS" ]; then
    OVMF_VARS_SRC=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_VARS.4m.fd" ! -name "*secboot*" 2>/dev/null | head -1)
    [ -n "$OVMF_VARS_SRC" ] || OVMF_VARS_SRC=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_VARS*.fd" ! -name "*secboot*" 2>/dev/null | head -1)
    
    if [ -n "$OVMF_VARS_SRC" ]; then
        echo "Copying OVMF_VARS.fd from $OVMF_VARS_SRC ..."
        cp "$OVMF_VARS_SRC" "$OVMF_VARS"
    else
        echo "Error: OVMF_VARS.fd source not found."
        exit 1
    fi
fi

# --- Virtual disk ---
VDISK="$PROFILE_DIR/vdisk.qcow2"
if [ ! -f "$VDISK" ]; then
    echo "Creating virtual disk: $VDISK (20G) ..."
    qemu-img create -f qcow2 "$VDISK" 20G
fi

# --- Display resolution ---
XRES="${XRES:-1920}"
YRES="${YRES:-1080}"

# --- Run QEMU ---
QEMU_ARGS=(
    -enable-kvm
    -cpu host
    -smp 4,sockets=1,cores=4,threads=1
    -m 4G
    -machine q35
    -display sdl,gl=on
    -device virtio-vga-gl,xres=$XRES,yres=$YRES,edid=on
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    -drive id=vdisk,file="$VDISK",if=none,format=qcow2,cache=writeback,aio=io_uring
    -device virtio-blk-pci,drive=vdisk
    -virtfs local,path="$SHARED_DIR",mount_tag=shared,security_model=mapped,id=hostshared
    -netdev user,id=net0,hostfwd=tcp::2222-:22
    -device virtio-net-pci,netdev=net0
    -device virtio-serial-pci
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
    -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on
)

if [ -n "$ISO" ]; then
    QEMU_ARGS=(-cdrom "$ISO" -boot d "${QEMU_ARGS[@]}")
fi

exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
