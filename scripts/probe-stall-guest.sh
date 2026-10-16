#!/usr/bin/env bash
#
# Aelum live-ISO guest probe — runs INSIDE the guest.
#
# boot-timing.sh reconstructs *when* things happened after the fact. This probe
# records *what the machine is doing*: a one-shot snapshot of the finished boot
# (systemd-analyze time / critical-chain / blame, still-queued jobs, DRM state,
# mounts) followed by a live sampler of the process tree — CPU/IO pressure, load
# average, top CPU, D-state tasks, the compositor's blocked state and the
# installer's own threads. That is enough to tell a compositor/GPU wait apart
# from system-wide starvation while it is still happening.
#
# Driven by scripts/probe-stall.sh, which boots the ISO and pipes this in once
# sshd is reachable. STALL_DUR (seconds, default 50) sets the sampler window.
# Everything is printed to stdout; the driver tees it to logs/stall-probe.log.
set -uo pipefail

now() { awk '{printf "%.3f", $1}' /proc/uptime; }
DUR="${STALL_DUR:-50}"

echo "############ STALL PROBE START $(now) ############"

# ---------------------------------------------------------------------------
# One-shot: what the boot looks like
# ---------------------------------------------------------------------------
echo "===== systemd-analyze time ====="
systemd-analyze time 2>&1 || true
echo
echo "===== systemctl is-system-running ====="
systemctl is-system-running 2>&1 || true
echo
echo "===== systemd-analyze critical-chain ====="
systemd-analyze critical-chain --no-pager 2>&1 || true
echo
echo "===== systemd-analyze blame (top 30) ====="
systemd-analyze blame --no-pager 2>&1 | head -30 || true
echo
echo "===== systemctl list-jobs (jobs still queued) ====="
systemctl list-jobs --no-pager 2>&1 || true
echo
echo "===== filesystems ====="
findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | sort || true
echo
echo "===== DRM state ====="
for c in /sys/class/drm/card*/; do
    [ -e "$c/status" ] || continue
    printf '%s status=%s enabled=%s modes=[%s]\n' "${c%/}" \
        "$(cat "$c/status" 2>/dev/null)" \
        "$(cat "$c/enabled" 2>/dev/null)" \
        "$(head -1 "$c/modes" 2>/dev/null)"
done
echo "/proc/fb: $(cat /proc/fb 2>/dev/null)"
ls -l /dev/dri 2>/dev/null || true

# ---------------------------------------------------------------------------
# Live sampling of the stall window
# ---------------------------------------------------------------------------
echo
echo "===== LIVE SAMPLES (t, loadavg, PSI, top cpu, D-state, compositor, plymouthd) ====="
endt="$(awk -v a="$(now)" -v d="$DUR" 'BEGIN{printf "%.3f", a+d}')"

# Locate the installer process by its executable (works whether started by
# greetd's session or manually).
find_installer() {
    local d
    for d in /proc/[0-9]*; do
        if [ "$(readlink "$d/exe" 2>/dev/null)" = /usr/local/bin/aelum-installer ]; then
            echo "${d##*/}"; return 0
        fi
    done
}

while :; do
    u="$(now)"
    awk -v u="$u" -v e="$endt" 'BEGIN{exit !(u < e)}' || break
    load="$(cut -d' ' -f1-3 /proc/loadavg)"
    cpsi="$(grep -h '^some' /proc/pressure/cpu 2>/dev/null | sed 's/^some //')"
    ipsi="$(grep -h '^some' /proc/pressure/io 2>/dev/null | sed 's/^some //')"
    top="$(ps -eo pcpu=,pid=,stat=,comm= 2>/dev/null | sort -rn | head -6 \
              | awk '{printf "%s%%(pid %s,%s,%s) ", $1,$2,$3,$4}')"
    dstate="$(ps -eo pid=,stat=,comm= 2>/dev/null | awk '$2 ~ /D/' \
              | awk '{printf "%s(%s,%s) ",$1,$2,$3}')"
    comp=""
    for name in Hyprland cage sway wayland; do
        for pid in $(pgrep -x "$name" 2>/dev/null); do
            comp+="$name(pid=$pid state=$(awk '{print $3}' /proc/$pid/stat 2>/dev/null) wchan=$(cat /proc/$pid/wchan 2>/dev/null)) "
        done
    done
    ply="$(pgrep -a plymouthd 2>/dev/null | tr '\n' ' ')"
    printf 'SAMPLE t=%s load=[%s] cpu_psi=[%s] io_psi=[%s]\n' "$u" "$load" "$cpsi" "$ipsi"
    printf '  top:  %s\n' "$top"
    printf '  D:    %s\n' "${dstate:-none}"
    printf '  comp: %s\n' "${comp:-none}"
    printf '  ply:  %s\n' "${ply:-none}"

    # --- installer-process dissection -------------------------------------
    inst="$(find_installer)"
    if [ -n "$inst" ]; then
        printf '  inst: pid=%s %s\n' "$inst" \
            "$(grep -E '^(State|Threads|Ctxt)' /proc/$inst/status 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
        # Per-thread CPU (top 5) + state + wchan: which thread burns the core?
        for t in /proc/$inst/task/*/; do
            tid="${t%/}"; tid="${tid##*/}"
            comm="$(cat "$t/comm" 2>/dev/null)"
            st="$(cat "$t/stat" 2>/dev/null)"; st="${st#*) }"
            # shellcheck disable=SC2086
            set -- $st
            printf '%s %s %s %s\n' "$(( ${12:-0} + ${13:-0} ))" "$tid" "${comm:-?}" "${1:-?}"
        done | sort -rn | head -5 | while read -r ct tid comm state; do
            printf '      cpu=%-7s tid=%-7s %-18s state=%s wchan=%s\n' \
                "$ct" "$tid" "$comm" "$state" "$(cat /proc/$inst/task/$tid/wchan 2>/dev/null)"
        done
        printf '      io:   %s\n' "$(tr '\n' ' ' < /proc/$inst/io 2>/dev/null)"
        # Dump the open-file set once, the first time we see the process.
        if [ ! -e /tmp/.fds_dumped ]; then
            echo '      --- OPEN FILES (first seen) ---'
            ls -l /proc/$inst/fd 2>/dev/null | sed 's/^/        /'
            echo "      --- maps lines: $(wc -l < /proc/$inst/maps 2>/dev/null) ---"
            touch /tmp/.fds_dumped
        fi
    fi
    sleep 0.5
done

# ---------------------------------------------------------------------------
# Post: journals
# ---------------------------------------------------------------------------
echo
echo "===== journalctl -b -o short-monotonic (FULL) ====="
journalctl -b -o short-monotonic --no-pager 2>&1 || true
echo
echo "===== journalctl -b _UID=1000 (user session) ====="
journalctl -b _UID=1000 -o short-monotonic --no-pager 2>&1 | tail -n 150 || true
echo
echo "===== journalctl -b -u greetd.service ====="
journalctl -b -u greetd.service -o short-monotonic --no-pager 2>&1 | tail -n 150 || true
echo
echo "===== dmesg ====="
dmesg 2>&1 || true

echo "############ STALL PROBE END $(now) ############"

# vim: set ft=sh ts=4 sw=4 et:
