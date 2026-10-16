#!/usr/bin/env bash
#
# Aelum live-ISO guest-probe driver (host side).
#
# Boots the ISO and, the moment sshd is reachable, pipes GUEST_SCRIPT into the
# guest over SSH. SSH comes up at roughly the same moment the compositor does,
# so a guest script can sample live state instead of inferring it from
# timestamps after the fact.
#
# It was written for the post-greetd black-screen stall (hence the name), but
# it is the generic "run a diagnostic inside a booted guest" driver: point
# GUEST_SCRIPT at anything you want executed as root in the VM.
#
# Output: logs/stall-probe.log  (raw, everything the guest printed)
#
# Usage:
#   bash scripts/probe-stall.sh
#   DISPLAY_MODE=sdl bash scripts/probe-stall.sh      # watch it
#   MEM=8G STALL_DUR=60 bash scripts/probe-stall.sh   # STALL_DUR is passed to the guest
#   GUEST_SCRIPT=scripts/some-other-probe.sh bash scripts/probe-stall.sh
#
# Requires: qemu-system-x86_64, sshpass, ssh.

set -uo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${ISO:-$(find "$PROFILE_DIR/output" -maxdepth 1 -name "*.iso" 2>/dev/null | sort | tail -1)}"
SSH_PORT="${SSH_PORT:-2222}"
ROOT_PASS="${ROOT_PASS:-}"
DISPLAY_MODE="${DISPLAY_MODE:-egl-headless}"   # egl-headless | sdl | gtk | none
XRES="${XRES:-1920}"
YRES="${YRES:-1080}"
MEM="${MEM:-4G}"
STALL_DUR="${STALL_DUR:-50}"
SSH_TIMEOUT="${SSH_TIMEOUT:-180}"
QEMU_QVM="${QEMU_QVM:-1}"
QEMU_EXTRA="${QEMU_EXTRA:-}"
GUEST_SCRIPT="${GUEST_SCRIPT:-$PROFILE_DIR/scripts/probe-stall-guest.sh}"

LOG="${LOG:-$PROFILE_DIR/logs/stall-probe.log}"
QEMU_LOG="$PROFILE_DIR/logs/qemu-stall-probe.log"
mkdir -p "$PROFILE_DIR/logs"

log()  { echo "[stall] $*"; }
fail() { echo "[stall] ERROR: $*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "qemu-system-x86_64 not found"
command -v sshpass           >/dev/null 2>&1 || fail "sshpass not found"
[ -n "$ISO" ] && [ -f "$ISO" ] || fail "no ISO found in $PROFILE_DIR/output/"

# --- kill stale QEMU for this ISO -------------------------------------------
self_pid=$$
for pid in $(pgrep -f "qemu-system-x86_64.*$(basename "$ISO")" 2>/dev/null); do
    [ "$pid" = "$self_pid" ] && continue
    kill -9 "$pid" 2>/dev/null
done
sleep 1

# --- firmware ---------------------------------------------------------------
OVMF_CODE="$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_CODE*.fd" 2>/dev/null | grep -v secboot | head -1)"
OVMF_VARS_SRC="$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_VARS*.fd" 2>/dev/null | grep -v secboot | head -1)"
[ -n "$OVMF_CODE" ] || fail "OVMF_CODE not found (install edk2-ovmf)"
OVMF_VARS="$PROFILE_DIR/OVMF_VARS.fd"
cp "$OVMF_VARS_SRC" "$OVMF_VARS"

# --- display / gpu ----------------------------------------------------------
case "$DISPLAY_MODE" in
    egl-headless) DISP=(-display egl-headless); GPU=(-device virtio-vga-gl,xres="$XRES",yres="$YRES",edid=on) ;;
    sdl)          DISP=(-display sdl,gl=on);     GPU=(-device virtio-vga-gl,xres="$XRES",yres="$YRES",edid=on) ;;
    gtk)          DISP=(-display gtk,gl=on);     GPU=(-device virtio-vga-gl,xres="$XRES",yres="$YRES",edid=on) ;;
    none)         DISP=(-display none);          GPU=(-device virtio-vga,xres="$XRES",yres="$YRES",edid=on) ;;
    *) fail "DISPLAY_MODE must be egl-headless|sdl|gtk|none" ;;
esac

QEMU_ARGS=(
    -nodefaults -machine q35
    -smp 4,sockets=1,cores=4,threads=1
    -m "$MEM"
    -cdrom "$ISO" -boot d -no-reboot
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 -device virtio-net-pci,netdev=net0
    "${DISP[@]}" "${GPU[@]}"
)
[ -f "$PROFILE_DIR/vdisk.qcow2" ] && QEMU_ARGS+=(
    -drive id=vdisk,file="$PROFILE_DIR/vdisk.qcow2",if=none,format=qcow2,cache=writeback,aio=io_uring
    -device virtio-blk-pci,drive=vdisk)
if [ "$QEMU_QVM" = "1" ] && [ -e /dev/kvm ]; then
    QEMU_ARGS=(-enable-kvm -cpu host "${QEMU_ARGS[@]}")
fi
[ -n "$QEMU_EXTRA" ] && QEMU_ARGS+=($QEMU_EXTRA)

SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=2 -o BatchMode=yes)
ssh_root() { sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" "$@"; }

log "ISO: $(basename "$ISO")  (display=$DISPLAY_MODE, mem=$MEM)"
log "Booting QEMU ..."
qemu-system-x86_64 "${QEMU_ARGS[@]}" < /dev/null > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!
cleanup() { kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; }
trap cleanup EXIT

log "Waiting for sshd (up to ${SSH_TIMEOUT}s) ..."
ready=0
for _ in $(seq 1 "$SSH_TIMEOUT"); do
    if kill -0 "$QEMU_PID" 2>/dev/null && ssh_root "true" 2>/dev/null; then ready=1; break; fi
    kill -0 "$QEMU_PID" 2>/dev/null || fail "QEMU exited during boot — see $QEMU_LOG"
    sleep 1
done
[ "$ready" = "1" ] || fail "sshd did not become available — see $QEMU_LOG"

log "Guest up; probing the stall live for ${STALL_DUR}s ..."
STALL_DUR="$STALL_DUR" sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" "bash -s" \
    < "$GUEST_SCRIPT" 2>&1 | tee "$LOG"

log "Probe saved: $LOG"

# vim: set ft=sh ts=4 sw=4 et:
