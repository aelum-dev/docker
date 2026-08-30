#!/usr/bin/env bash
#
# Headless QEMU + installer-cli smoke/integration test for the Aelum ISO.
#
# Boots the built ISO in a display-less QEMU VM, waits for sshd, and drives
# aelum-installer-cli over SSH against the virtual disk. The installer CLI is
# fully headless: the password is read from stdin and JSON progress is written
# to stderr, so it can be scripted without the graphical frontend.
#
# Modes:
#   MODE=full    (default) Run a real install against the vdisk.
#   MODE=dry     Run --install --dry-run. Fast, no real disk writes. Smoke test.
#
#   SHARED_INSTALLER=1  Run the freshly built CLI from /shared instead of the
#                       version baked into the ISO. Useful to test the latest
#                       build without rebuilding the ISO:
#                         SHARED_INSTALLER=1 MODE=full ./test.sh
#                       (the host shared/ dir is mounted at /shared inside the VM).
#
# Requirements: qemu-system-x86_64, sshpass, ssh.
#   KVM is optional: without /dev/kvm, drop -enable-kvm/-cpu host (see below).
#
# Configuration (all optional, see defaults below).

set -uo pipefail

# --- Configuration -----------------------------------------------------------
# Scripts live in scripts/; the project root (output/, vdisk, firmware, logs/)
# is the parent of this script.
PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${ISO:-$(find "$PROFILE_DIR/output" -maxdepth 1 -name "*.iso" 2>/dev/null | sort | tail -1)}"
MODE="${MODE:-full}"                      # full | dry (full = real install)
SHARED_INSTALLER="${SHARED_INSTALLER:-0}" # 0 = ISO-baked CLI, 1 = run from /shared
KEEP_ALIVE="${KEEP_ALIVE:-0}"             # 1 = leave QEMU running after a successful run so you can SSH in and re-run the CLI without restarting the VM
SHARED_DIR="${SHARED_DIR:-$HOME/Projects/shared}"  # host dir mounted at /shared in the VM
ROOT_PASS="${ROOT_PASS:-}"                # empty-password SSH (PermitEmptyPasswords yes on the live ISO)
USERNAME="${USERNAME:-aelum}"             # account created by the installer
USER_PASS="${USER_PASS:-aelum}"           # password set for that account (full mode)
SSH_PORT="${SSH_PORT:-2222}"              # host port forwarded to guest :22
DISK_PATH="${DISK_PATH:-/dev/vda}"        # disk path *inside* the guest
QEMU_QVM="${QEMU_QVM:-1}"                 # 1 = use -enable-kvm -cpu host
QEMU_EXTRA="${QEMU_EXTRA:-}"              # extra qemu-system-x86_64 args

LOG_PREFIX="[test]"

log()  { echo "${LOG_PREFIX} $*"; }

# Print SSH + re-run instructions when KEEP_ALIVE=1. QEMU is a background child,
# so it keeps running after the script exits and the forwarded :2222 port stays
# live as long as it runs.
keep_alive_note() {
    [ -n "${QEMU_PID:-}" ] || return 0
    log "KEEP_ALIVE=1: leaving QEMU running (pid $QEMU_PID). SSH in with:"
    log "  ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost"
    log "Then re-run the installer CLI directly, e.g.:"
    log "  ${INSTALLER_BIN:-sudo aelum-installer-cli} --install $DISK_PATH --username $USERNAME 2> $PROGRESS_JSON"
    log "Find the still-running QEMU with: pgrep -af qemu-system-x86_64"
}

fail() {
    echo "${LOG_PREFIX} ERROR: $*" >&2
    # With KEEP_ALIVE=1, disarm the EXIT cleanup and leave QEMU up so the VM can
    # be inspected over SSH even after a failed run.
    if [ "$KEEP_ALIVE" = "1" ]; then
        trap - EXIT
        keep_alive_note
        exit 1
    fi
    cleanup
    exit 1
}

# Kill leftover QEMU/test processes from an aborted previous run. A stale QEMU
# holds the vdisk lock, which makes the boot fail with "Failed to get 'write'
# lock". Match against our ISO+vdisk (and skip this process tree) so unrelated
# QEMU/installs are never touched.
self_pid=$$
kill_stale() {
    log "Clearing stale QEMU/test processes from a previous run ..."
    local base_iso base_disk pid
    base_iso="$(basename "$ISO")"
    base_disk="$(basename "$VDISK")"
    for pid in $(pgrep -f "qemu-system-x86_64.*${base_iso}.*${base_disk}" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null
    done
    # [t]est\.sh keeps this regex from matching its own command line.
    for pid in $(pgrep -f "[t]est\.sh" 2>/dev/null); do
        [ "$pid" = "$self_pid" ] && continue
        [ "$pid" = "$PPID" ] && continue
        kill -9 "$pid" 2>/dev/null
    done
    # Drop a stale qcow2 lock only if its holder is already gone.
    if [ -e "$VDISK.lock" ]; then
        rm -f "$VDISK.lock"
    fi
    sleep 2
}

# --- Preconditions -----------------------------------------------------------
command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "qemu-system-x86_64 not found"
command -v sshpass          >/dev/null 2>&1 || fail "sshpass not found (apt/dnf install sshpass)"
command -v ssh              >/dev/null 2>&1 || fail "ssh not found"
[ -n "$ISO" ] && [ -f "$ISO" ] || fail "no ISO found in $PROFILE_DIR/output/ (build it first with 'make build')"

VDISK="$PROFILE_DIR/vdisk.qcow2"
OVMF_VARS="$PROFILE_DIR/OVMF_VARS.fd"
PROGRESS_JSON="$PROFILE_DIR/logs/test-progress.json"
mkdir -p "$(dirname "$PROGRESS_JSON")"

# --- Clean up stale state before we touch the vdisk --------------------------
kill_stale

# --- Virtual disk ---------------
# Start from a clean disk each run so partition/format/rollback are exercised
# against a fresh target.
if [ "$MODE" = "full" ]; then
    log "Recreating virtual disk ($VDISK, 20G) ..."
    qemu-img create -f qcow2 "$VDISK" 20G >/dev/null || fail "could not create vdisk"
fi
[ -f "$VDISK" ] || fail "vdisk not found: $VDISK"

# --- OVMF firmware (mirrors run.sh) ------------------------------------------
OVMF_CODE=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_CODE*.fd" 2>/dev/null | grep -v secboot | head -1)
[ -n "$OVMF_CODE" ] || fail "OVMF_CODE not found (install edk2-ovmf)"
# Reset UEFI NVRAM from the system template before each boot so the boot records
# start clean (same effect as manually deleting OVMF_VARS.fd to reset boot order).
OVMF_VARS_SRC=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_VARS*.fd" 2>/dev/null | grep -v secboot | head -1)
[ -n "$OVMF_VARS_SRC" ] || fail "OVMF_VARS source not found"
cp "$OVMF_VARS_SRC" "$OVMF_VARS"

# --- SSH helpers -------------------------------------------------------------
SSH_OPTS=(
    -p "$SSH_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
    -o BatchMode=yes
)
ssh_root() { sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" "$@"; }

# Wait for sshd inside the guest. Poll the login instead of a fixed sleep.
wait_for_ssh() {
    local i
    for i in $(seq 1 90); do
        if ssh_root "true" 2>/dev/null; then
            log "sshd is up (after ~$((i * 4))s)"
            return 0
        fi
        sleep 4
    done
    fail "sshd did not become available"
}

# --- Boot QEMU headless ------------------------------------------------------
QEMU_ARGS=(
    -display none
    -nodefaults
    -machine q35
    -smp 4,sockets=1,cores=4,threads=1
    -m 4G
    -cdrom "$ISO"
    -boot d
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    -drive id=vdisk,file="$VDISK",if=none,format=qcow2,cache=writeback,aio=io_uring
    -device virtio-blk-pci,drive=vdisk
    -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0
    -vnc none
)

# When testing the freshly built CLI from /shared, expose the host shared dir to
# the guest via a 9p virtfs mount (mirrors run.sh). The live ISO's shared-mount
# service then mounts it at /shared on boot.
if [ "$SHARED_INSTALLER" = "1" ]; then
    [ -d "$SHARED_DIR" ] || fail "SHARED_INSTALLER=1 but SHARED_DIR not found: $SHARED_DIR"
    QEMU_ARGS+=(-virtfs local,path="$SHARED_DIR",mount_tag=shared,security_model=mapped,id=hostshared)
fi
if [ "$QEMU_QVM" = "1" ] && [ -e /dev/kvm ]; then
    QEMU_ARGS=(-enable-kvm -cpu host "${QEMU_ARGS[@]}")
else
    log "KVM unavailable; running QEMU in software emulation (slower)"
fi
if [ -n "$QEMU_EXTRA" ]; then
    # shellcheck disable=SC2206
    QEMU_ARGS+=($QEMU_EXTRA)
fi

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null && wait "$QEMU_PID" 2>/dev/null
}
trap cleanup EXIT

log "Booting QEMU headless (mode=$MODE) ..."
qemu-system-x86_64 "${QEMU_ARGS[@]}" &
QEMU_PID=$!

wait_for_ssh

# When running from /shared, wait for the 9p mount to come up (shared-mount
# service) before launching, so we don't race the mount and hit "command not found".
if [ "$SHARED_INSTALLER" = "1" ]; then
    log "Waiting for /shared/aelum-installer-cli to be available ..."
    shared_ready=0
    for i in $(seq 1 30); do
        if ssh_root "test -x /shared/aelum-installer-cli" 2>/dev/null; then
            log "/shared ready (after ~$((i * 2))s)"
            shared_ready=1
            break
        fi
        sleep 2
    done
    [ "$shared_ready" = "1" ] || fail "/shared/aelum-installer-cli not found after wait (is SHARED_DIR mounted?)."
fi

# --- Installer to run --------------------------------------------------------
# By default the test drives the CLI baked into the ISO. With SHARED_INSTALLER=1
# it runs the freshly built binary from /shared (mounted host<->VM) instead,
# using an absolute path so sudo resolves it reliably:
#   sudo /shared/aelum-installer-cli
if [ "$SHARED_INSTALLER" = "1" ]; then
    INSTALLER_BIN="sudo /shared/aelum-installer-cli"
    log "Using freshly built CLI from /shared"
else
    INSTALLER_BIN="sudo aelum-installer-cli"
    log "Using CLI baked into the ISO"
fi

# --- Run the installer -------------------------------------------------------
# The CLI reads the user *password* from stdin; the username comes from
# --username. In --dry-run neither is read, so no stdin is needed there.
if [ "$MODE" = "dry" ]; then
    log "Running installer CLI (dry-run) on $DISK_PATH ..."
    sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" \
        "${INSTALLER_BIN} --install ${DISK_PATH} --dry-run --username ${USERNAME}" 2> "$PROGRESS_JSON"
    RC=$?
else
    log "Running installer CLI (full install) on $DISK_PATH ..."
    printf '%s\n' "$USER_PASS" \
        | sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" \
            "${INSTALLER_BIN} --install ${DISK_PATH} --username ${USERNAME}" 2> "$PROGRESS_JSON"
    RC=$?
fi

# --- Assert the run ----------------------------------------------------------
if [ "$RC" -ne 0 ]; then
    fail "installer CLI exited with code $RC (see $PROGRESS_JSON)"
fi
log "installer CLI exited 0"

if [ -s "$PROGRESS_JSON" ]; then
    # The installer streams one JSON event per line to stderr; report a compact
    # summary. The real gate below is the exit code, not this output.
    events=$(grep -c '^{' "$PROGRESS_JSON" 2>/dev/null || echo 0)
    log "installer emitted ${events} progress event(s)"
    if grep -qiE 'error|fail|panic' "$PROGRESS_JSON"; then
        log "warning: progress output contained error/fail keywords (exit code was 0)"
    fi
fi

log "SUCCESS ($MODE test passed). Progress: $PROGRESS_JSON"

# With KEEP_ALIVE=1, detach from the EXIT cleanup trap and leave QEMU running so
# the VM can be SSHed into and the installer CLI re-run over SSH (no QEMU restart
# per iteration). QEMU is a background child, so it keeps running after this
# script exits; the forwarded :2222 port stays live as long as it runs.
if [ "$KEEP_ALIVE" = "1" ]; then
    trap - EXIT
    keep_alive_note
    exit 0
fi

exit 0
