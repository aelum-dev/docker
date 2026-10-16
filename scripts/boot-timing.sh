#!/usr/bin/env bash
#
# Aelum live-ISO boot-timing collector — runs INSIDE the guest.
#
# Reconstructs a single monotonic timeline of the boot chain
# (kernel -> systemd -> plymouth -> greetd -> Hyprland -> installer) from
# systemd unit timestamps, systemd-analyze and /proc — no instrumentation is
# baked into the ISO. The host driver (scripts/measure-boot.sh) pipes this in
# over SSH and renders the report.
#
# Output contract on stdout:
#   AELUM_TIMING<TAB>KEY<TAB>VALUE      (VALUE = seconds since kernel start;
#                                        empty/absent when never observed)
# The remaining output is a raw diagnostic dump for the log. Only the
# AELUM_TIMING lines are parsed. All timestamps are CLOCK_MONOTONIC (seconds
# since the kernel started), which is the same origin as /proc/uptime and the
# starttime field of /proc/<pid>/stat.
set -uo pipefail

HZ="$(getconf CLK_TCK 2>/dev/null || echo 100)"

emit() { printf 'AELUM_TIMING\t%s\t%s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

# Seconds since kernel start, right now.
now_s() { awk '{printf "%.3f", $1}' /proc/uptime; }

# Start time of a pid in seconds since kernel start, from field 22 of
# /proc/<pid>/stat. comm can contain spaces and parentheses, so drop everything
# up to the last ") " before counting fields: starttime (field 22 overall) is
# then field 20.
pid_start() {
    local pid="$1" stat rest start
    read -r stat < "/proc/$pid/stat" 2>/dev/null || return 1
    rest="${stat##*') '}"
    start="$(awk '{print $20}' <<<"$rest")"
    [ -n "${start:-}" ] || return 1
    awk -v s="$start" -v hz="$HZ" 'BEGIN{printf "%.3f", s/hz}'
}

# Earliest start time among processes whose /proc/<pid>/exe resolves to the
# given absolute path or basename. Matching on exe (not comm) avoids the 15-char
# comm truncation that makes aelum-installer and aelum-installer-cli collide.
first_start_for_exe() {
    local want="$1" pid exe base best="" t
    for pid in /proc/[0-9]*; do
        exe="$(readlink "$pid/exe" 2>/dev/null)" || continue
        base="${exe##*/}"
        if [ "$exe" = "$want" ] || [ "$base" = "$want" ]; then
            t="$(pid_start "${pid##*/}")" || continue
            if [ -z "$best" ] || awk -v a="$t" -v b="$best" 'BEGIN{exit !(a<b)}'; then
                best="$t"
            fi
        fi
    done
    printf '%s' "$best"
}

# Monotonic timestamp (seconds since kernel start) of a systemd unit property,
# e.g. ActiveEnterTimestampMonotonic. systemd reports microseconds.
unit_mono() {
    local v
    v="$(systemctl show -p "$2" --value "$1" 2>/dev/null)" || return 0
    case "${v:-}" in ''|0|n/a) return 0 ;; esac
    awk -v us="$v" 'BEGIN{printf "%.3f", us/1000000}'
}

# ---------------------------------------------------------------------------
# systemd-analyze breakdown (firmware/loader/kernel/initrd/userspace/total)
# ---------------------------------------------------------------------------

ANALYZE="$(systemd-analyze time 2>&1 | tr '\n' ' ')"
analyze_dur() {
    local m
    m="$(grep -oE "[0-9.]+s? \($1\)" <<<"$ANALYZE" | head -1)"
    printf '%s' "${m%%s*}"
}
emit fw        "$(analyze_dur firmware)"
emit loader    "$(analyze_dur loader)"
emit kernel    "$(analyze_dur kernel)"
emit initrd    "$(analyze_dur initrd)"
emit userspace "$(analyze_dur userspace)"

# ---------------------------------------------------------------------------
# Userspace milestones (systemd units)
# ---------------------------------------------------------------------------

emit plymouth_start     "$(unit_mono plymouth-start.service         ActiveEnterTimestampMonotonic)"
emit systemd_usersphere "$(unit_mono systemd-user-sessions.service   ActiveEnterTimestampMonotonic)"
emit greetd_unit        "$(unit_mono greetd.service                 ActiveEnterTimestampMonotonic)"
emit plymouth_quit      "$(unit_mono plymouth-quit.service          ActiveEnterTimestampMonotonic)"
emit plymouth_quit_wait "$(unit_mono plymouth-quit-wait.service     InactiveEnterTimestampMonotonic)"
emit sshd_unit          "$(unit_mono sshd.service                   ActiveEnterTimestampMonotonic)"

# ---------------------------------------------------------------------------
# Installer window: first time the aelum-installer Wayland surface exists.
# Polled from here, which is the earliest point the host can observe the guest.
# If it is already mapped on the first look, the exact time is unknowable (the
# host driver falls back to the installer process start); flag it either way.
# The process start times below are sampled *after* this poll so that the
# installer (which appears later than greetd/Hyprland) is always seen.
# ---------------------------------------------------------------------------

emit collector_start "$(now_s)"
window_time=""
window_already=0
WINDOW_TIMEOUT="${WINDOW_TIMEOUT:-60}"
i=0
while [ "$i" -lt $(( WINDOW_TIMEOUT * 5 )) ]; do
    if [ -d /run/user/1000/hypr ]; then
        for sig in /run/user/1000/hypr/*; do
            [ -d "$sig" ] || continue
            if runuser -u aelum -- env XDG_RUNTIME_DIR=/run/user/1000 \
                   HYPRLAND_INSTANCE_SIGNATURE="${sig##*/}" \
                   hyprctl -j clients 2>/dev/null | grep -qi 'aelum-installer'; then
                window_time="$(now_s)"
                [ "$i" -eq 0 ] && window_already=1
                break 2
            fi
        done
    fi
    sleep 0.2
    i=$(( i + 1 ))
done
emit window "$window_time"
emit window_already_present "$window_already"

# ---------------------------------------------------------------------------
# Desktop-chain processes: exact start time from /proc/<pid>/stat. Sampled
# after the window poll so the installer process is present regardless of how
# long it took to start.
# ---------------------------------------------------------------------------

emit proc_greetd        "$(first_start_for_exe greetd)"
emit proc_hyprland      "$(first_start_for_exe Hyprland)"
emit proc_hyprpaper     "$(first_start_for_exe hyprpaper)"
emit proc_quickshell    "$(first_start_for_exe quickshell)"
emit proc_installer     "$(first_start_for_exe /usr/local/bin/aelum-installer)"
emit proc_installer_cli "$(first_start_for_exe /usr/local/bin/aelum-installer-cli)"

# ---------------------------------------------------------------------------
# Raw diagnostics for the log
# ---------------------------------------------------------------------------

echo
echo "===== systemd-analyze time ====="
echo "$ANALYZE"
echo
echo "===== systemd-analyze blame (top 25) ====="
systemd-analyze blame --no-pager 2>/dev/null | head -25
echo
echo "===== boot-chain units ====="
systemctl show -p Id -p ActiveEnterTimestamp -p ActiveEnterTimestampMonotonic \
    -p InactiveEnterTimestamp -p InactiveEnterTimestampMonotonic \
    plymouth-start.service plymouth-quit.service plymouth-quit-wait.service \
    greetd.service systemd-user-sessions.service sshd.service 2>/dev/null
echo
echo "===== greetd.service journal (installer stdout; short-monotonic) ====="
journalctl -b -u greetd.service -o short-monotonic --no-pager 2>/dev/null | tail -n 120
echo
echo "===== installer process environment (selected) ====="
for pid in /proc/[0-9]*; do
    [ "$(readlink "$pid/exe" 2>/dev/null)" = /usr/local/bin/aelum-installer ] || continue
    printf 'pid=%s  start=%s\n' "${pid##*/}" "$(pid_start "${pid##*/}")"
    tr '\0' '\n' < "$pid/environ" 2>/dev/null \
        | grep -E '^(GDK|GTK|GSK|WAYLAND|XDG_SESSION|XDG_RUNTIME|WEBKIT|LIBGL|MESA|HYPRLAND|DISPLAY)' \
        | sort | sed 's/^/  /'
done

echo
echo "===== all processes since boot (start asc) ====="
for pid in /proc/[0-9]*; do
    t="$(pid_start "${pid##*/}")" || continue
    printf '%s\t%s\t%s\n' "$t" "$(cat "$pid/comm" 2>/dev/null)" "$(readlink "$pid/exe" 2>/dev/null)"
done | sort -n | awk -F'\t' '{ printf "%8.3f  %-24s %s\n", $1, $2, $3 }'
echo
echo "===== boot-chain processes (start time) ====="
for name in greetd Hyprland hyprpaper quickshell; do
    for pid in $(pgrep -x "$name" 2>/dev/null); do
        printf '%s\tpid=%s\tstart=%s\n' "$name" "$pid" "$(pid_start "$pid")"
    done
done
for exe in /usr/local/bin/aelum-installer /usr/local/bin/aelum-installer-cli; do
    for pid in /proc/[0-9]*; do
        [ "$(readlink "$pid/exe" 2>/dev/null)" = "$exe" ] || continue
        printf '%s\tpid=%s\tstart=%s\n' "$exe" "${pid##*/}" "$(pid_start "${pid##*/}")"
    done
done

# vim: set ft=sh ts=4 sw=4 et:
