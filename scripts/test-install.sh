#!/usr/bin/env bash
#
# Headless QEMU driver for the Aelum ISO. Two modes:
#
#   MODE=auto   (default) Boot the ISO, wait for ssh, and run the installer CLI
#               (the version baked into the ISO) to do a full automatic install
#               against the vdisk. QEMU is stopped when the test finishes.
#
#               LUKS=1  encrypt the root partition with LUKS2 (pipe the account
#               password then the LUKS passphrase; default passphrase
#               LUKS_PASS=aelum-luks). The installer CLI already supports --luks.
#
#               MANUAL=1 use manual partitioning: a 512 MiB ESP plus a System
#               partition that fills the rest, driven via --manual-layout.
#               Exercises the manual install path end to end (both selected
#               partitions are formatted).
#
#               LVM=1   place root (and, for ext4, home) on LVM logical volumes
#               (adds --lvm; combine with LUKS=1 for LUKS under LVM).
#
#               VERIFY=0 skip the post-install inspection of the installed system
#               (verify-installed.sh runs it by default when VERIFY=1).
#
#   MODE=boot   Boot the ISO headless, mount the host shared dir at /shared in
#               the guest, and leave it running so you can SSH in and launch the
#               freshly built installer from /shared. QEMU is detached and
#               survives this script exiting.
#
#   SHARED_INSTALLER=1 (auto mode) mount /shared and drive the auto install with
#               the freshly built installer from /shared instead of the CLI
#               baked into the ISO.
#
# Requirements: qemu-system-x86_64, sshpass, ssh.
#   KVM is optional: without /dev/kvm, set QEMU_QVM=0.

set -uo pipefail

# Scripts live in scripts/; the project root (output/, vdisk, firmware, logs/)
# is the parent of this script.
PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The distro workspace is one level above this repo and holds shared/, the host
# side of the VM's /shared mount. Deriving it keeps SHARED_INSTALLER=1 pointed at
# the trees this checkout actually contains: a hard-coded home path silently
# tested whatever stale binary happened to sit there.
DISTRO_DIR="$(cd "$PROFILE_DIR/.." && pwd)"
ISO="${ISO:-$(find "$PROFILE_DIR/output" -maxdepth 1 -name "*.iso" 2>/dev/null | sort | tail -1)}"
MODE="${MODE:-auto}"                       # auto | boot
SHARED_DIR="${SHARED_DIR:-$DISTRO_DIR/shared}"  # host dir mounted at /shared in the VM
SHARED_INSTALLER="${SHARED_INSTALLER:-0}"          # auto mode: install using /shared/aelum-installer-cli instead of the baked-in one (0 | 1)
ROOT_PASS="${ROOT_PASS:-}"                 # empty-password SSH (PermitEmptyPasswords yes on the live ISO)
USERNAME="${USERNAME:-aelum}"              # account created by the installer (auto mode)
USER_PASS="${USER_PASS:-aelum}"            # password for that account (auto mode)
LUKS="${LUKS:-0}"                          # encrypt root with LUKS2 in auto install: 0 | 1
LUKS_PASS="${LUKS_PASS:-aelum-luks}"       # passphrase for the LUKS root partition (LUKS=1)
LVM="${LVM:-0}"                            # root (and ext4 home) on LVM logical volumes: 0 | 1
SSH_PORT="${SSH_PORT:-2222}"               # host port forwarded to guest :22
DISK_PATH="${DISK_PATH:-/dev/vda}"         # disk path *inside* the guest
FILESYSTEM="${FILESYSTEM:-btrfs}"          # root fs for auto install: ext4 | btrfs
MANUAL="${MANUAL:-0}"                      # use manual partitioning (formats Boot + System): 0 | 1
VERIFY="${VERIFY:-1}"                      # independently inspect the installed system after install: 0 | 1
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
    # [t]est-install\.sh keeps this regex from matching its own command line.
    for pid in $(pgrep -f "[t]est-install\.sh" 2>/dev/null); do
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
[ "$FILESYSTEM" = "ext4" ] || [ "$FILESYSTEM" = "btrfs" ] || fail "FILESYSTEM must be 'ext4' or 'btrfs' (got '$FILESYSTEM')"
[ "$LUKS" = "0" ] || [ "$LUKS" = "1" ] || fail "LUKS must be '0' or '1' (got '$LUKS')"
[ "$LUKS" = "0" ] || [ -n "$LUKS_PASS" ] || fail "LUKS_PASS must be set when LUKS=1"
[ "$LVM" = "0" ] || [ "$LVM" = "1" ] || fail "LVM must be '0' or '1' (got '$LVM')"
[ "$MANUAL" = "0" ] || [ "$MANUAL" = "1" ] || fail "MANUAL must be '0' or '1' (got '$MANUAL')"
[ "$VERIFY" = "0" ] || [ "$VERIFY" = "1" ] || fail "VERIFY must be '0' or '1' (got '$VERIFY')"

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
# An auto run installs onto a freshly created disk, so its NVRAM starts clean
# from the system template (same effect as manually deleting OVMF_VARS.fd).
# A boot run must NOT reset it: MODE=boot itself, and everything that follows a
# boot-mode VM (run-disk, snapshot-rollback), follows the firmware entries an
# earlier install wrote — resetting here silently deletes them, and the next
# disk boot fails with "BdsDxe: No bootable option or device was found".
# (demo-snapshots is what (re)creates the Aelum entry; it deletes stale ones.)
if [ "$MODE" = "auto" ]; then
    OVMF_VARS_SRC=$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_VARS*.fd" 2>/dev/null | grep -v secboot | head -1)
    [ -n "$OVMF_VARS_SRC" ] || fail "OVMF_VARS source not found"
    cp "$OVMF_VARS_SRC" "$OVMF_VARS"
fi

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

# Emit a manual-layout JSON for a fresh disk: a 512 MiB ESP plus a System
# partition that consumes the rest. Used by MANUAL=1 to exercise the manual
# install path headlessly. The geometry is read from the guest so the sector
# math matches what the installer sees.
build_manual_layout() {
    ssh_root "DISK='$DISK_PATH' bash -s" <<'EOS'
set -e
bytes=$(blockdev --getsize64 "$DISK")
ss=$(blockdev --getss "$DISK")
mib=$((1024 * 1024))
parts='{"index":0,"path":"","sizeMB":512,"type":"esp"},{"index":1,"path":"","sizeMB":0,"type":"system"}'
printf '{"disk":"%s","diskSizeMB":%s,"diskSizeBytes":%s,"sectorSizeBytes":%s,"partitions":[%s]}\n' \
    "$DISK" "$((bytes / mib))" "$bytes" "$ss" "$parts"
EOS
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

# Expose the host shared dir to the guest via a 9p virtfs mount (mirrors
# run.sh). The live ISO's shared-mount service then mounts it at /shared on
# boot, so the freshly built installer can be launched from there. Mounted in
# boot mode always, and in auto mode when SHARED_INSTALLER=1 so the test can
# drive the install from /shared instead of the baked-in CLI.
if [ "$MODE" = "boot" ] || [ "$SHARED_INSTALLER" = "1" ]; then
    # A fresh checkout has no shared/ (it holds artifacts only), and QEMU cannot
    # export a directory that is absent.
    mkdir -p "$SHARED_DIR" 2>/dev/null
    [ -d "$SHARED_DIR" ] || fail "SHARED_DIR not found and could not be created: $SHARED_DIR"
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
    # Wait for the 9p /shared mount to come up so the freshly built installer is
    # available before we hand off to the user.
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
    [ "$shared_ready" = "1" ] || fail "/shared/aelum-installer-cli not found after wait (is SHARED_DIR mounted?)"
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

# When installing from /shared, wait for the 9p mount to come up so the freshly
# built installer is available before we launch it (mirrors boot mode).
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
    [ "$shared_ready" = "1" ] || fail "/shared/aelum-installer-cli not found after wait (is SHARED_DIR mounted?)"
fi

# The test drives the CLI (an absolute path so sudo resolves it reliably).
if [ "$SHARED_INSTALLER" = "1" ]; then
    INSTALLER_BIN="sudo /shared/aelum-installer-cli"
    log "Using freshly built CLI from /shared"
else
    INSTALLER_BIN="sudo aelum-installer-cli"
    log "Using CLI baked into the ISO"
fi

# Assemble the installer arguments shared by every path. The CLI reads the user
# *password* from stdin; the username comes from --username.
INSTALLER_ARGS=(--install "$DISK_PATH" --filesystem "$FILESYSTEM" --username "$USERNAME")
if [ "$LUKS" = "1" ]; then
    INSTALLER_ARGS+=(--luks)
fi
if [ "$LVM" = "1" ]; then
    INSTALLER_ARGS+=(--lvm)
fi
if [ "$MANUAL" = "1" ]; then
    MANUAL_LAYOUT="$(build_manual_layout)"
    [ -n "$MANUAL_LAYOUT" ] || fail "could not build a manual layout for $DISK_PATH"
    log "Manual layout: $MANUAL_LAYOUT"
    # Single-quote the JSON so the remote shell passes it through verbatim (JSON
    # contains double quotes but no single quotes).
    INSTALLER_ARGS+=(--manual-layout "'$MANUAL_LAYOUT'")
fi

log "Running installer install on $DISK_PATH (fs=$FILESYSTEM luks=$LUKS lvm=$LVM manual=$MANUAL)"
if [ "$LUKS" = "1" ]; then
    log "LUKS encryption enabled (root partition will be LUKS2-encrypted)"
    # CLI reads the account password first, then the LUKS passphrase, both from
    # stdin — pipe them in that order.
    printf '%s\n%s\n' "$USER_PASS" "$LUKS_PASS" \
        | sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" \
        "${INSTALLER_BIN} ${INSTALLER_ARGS[*]}" 2> >(tee "$PROGRESS_JSON" >&2)
else
    printf '%s\n' "$USER_PASS" \
        | sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" \
        "${INSTALLER_BIN} ${INSTALLER_ARGS[*]}" 2> >(tee "$PROGRESS_JSON" >&2)
fi
RC=$?

if [ "$RC" -ne 0 ]; then
    fail "installer CLI exited with code $RC (see $PROGRESS_JSON)"
fi
log "installer CLI exited 0"

# ── Independent verification of the installed system ─────────────────────────
# The installer's own VerifySystem step already ran, but it is the same code
# under test. This re-inspects the disk from outside: it re-opens LUKS,
# mounts the installed root, and asserts the fstab, initramfs hooks, and boot
# entry match the requested combination.
if [ "$VERIFY" = "1" ]; then
    log "Verifying the installed system (fs=$FILESYSTEM luks=$LUKS lvm=$LVM manual=$MANUAL) ..."
    if { printf 'FILESYSTEM=%q LUKS=%q LUKS_PASS=%q LVM=%q DISK_PATH=%q ENABLE_SSHD=1\n' \
             "$FILESYSTEM" "$LUKS" "$LUKS_PASS" "$LVM" "$DISK_PATH"
          cat "$PROFILE_DIR/scripts/verify-installed.sh"; } \
        | sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" "bash -s"; then
        log "Verification passed"
    else
        fail "verification of the installed system failed"
    fi
else
    log "Verification skipped (VERIFY=0)"
fi

log "SUCCESS (auto test passed). Progress: $PROGRESS_JSON"
exit 0
