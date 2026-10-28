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

# --- GPU acceleration ------------------------------------------------------
# GL=1 (the default) gives the guest a virtio-vga-gl (virgl 3D) and asks the
# window to composite it on the host GPU. GL=0 falls back to the old plain
# secondary-vga in a CPU-composited window.
# UI=sdl (the default) is the backend that composites smoothly on this host;
# UI=gtk is kept as a fallback (2c52743: an older QEMU showed a black
# sdl,gl=on window here).
# FULLSCREEN=1 applies to the GTK backend only: GTK fullscreen has no title bar
# or borders and drops the menubar with them. This QEMU's SDL has no fullscreen
# CLI option - press Ctrl+Alt+F once its window is open.
GL="${GL:-1}"
UI="${UI:-sdl}"
FULLSCREEN="${FULLSCREEN:-1}"

# --- Headless capture mode -----------------------------------------------
# HEADLESS=1 draws nothing on the host and gives the guest a plain VGA, which is
# the only thing QEMU's `screendump` can read: that is how the boot menu gets
# screenshotted (scripts/menu-shots.sh). MONITOR=<path> puts QEMU's human
# monitor on a unix socket so keys and screendumps can be sent from the host,
# SERIAL=<path> keeps the guest's text console in a file, and SSH_PORT=0 drops
# the port forward so a headless capture can run next to a test VM.
HEADLESS="${HEADLESS:-0}"
MONITOR="${MONITOR:-}"
SERIAL="${SERIAL:-}"
SSH_PORT="${SSH_PORT:-2222}"

# --- Run QEMU ---
QEMU_ARGS=(
    -enable-kvm
    -cpu host
    -smp 4,sockets=1,cores=4,threads=1
    -m 4G
    -machine q35
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    -drive id=vdisk,file="$VDISK",if=none,format=qcow2,cache=writeback,aio=io_uring
    -device virtio-blk-pci,drive=vdisk
    -virtfs local,path="$SHARED_DIR",mount_tag=shared,security_model=mapped,id=hostshared
)

if [ "$HEADLESS" = 1 ]; then
    # std-vga, not virtio-vga-gl: screendump reads the standard VGA console, and
    # -nodefaults keeps QEMU from adding a monitor or a default serial device
    # that would clash with the ones asked for above.
    QEMU_ARGS+=(-display none -nodefaults -vga std)
else
    DISPLAY_OPTS="$UI"
    if [ "$GL" = 1 ]; then
        DISPLAY_OPTS+=",gl=on"
    fi
    if [ "$UI" = gtk ] && [ "$FULLSCREEN" = 1 ]; then
        DISPLAY_OPTS+=",full-screen=on,show-menubar=off"
    fi

    GPU_DEV="secondary-vga,edid=on,xres=$XRES,yres=$YRES"
    if [ "$GL" = 1 ]; then
        # virtio-vga-gl is the guest's whole display (firmware GOP and virgl 3D
        # in the guest kernel); XRES/YRES are the EDID the guest desktop picks.
        GPU_DEV="virtio-vga-gl,edid=on,xres=$XRES,yres=$YRES"
    fi
    QEMU_ARGS+=(
        -display "$DISPLAY_OPTS"
        -device "$GPU_DEV"
        -device virtio-serial-pci
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
        -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on
    )
fi

if [ -n "$MONITOR" ]; then
    mkdir -p "$(dirname "$MONITOR")" 2>/dev/null
    rm -f "$MONITOR" 2>/dev/null
    QEMU_ARGS+=(-monitor "unix:$MONITOR,server,nowait")
fi
if [ -n "$SERIAL" ]; then
    mkdir -p "$(dirname "$SERIAL")" 2>/dev/null
    QEMU_ARGS+=(-serial "file:$SERIAL")
fi

if [ "$SSH_PORT" = 0 ] || [ -z "$SSH_PORT" ]; then
    QEMU_ARGS+=(-netdev user,id=net0)
else
    QEMU_ARGS+=(-netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22)
fi
QEMU_ARGS+=(-device virtio-net-pci,netdev=net0)

if [ -n "$ISO" ]; then
    QEMU_ARGS=(-cdrom "$ISO" -boot d "${QEMU_ARGS[@]}")
fi

exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
