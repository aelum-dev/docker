#!/usr/bin/env bash
set -euo pipefail

# menu-shots.sh — screenshot the boot menu of the system installed on
# vdisk.qcow2, without opening a QEMU window.
#
#   ./scripts/menu-shots.sh                  # boot it, capture, power it off
#   KEEP_UP=1 ./scripts/menu-shots.sh        # leave the VM up for more keys
#   ./scripts/menu-shots.sh --then-boot      # then boot the install, so it rewrites its menu
#   ./scripts/menu-shots.sh --boot-snapshot  # also boot the snapshot the menu points at
#   ./scripts/menu-shots.sh --entry 0        # the menu exactly as rEFInd opens it
#
# Frames go to logs/menu/ as menu-NN-*.ppm (+ .png when Pillow is installed).
# If a headless VM for this disk is already up, this uses it instead of booting
# a second one, so keys and screenshots can be repeated while looking at one boot.
#
# The menu itself is rEFInd's, written by the installed system: see
# make -C docker demo-snapshots for putting snapshots on the disk first. That
# runs from the live ISO, which cannot write this install's menu, so after it
# the menu on the ESP is one boot behind: run this once with --then-boot (the
# install rebuilds its menu at boot) and the screenshots after that are current.

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$PROFILE_DIR/logs/menu}"
MON="$OUT_DIR/monitor.sock"
KEEP_UP="${KEEP_UP:-0}"

# The [v] is not a typo: pgrep -f also matches the shell that is running this
# script, and that shell has the pattern in its own command line.
running() { pgrep -f "qemu-system-x86_64.*[v]disk.qcow2" >/dev/null 2>&1; }

if running && [ -S "$MON" ]; then
    echo "using the headless VM that is already running ($MON)"
else
    if running; then
        echo "A VM for vdisk.qcow2 is already running without a monitor socket." >&2
        echo "Stop it first (ssh -p 2222 root@localhost poweroff, or:" >&2
        echo " pkill -f 'qemu-system[-]x86_64.*vdisk.qcow2'), then run this again." >&2
        exit 1
    fi
    echo "booting vdisk.qcow2 headless (monitor $MON) ..."
    mkdir -p "$OUT_DIR"
    # SSH_PORT=0: no host port forward, so a capture can run while a test VM is
    # up. The menu is drawn before anything in the guest needs the network.
    BOOT_DISK=1 HEADLESS=1 MONITOR="$MON" SERIAL="$OUT_DIR/serial.log" SSH_PORT=0 \
        setsid "$PROFILE_DIR/scripts/run-iso.sh" >"$OUT_DIR/qemu.log" 2>&1 &
    for _ in $(seq 1 100); do
        [ -S "$MON" ] && break
        sleep 0.2
    done
    [ -S "$MON" ] || { echo "QEMU did not open a monitor; see $OUT_DIR/qemu.log" >&2; exit 1; }
fi

cd "$PROFILE_DIR"
status=0
./scripts/menu-shots.py --socket "$MON" --out-dir "$OUT_DIR" "$@" || status=$?

if [ "$KEEP_UP" != 1 ]; then
    # A guest that is running an OS answers the power button. One that is still
    # sitting in the firmware does not, so the monitor gets a quit as well and
    # this never leaves a VM behind holding port 2222.
    ./scripts/qemu-mon.py --socket "$MON" --gap 0.4 "system_powerdown" >/dev/null
    for _ in $(seq 1 20); do running || break; sleep 0.5; done
    if running; then ./scripts/qemu-mon.py --socket "$MON" --gap 0.4 "quit" >/dev/null; fi
    echo "VM stopped"
fi

echo
echo "frames: $OUT_DIR"
exit $status
