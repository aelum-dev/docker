#!/usr/bin/env bash
#
# Aelum live-ISO boot-time measurement.
#
# Boots the latest ISO in output/ in QEMU *with a GPU* (so the graphical boot
# chain actually runs), then runs scripts/boot-timing.sh inside the guest over
# SSH and prints a monotonic timeline of every component on the way from the
# kernel to the installer's first window. Nothing is baked into the ISO; the
# timeline is reconstructed from systemd, /proc and the guest's own IPC.
#
# The point of this tool is the gap the splash does not cover:
#
#     plymouth-quit (splash dismissed) -> installer window mapped
#
# Usage:
#   make measure-boot                 # or: bash scripts/measure-boot.sh
#   DISPLAY_MODE=sdl make measure-boot   # watch it live in an SDL window
#   SSH_PORT=2230 make measure-boot
#
# Output:
#   stdout                            — the timeline report
#   logs/boot-timing.log              — full raw collector output
#   logs/boot-timing.json             — machine-readable timings (seconds)
#
# Requires: qemu-system-x86_64, sshpass, ssh. KVM optional (QEMU_QVM=0).

set -uo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${ISO:-$(find "$PROFILE_DIR/output" -maxdepth 1 -name "*.iso" 2>/dev/null | sort | tail -1)}"
SSH_PORT="${SSH_PORT:-2222}"
ROOT_PASS="${ROOT_PASS:-}"
DISPLAY_MODE="${DISPLAY_MODE:-egl-headless}"   # egl-headless | sdl | gtk | none
XRES="${XRES:-1920}"
YRES="${YRES:-1080}"
WINDOW_TIMEOUT="${WINDOW_TIMEOUT:-60}"         # seconds to wait for the installer window
SSH_TIMEOUT="${SSH_TIMEOUT:-180}"              # seconds to wait for sshd
MEM="${MEM:-4G}"                               # guest RAM
QEMU_QVM="${QEMU_QVM:-1}"                      # 1 = use -enable-kvm -cpu host
QEMU_EXTRA="${QEMU_EXTRA:-}"
KEEP="${KEEP:-0}"                              # 1 = leave the VM running after the report (for follow-up probes)

VDISK="$PROFILE_DIR/vdisk.qcow2"
OVMF_VARS="$PROFILE_DIR/OVMF_VARS.fd"
RAW_LOG="$PROFILE_DIR/logs/boot-timing.log"
JSON_LOG="$PROFILE_DIR/logs/boot-timing.json"
QEMU_LOG="$PROFILE_DIR/logs/qemu-boot-timing.log"
mkdir -p "$PROFILE_DIR/logs"

LOG_PREFIX="[timing]"
log() { echo "${LOG_PREFIX} $*"; }
fail() { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

# --- Preconditions -----------------------------------------------------------
command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "qemu-system-x86_64 not found"
command -v sshpass           >/dev/null 2>&1 || fail "sshpass not found"
command -v ssh               >/dev/null 2>&1 || fail "ssh not found"
[ -n "$ISO" ] && [ -f "$ISO" ] || fail "no ISO found in $PROFILE_DIR/output/ (build it first with 'make build')"
case "$DISPLAY_MODE" in
    egl-headless|sdl|gtk|none) ;;
    *) fail "DISPLAY_MODE must be egl-headless|sdl|gtk|none (got '$DISPLAY_MODE')" ;;
esac

# --- Kill stale QEMU from a previous run (same ISO) --------------------------
self_pid=$$
for pid in $(pgrep -f "qemu-system-x86_64.*$(basename "$ISO")" 2>/dev/null); do
    [ "$pid" = "$self_pid" ] && continue
    kill -9 "$pid" 2>/dev/null
done
sleep 1

# --- Firmware / disk ---------------------------------------------------------
OVMF_CODE="$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_CODE*.fd" 2>/dev/null | grep -v secboot | head -1)"
[ -n "$OVMF_CODE" ] || fail "OVMF_CODE not found (install edk2-ovmf)"
OVMF_VARS_SRC="$(find /usr/share/edk2/x64 /usr/share/OVMF -name "OVMF_VARS*.fd" 2>/dev/null | grep -v secboot | head -1)"
[ -n "$OVMF_VARS_SRC" ] || fail "OVMF_VARS source not found"
cp "$OVMF_VARS_SRC" "$OVMF_VARS"

# --- Display / GPU -----------------------------------------------------------
# A GPU is required for Hyprland. egl-headless/gtk/sdl hand the guest a
# virtio-vga-gl (virgl) device; "none" falls back to a plain virtio-gpu, which
# is enough for the non-graphical chain but will not start the compositor.
# The "-gl" suffix already enables virgl — there is no gl=on device property on
# modern QEMU; GL is negotiated with the display backend.
case "$DISPLAY_MODE" in
    egl-headless) DISP=(-display egl-headless); GPU=(-device virtio-vga-gl,xres="$XRES",yres="$YRES",edid=on) ;;
    sdl)          DISP=(-display sdl,gl=on);     GPU=(-device virtio-vga-gl,xres="$XRES",yres="$YRES",edid=on) ;;
    gtk)          DISP=(-display gtk,gl=on);     GPU=(-device virtio-vga-gl,xres="$XRES",yres="$YRES",edid=on) ;;
    none)         DISP=(-display none);          GPU=(-device virtio-vga,xres="$XRES",yres="$YRES",edid=on) ;;
esac

# --- QEMU --------------------------------------------------------------------
QEMU_ARGS=(
    -nodefaults
    -machine q35
    -smp 4,sockets=1,cores=4,threads=1
    -m "$MEM"
    -cdrom "$ISO"
    -boot d
    -no-reboot
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 -device virtio-net-pci,netdev=net0
    "${DISP[@]}"
    "${GPU[@]}"
)
# Attach the existing test disk if present (the installer enumerates disks on
# launch); never recreate it here, measurement must not touch test state.
if [ -f "$VDISK" ]; then
    QEMU_ARGS+=(-drive id=vdisk,file="$VDISK",if=none,format=qcow2,cache=writeback,aio=io_uring
                -device virtio-blk-pci,drive=vdisk)
fi
if [ "$QEMU_QVM" = "1" ] && [ -e /dev/kvm ]; then
    QEMU_ARGS=(-enable-kvm -cpu host "${QEMU_ARGS[@]}")
else
    log "KVM unavailable; running in software emulation (slower)"
fi
if [ -n "$QEMU_EXTRA" ]; then
    # shellcheck disable=SC2206
    QEMU_ARGS+=($QEMU_EXTRA)
fi

# --- SSH ---------------------------------------------------------------------
SSH_OPTS=(
    -p "$SSH_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
    -o BatchMode=yes
)
ssh_root() { sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" "$@"; }

# --- Boot --------------------------------------------------------------------
log "ISO: $(basename "$ISO")  (display=$DISPLAY_MODE ${XRES}x${YRES}, mem=$MEM)"
log "Booting QEMU ..."
if [ "$KEEP" = "1" ]; then
    # Detach so the VM survives this script exiting (for follow-up probes).
    setsid qemu-system-x86_64 "${QEMU_ARGS[@]}" < /dev/null > "$QEMU_LOG" 2>&1 &
    QEMU_PID=$!
    cleanup() { :; }
else
    qemu-system-x86_64 "${QEMU_ARGS[@]}" < /dev/null > "$QEMU_LOG" 2>&1 &
    QEMU_PID=$!
    cleanup() { kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; }
fi
trap cleanup EXIT

log "Waiting for sshd (up to ${SSH_TIMEOUT}s) ..."
ssh_ready=0
for _ in $(seq 1 "$SSH_TIMEOUT"); do
    if kill -0 "$QEMU_PID" 2>/dev/null && ssh_root "true" 2>/dev/null; then
        ssh_ready=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        fail "QEMU exited during boot — see $QEMU_LOG"
    fi
    sleep 1
done
[ "$ssh_ready" = "1" ] || fail "sshd did not become available within ${SSH_TIMEOUT}s — see $QEMU_LOG"

# Run the collector immediately: it polls for the installer surface, so the
# earlier we start it, the more accurate the window time is.
log "Guest up; collecting boot timeline (waiting up to ${WINDOW_TIMEOUT}s for the installer window) ..."
WINDOW_TIMEOUT="$WINDOW_TIMEOUT" \
    sshpass -p "$ROOT_PASS" ssh "${SSH_OPTS[@]}" "root@localhost" "bash -s" \
    < "$PROFILE_DIR/scripts/boot-timing.sh" | tee "$RAW_LOG"

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
declare -A T=()
while IFS=$'\t' read -r tag key val; do
    [ "$tag" = "AELUM_TIMING" ] || continue
    T["$key"]="$val"
done < <(grep -a '^AELUM_TIMING' "$RAW_LOG")

offset="$(awk -v f="${T[fw]:-}" -v l="${T[loader]:-}" \
    'BEGIN{printf "%.3f", (f==""?0:f+0)+(l==""?0:l+0)}')"

echo
echo "===================== Aelum boot timing ====================="
echo
echo "systemd-analyze breakdown (seconds):"
for k in fw loader kernel initrd userspace; do
    printf '  %-10s %s\n' "$k" "${T[$k]:-n/a}"
done
if [ -z "${T[fw]:-}" ] && [ -z "${T[loader]:-}" ]; then
    echo "  (firmware/loader not reported on this boot — GRUB/UEFI without systemd-boot"
    echo "   EFI timing; the timeline below is therefore relative to kernel start)"
fi

rows=""
add_abs() { [ -n "${2:-}" ] || return 0; rows+="$2"$'\t'"$1"$'\n'; }
add_mono() {
    [ -n "${2:-}" ] || return 0
    add_abs "$1" "$(awk -v v="$2" -v o="$offset" 'BEGIN{printf "%.3f", v+o}')"
}
add_abs  "kernel start"                 "$offset"
add_mono "plymouth-start (initramfs)"   "${T[plymouth_start]:-}"
add_mono "greetd.service"               "${T[greetd_unit]:-}"
add_mono "greetd process"               "${T[proc_greetd]:-}"
add_mono "systemd-user-sessions"        "${T[systemd_usersphere]:-}"
add_mono "plymouth-quit (splash off)"   "${T[plymouth_quit]:-}"
add_mono "Hyprland"                     "${T[proc_hyprland]:-}"
add_mono "hyprpaper"                    "${T[proc_hyprpaper]:-}"
add_mono "quickshell (dms)"             "${T[proc_quickshell]:-}"
add_mono "collector start (SSH up)"     "${T[collector_start]:-}"
add_mono "installer process"            "${T[proc_installer]:-}"
add_mono "installer window"             "${T[window]:-}"
add_mono "installer CLI"                "${T[proc_installer_cli]:-}"

echo
echo "component timeline (seconds since power-on, +delta from previous):"
printf '%s' "$rows" | sort -n | awk -F'\t' '
    { d = (NR == 1 ? 0 : $1 - prev); printf "  %8.3f  %+7.3f  %s\n", $1, d, $2; prev = $1 }
'

splash="${T[plymouth_quit]:-}"
echo
echo "black-screen gap:"
if [ -z "$splash" ]; then
    echo "  plymouth-quit time unavailable — cannot measure the gap"
else
    for pair in "installer process:proc_installer" "installer window:window"; do
        label="${pair%%:*}"; key="${pair##*:}"
        v="${T[$key]:-}"
        [ -n "$v" ] || { printf '  splash off -> %-18s n/a\n' "$label"; continue; }
        printf '  splash off -> %-18s %.3f s\n' "$label" \
            "$(awk -v a="$v" -v b="$splash" 'BEGIN{print a-b}')"
    done
    if [ "${T[window_already_present]:-0}" = "1" ]; then
        echo "  note: the installer window was already mapped when the collector"
        echo "        first looked; its exact time is an upper bound — use the"
        echo "        installer process start above."
    fi
fi
echo "============================================================="

# ---------------------------------------------------------------------------
# Machine-readable sidecar
# ---------------------------------------------------------------------------
json_values=""
k_sorted="$(printf '%s\n' "${!T[@]}" | grep -v '^window_already_present$' | sort)"
for k in $k_sorted; do
    v="${T[$k]}"
    [ -n "$v" ] || continue
    [ "$k" = "fw" ] || [ "$k" = "loader" ] || [ "$k" = "kernel" ] || \
    [ "$k" = "initrd" ] || [ "$k" = "userspace" ] || \
        v="$(awk -v v="$v" -v o="$offset" 'BEGIN{printf "%.3f", v+o}')"
    json_values+="  \"$k\": $v,"$'\n'
done
{
    echo "{"
    echo "  \"iso\": \"$(basename "$ISO")\","
    printf '%s' "$json_values"
    echo "  \"offset_firmware_loader\": $offset,"
    echo "  \"window_already_present\": ${T[window_already_present]:-0}"
    echo "}"
} > "$JSON_LOG"

log "Report saved: $RAW_LOG"
log "JSON saved:   $JSON_LOG"
if [ "$KEEP" = "1" ]; then
    log "VM left running (KEEP=1). SSH in with:"
    log "  sshpass -p '' ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost"
    log "Stop it with: pkill -f 'qemu-system-x86_64.*$(basename "$ISO")'"
fi
