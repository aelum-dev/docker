#!/usr/bin/env bash
#
# Headless QEMU driver for the Aelum ISO. Two modes:
#
#   MODE=auto   (default) Boot the ISO, wait for ssh, and run the installer CLI
#               (from /shared when SHARED_INSTALLER=1, else the version baked
#               into the ISO) to do a full automatic install against the vdisk.
#               QEMU is stopped when the test finishes.
#
#   MODE=boot   Boot the ISO headless and leave it running so you can SSH in and
#               experiment. QEMU is detached and survives this script exiting.
#
# Requirements: qemu-system-x86_64, sshpass, ssh.
#   KVM is optional: without /dev/kvm, set QEMU_QVM=0.

set -uo pipefail

# Scripts live in scripts/; the project root (output/, vdisk, firmware, logs/)
# is the parent of this script.
PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${ISO:-$(find "$PROFILE_DIR/output" -maxdepth 1 -name "*.iso" 2>/dev/null | sort | tail -1)}"
MODE="${MODE:-auto}"                       # auto | boot
SHARED_INSTALLER="${SHARED_INSTALLER:-0}"  # 1 = run installer from /shared instead of the ISO
SHARED_DIR="${SHARED_DIR:-$HOME/Projects/shared}"  # host dir mounted at /shared in the VM
ROOT_PASS="${ROOT_PASS:-}"                 # empty-password SSH (PermitEmptyPasswords yes on the live ISO)
USERNAME="${USERNAME:-aelum}"              # account created by the installer (auto mode)
USER_PASS="${USER_PASS:-aelum}"            # password for that account (auto mode)
SSH_PORT="${SSH_PORT:-2222}"               # host port forwarded to guest :22
DISK_PATH="${DISK_PATH:-/dev/vda}"         # disk path *inside* the guest
QEMU_QVM="${QEMU_QVM:-1}"                  # 1 = use -enable-kvm -cpu host
QEMU_EXTRA="${QEMU_EXTRA:-}"               # extra qemu-system-x86_64 args

LOG_PREFIX="[test]"
VDISK="$PROFILE_DIR/vdisk.qcow2"
OVMF_VARS="$PROFILE_DIR/OVMF_VARS.fd"
PROGRESS_JSON="$PROFILE_DIR/logs/test-progress.json"
QEMU_LOG="$PROFILE_DIR/logs/qemu.log"
mkdir -p "$(dirname "$PROGRESS_JSON")"

log()  { echo "${LOG_PREFIX} $*"; }
err()  { echo "${LOG_PREFIX} ERROR: $*" >&2; }
fail() { err "$*"; exit 1; }

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
    [ -e "$VDISK.lock" ] && rm -f "$VDISK.lock"
    sleep 2
}

# --- Preconditions -----------------------------------------------------------
command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "qemu-system-x86_64 not found"
command -v sshpass          >/dev/null 2>&1 || fail "sshpass not found (apt/dnf install sshpass)"
command -v ssh              >/dev/null 2>&1 || fail "ssh not found"
[ -n "$ISO" ] && [ -f "$ISO" ] || fail "no ISO found in $PROFILE_DIR/output/ (build it first with 'make build')"
[ "$MODE" = "auto" ] || [ "$MODE" = "boot" ] || fail "MODE must be 'auto' or 'boot' (got '$MODE')"

# --- Clean up stale state before we touch the vdisk --------------------------
kill_stale

# --- Virtual disk ------------------------------------------------------------
# Auto mode starts from a clean disk each run so partition/format are exercised
# against a fresh target. Boot mode leaves the vdisk untouched for experiments.
if [ "$MODE" = "auto" ]; then
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

# --- Boot mode: leave the VM running for experiments -------------------------
if [ "$MODE" = "boot" ]; then
    # Detach QEMU into its own session so it keeps running after this script
    # exits, and leave it up for SSH + experiments.
    log "Booting QEMU headless (boot mode), leaving it running ..."
    setsid qemu-system-x86_64 "${QEMU_ARGS[@]}" < /dev/null > "$QEMU_LOG" 2>&1 &
    wait_for_ssh
    log "VM is up. SSH in with:"
    log "  ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost"
    log "Find the QEMU process with: pgrep -af qemu-system-x86_64"
    exit 0
fi

# --- Auto mode: boot, run the installer, then stop QEMU ----------------------
log "Booting QEMU headless (auto mode) ..."
qemu-system-x86_64 "${QEMU_ARGS[@]}" &
QEMU_PID=$!
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null && wait "$QEMU_PID" 2>/dev/null
}
trap cleanup EXIT

wait_for_ssh

# When running from /shared, wait for the 9p mount to come up before launching
# the installer, so we don't race the mount and hit "command not found".
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

# By default the test drives the CLI baked into the ISO. With SHARED_INSTALLER=1
# it runs the freshly built binary from /shared instead, using an absolute path
# so sudo resolves it reliably.
if [ "$SHARED_INSTALLER" = "1" ]; then
    INSTALLER_BIN="sudo /shared/aelum-installer-cli"
    log "Using freshly built CLI from /shared"
else
    INSTALLER_BIN="sudo aelum-installer-cli"
    log "Using CLI baked into the ISO"
fi

# The CLI reads the user *password* from stdin; the username comes from
# --username.
log "Running installer install on $DISK_PATH ..."
printf '%s\n' "$USER_PASS" \
    | sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" \
    "${INSTALLER_BIN} --install ${DISK_PATH} --username ${USERNAME}" 2> "$PROGRESS_JSON"
RC=$?

if [ "$RC" -ne 0 ]; then
    fail "installer CLI exited with code $RC (see $PROGRESS_JSON)"
fi
log "installer CLI exited 0"
log "SUCCESS (auto test passed). Progress: $PROGRESS_JSON"
exit 0
