#!/usr/bin/env bash
#
# test-matrix.sh — run the full Aelum install matrix headlessly and print a
# pass/fail summary. Each cell boots the ISO in QEMU, performs an install via
# test-iso.sh, and (by default) independently verifies the installed system.
#
# Dimensions (override with the matching space-separated list):
#   MODES        auto manual     installation path     (default: both)
#   FILESYSTEMS  btrfs ext4      root filesystem       (default: both)
#   LUKSES       0 1             LUKS2 encryption      (default: both)
#   LVMS         0 1             LVM logical volumes   (default: both)
#
# Examples:
#   ./scripts/test-matrix.sh                     # all 16 combinations
#   LVMS=1 ./scripts/test-matrix.sh              # only the LVM cells (8)
#   MODES=auto FILESYSTEMS=ext4 LVMS=1 ./scripts/test-matrix.sh
#   SHARED_INSTALLER=1 ./scripts/test-matrix.sh  # drive installs from /shared
#
# A full desktop install is heavy: 16 cells takes a long time. Narrow the lists
# while iterating (e.g. LVMS=1 MODES=auto FILESYSTEMS=ext4).
#
# Forwarded to test-iso.sh: LUKS_PASS, USER_PASS, USERNAME, SSH_PORT, QEMU_QVM,
# DISK_PATH, VERIFY, SHARED_INSTALLER, SHARED_DIR, ISO.

set -uo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST="$PROFILE_DIR/scripts/test-iso.sh"

MODES="${MODES:-auto manual}"
FILESYSTEMS="${FILESYSTEMS:-btrfs ext4}"
LUKSES="${LUKSES:-0 1}"
LVMS="${LVMS:-0 1}"

LOG_DIR="$PROFILE_DIR/logs/matrix"
mkdir -p "$LOG_DIR"

total=0
passed=0
failed=0
failed_cells=()

for mode in $MODES; do
    for fs in $FILESYSTEMS; do
        for luks in $LUKSES; do
            for lvm in $LVMS; do
                total=$((total + 1))
                cell="mode=$mode fs=$fs luks=$luks lvm=$lvm"
                logfile="$LOG_DIR/$(printf '%s' "$cell" | tr ' =' '__').log"
                echo
                echo "================================================================"
                echo "[$total] $cell"
                echo "  log: $logfile"
                echo "================================================================"
                if MODE="$mode" FILESYSTEM="$fs" LUKS="$luks" LVM="$lvm" \
                     SHARED_INSTALLER="${SHARED_INSTALLER:-0}" \
                     LUKS_PASS="${LUKS_PASS:-aelum-luks}" \
                     USER_PASS="${USER_PASS:-aelum}" \
                     USERNAME="${USERNAME:-aelum}" \
                     SSH_PORT="${SSH_PORT:-2222}" \
                     QEMU_QVM="${QEMU_QVM:-1}" \
                     DISK_PATH="${DISK_PATH:-/dev/vda}" \
                     VERIFY="${VERIFY:-1}" \
                     SHARED_DIR="${SHARED_DIR:-$HOME/Projects/shared}" \
                     ISO="${ISO:-}" \
                     "$TEST" 2>&1 | tee "$logfile"; then
                    echo ">>> PASS: $cell"
                    passed=$((passed + 1))
                else
                    echo ">>> FAIL: $cell"
                    failed=$((failed + 1))
                    failed_cells+=("$cell")
                fi
            done
        done
    done
done

echo
echo "==================== MATRIX SUMMARY ===================="
echo "total=$total passed=$passed failed=$failed"
if [ "$failed" -gt 0 ]; then
    echo "failed cells:"
    for c in "${failed_cells[@]}"; do
        echo "  - $c"
    done
    echo "logs: $LOG_DIR"
    exit 1
fi
echo "all cells passed"
