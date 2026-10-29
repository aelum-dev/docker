#!/usr/bin/env bash
#
# test-snapshot-rollback.sh — the acceptance test for the snapshot feature, run
# against the real disk: boot a snapshot, roll back from inside it, reboot into
# the restored system, and assert what came back.
#
#   ./scripts/test-snapshot-rollback.sh                 # needs an install on vdisk.qcow2
#   SNAPSHOT=<n> ./scripts/test-snapshot-rollback.sh    # roll back to a given snapshot
#   KEEP_UP=1 ./scripts/test-snapshot-rollback.sh       # leave the VM running at the end
#   USERNAME=… USER_PASS=… ./scripts/test-snapshot-rollback.sh
#
# It runs against what is installed on docker/vdisk.qcow2 — the only place in this
# project with a disk to install onto and firmware to write boot entries into.
# Nothing here is checked in a container or a chroot: `snapper rollback` with no
# number means "the state I am booted in", and only a real boot has one.
#
# The flow is the one SNAPSHOT_RESTORE.md documents, in order:
#
#   1. put a marker in the live system *after* taking a snapshot of it, so there
#      is something the snapshot does not have;
#   2. boot that snapshot through its own rEFInd entry;
#   3. assert the shape of a snapshot boot (read-only /, live /home, the history
#      mounted, the state directories writable, the greeter reached, the boot
#      announced for the restore prompt);
#   4. the prompt's OK path: pkexec /usr/local/bin/aelum-snapshot-restore - the
#      polkit action is granted to the active graphical session, so this asserts
#      the scope (pkexec from this inactive SSH session must be refused) and then
#      runs the exact command pkexec execs;
#   5. reboot through the install's own entry, which names no subvolume and so
#      follows the pointer the rollback moved;
#   6. assert the system that comes up is the restored one: marker gone, root
#      writable, no snapshot-boot announcement, the undo snapshot listed, the menu
#      still naming real subvolumes.
#
# Getting into a snapshot without a keyboard is the one trick: rEFInd counts down
# to its default_selection, so this writes the snapshot entry into
# default_selection, reboots, and writes the install's own entry back before
# rebooting out. It is the same line a user's keypress would choose, which is
# what makes the whole flow scriptable.
#
# The installed system is reached over SSH as the install's own user (the test
# account, in wheel), because that is how a user would reach a recovery entry.
# sshd is not part of the installer's package set; openssh ships as a dependency
# of the desktop set, so this enables the unit rather than installing anything.

set -uo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VDISK="$PROFILE_DIR/vdisk.qcow2"
OUT_DIR="${OUT_DIR:-$PROFILE_DIR/logs/snapshot-rollback}"
MON="$OUT_DIR/monitor.sock"
SSH_PORT="${SSH_PORT:-2222}"
KEEP_UP="${KEEP_UP:-0}"
USERNAME="${USERNAME:-aelum}"
USER_PASS="${USER_PASS:-aelum}"
MARKER=/root/aelum-rollback-marker   # inside the root, not in /home

fails=0
step() { echo; echo "== $* =="; }
ok()   { echo "  ok   - $*"; }
bad()  { echo "  FAIL - $*"; fails=$((fails + 1)); }
note() { echo "  note - $*"; }
check()     { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
check_not() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi; }
has()       { grep -qE "$2" <<<"$1"; }
# One spelling of a subvolume path. `btrfs subvolume get-default` prints
# `@/.snapshots/1/snapshot`, findmnt prints `/@/.snapshots/1/snapshot`, and a
# menu entry says `rootflags=subvol=@/.snapshots/1/snapshot`. Compared as they
# come they never match, which is how a test passes for the wrong reason.
subvol_of() { sed -n 's/.*\[\([^]]*\)\]/\1/p' | sed 's#^/##'; }
default_subvol() { as_root 'btrfs subvolume get-default /' | sed -n 's/.*path //'p; }

SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)

# root, as the installed system's own user: sudo takes the install's password on
# stdin. Everything the test asserts runs through this.
as_root() {
    printf '%s\n' "$USER_PASS" | sshpass -p "$USER_PASS" ssh "${SSH_OPTS[@]}" \
        "$USERNAME@localhost" "sudo -S -p '' bash -c $(printf '%q' "$1")" 2>/dev/null
}

# Runs as the installed system's own user, with no sudo: this is the subject
# pkexec sees. An SSH session is local but not active, so the snapshot-restore
# action's grant (the local active session of an admin) does not apply here -
# which is exactly what the polkit scope assertion needs.
as_user() {
    sshpass -p "$USER_PASS" ssh "${SSH_OPTS[@]}" "$USERNAME@localhost" "$1" 2>&1
}

wait_for_ssh() { # wait_for_ssh <seconds>
    local deadline=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$deadline" ]; do
        as_root 'true' >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

running() { pgrep -f "qemu-system-x86_64.*[v]disk.qcow2" >/dev/null 2>&1; }

start_vm() {
    if running; then
        note "a VM for $VDISK is already running; this test drives the boot itself"
        return 1
    fi
    mkdir -p "$OUT_DIR"
    BOOT_DISK=1 HEADLESS=1 MONITOR="$MON" SERIAL="$OUT_DIR/serial.log" SSH_PORT="$SSH_PORT" \
        setsid "$PROFILE_DIR/scripts/run-iso.sh" >"$OUT_DIR/qemu.log" 2>&1 &
    wait_for_ssh 240
}

stop_vm() {
    [ "$KEEP_UP" = 1 ] && return 0
    as_root 'poweroff' >/dev/null 2>&1
    for _ in $(seq 1 20); do running || break; sleep 0.5; done
    running && "$PROFILE_DIR/scripts/qemu-mon.py" --socket "$MON" --gap 0.4 "quit" >/dev/null 2>&1
    return 0
}

# The line rEFInd boots without a keypress. Writing it is how this test chooses a
# boot without a keyboard; the install's own entry is what a user's default is.
set_default_selection() { # set_default_selection <menuentry title>
    as_root "sed -i 's/^default_selection .*/default_selection \"$1\"/' /efi/EFI/refind/refind.conf && sync"
}

reboot_guest() {
    as_root '(sleep 2; reboot) >/dev/null 2>&1 &' >/dev/null
    sleep 20
}

trap stop_vm EXIT

[ -f "$VDISK" ] || { echo "no $VDISK — run  make -C docker test-one  first" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# ── 1. boot the installed system the way it normally boots ────────────────────
step "boot the installed system"
start_vm || exit 1
root_subvol="$(default_subvol)"
echo "  default subvolume: ${root_subvol:-none}"
check "the disk holds an installed system" test -n "$root_subvol"
check "the live root is a numbered snapshot (the layout snapper rollback needs)" \
    bash -c '[[ "$1" == */.snapshots/[0-9]*/snapshot ]]' _ "$root_subvol"

if [ "$(as_root 'systemctl is-enabled sshd 2>&1')" != "enabled" ]; then
    as_root 'systemctl enable sshd.service' >/dev/null
    note "enabled sshd so a booted snapshot is reachable (openssh ships with the desktop set)"
fi
check "the installed system is reachable over SSH" as_root 'true'

install_entry="$(as_root "grep -hm1 -oE '^menuentry \"[^\"]+\"' /efi/EFI/refind/aelum/*.conf | grep -v 'Aelum snapshot' | sed -e 's/^menuentry //' -e 's/\"//g'" | head -1)"
echo "  install entry: ${install_entry:-none}"
check "the install's own menu entry exists" test -n "$install_entry"

# ── 2. a state the snapshot will not have ────────────────────────────────────
step "take a snapshot, then change the live system"
snapshot="$(as_root "snapper -c root create -t single -d 'rollback acceptance test' -c number -u important=yes" | tr -dc '0-9')"
if [ -z "$snapshot" ]; then
    # snapper prints the number it made; if it did not, read it back off the tree.
    snapshot="$(as_root 'ls -1 /.snapshots | grep -E "^[0-9]+$" | sort -n | tail -1')"
fi
[ -n "${SNAPSHOT:-}" ] && snapshot="$SNAPSHOT"
echo "  snapshot: ${snapshot:-none}"
check "a snapshot of the current system was taken" bash -c '[[ "$1" =~ ^[0-9]+$ ]]' _ "$snapshot"

as_root "printf 'written after the snapshot\n' > $MARKER && sync"
check "the live system now has something the snapshot does not" as_root "test -f $MARKER"

# The menu is what a user boots, so the installed system's own generator writes
# it; this test only reads the entry it produced.
as_root '/usr/local/bin/aelum-refind-snapshots' >/dev/null
entry="$(as_root "grep -hoE '^menuentry \"Aelum snapshot $snapshot[^\"]*\"' /efi/EFI/refind/aelum/*.conf" | head -1 |
         sed -e 's/^menuentry //' -e 's/^"//' -e 's/"$//')"
echo "  menu entry: ${entry:-none}"
check "the menu offers the snapshot" test -n "$entry"

# ── 3. boot it ────────────────────────────────────────────────────────────────
step "boot the snapshot"
set_default_selection "$entry"
reboot_guest
if ! wait_for_ssh 180; then
    bad "the snapshot did not come up (no SSH from a booted snapshot)"
    exit 1
fi
booted="$(as_root 'findmnt -n -o SOURCE /' | subvol_of)"
echo "  booted root: ${booted:-none}"
check "the running root is the snapshot, not the default subvolume" \
    bash -c '[[ "$1" == *"/.snapshots/$2/snapshot" && "$1" != "$3" ]]' _ "$booted" "$snapshot" "$root_subvol"
check_not "the snapshot is read-only where it matters" as_root "touch /root/.aelum-write-probe"
check "the history is mounted" as_root 'findmnt -n -o SOURCE /.snapshots'
home_src="$(as_root 'findmnt -n -o SOURCE /home')"
case "$home_src" in
    *".snapshots"*) bad "/home is the snapshot's own, not the live one ($home_src)" ;;
    "")             bad "/home is not mounted in a snapshot boot" ;;
    *)              ok "/home is the live subvolume ($home_src)" ;;
esac
state_ok=1
for dir in /var/lib/systemd /var/lib/greeter; do
    as_root "findmnt -n -o SOURCE $dir" | grep -q tmpfs || state_ok=0
done
[ "$state_ok" = 1 ] && ok "the state directories a snapshot boot needs are writable (tmpfs)" ||
    bad "a state directory a snapshot boot needs is not writable (see configure/snapshot_state.go)"
check "the greeter is reached, not a text login" as_root 'systemctl is-active greetd | grep -q active'
check "the network is up (this session is over it)" as_root 'true'

# What the desktop prompt is built from: the generator announced this boot and
# named the snapshot, and the prompt's unit + config are installed system-side
# (/etc/xdg/quickshell + /etc/systemd/user), so they belong to the system and
# not to any one account - and they are inside the very snapshot being booted.
# The unit itself is only observable in a graphical session; the marker and the
# files are the parts this test can assert, and the next step drives the exact
# command the OK button runs.
marker="$(as_root 'cat /run/aelum-snapshot-boot 2>/dev/null')"
check "the snapshot boot announced itself with this snapshot's number" \
    bash -c '[[ "$1" == "SNAPSHOT=$2" ]]' _ "$marker" "$snapshot"
check "the restore prompt is installed system-side" \
    as_root "test -f /etc/xdg/quickshell/aelum-snapshot/shell.qml"
# The pull-in is the home's wants link (seeded by /etc/skel), not a
# system-side one: this booted user's session is what starts the prompt unit,
# and the greeter - which must not be asked - has no such link.
check "this user's session target wants the prompt" \
    as_root "test -e /home/$USERNAME/.config/systemd/user/hyprland-session.target.wants/aelum-snapshot-prompt.service"
check "there is no system-side pull-in (the greeter is not asked)" \
    as_root "test ! -e /etc/systemd/user/hyprland-session.target.wants/aelum-snapshot-prompt.service"

# What a snapshot boot costs, reported rather than asserted: the point is knowing
# which services fail a step and which only log. Recorded in SNAPSHOT_RESTORE.md.
step "what a snapshot boot logs"
as_root "journalctl -b --no-pager 2>/dev/null | grep -i 'Read-only file system' | sed 's/^.[0-9]* [0-9:.]* //' | sort -u | head -20" |
    sed 's/^/    /'

# ── 4. roll back from inside it ───────────────────────────────────────────────
step "the prompt's OK path: pkexec aelum-snapshot-restore, and its polkit scope"
# The desktop's OK button runs `pkexec <helper>` from the active graphical
# session, and the installed polkit rule grants it there: local, active, admin.
# This SSH session is local but not active, so the same pkexec must be refused -
# the scope is part of the feature, and a session that could never have shown
# the dialog must not be able to answer it either. The unknown argument keeps
# this safe either way: if the refusal were broken, the helper would print its
# usage and roll nothing back.
scope_out="$(as_user 'pkexec /usr/local/bin/aelum-snapshot-restore --scope-probe')"
printf '%s\n' "$scope_out" | sed 's/^/    /'
check "pkexec from this inactive session is refused (the grant is for active sessions)" \
    bash -c 'grep -qiE "not authorized|authorization" <<<"$1"' _ "$scope_out"
check "the refusal ran no helper (its usage line would mean it ran)" \
    bash -c '! grep -q "usage: aelum-snapshot-restore" <<<"$1"' _ "$scope_out"
# The exact command pkexec execs, run as root the way pkexec execs it.
before_default="$root_subvol"
rollback_out="$(as_root '/usr/local/bin/aelum-snapshot-restore')"
printf '%s\n' "$rollback_out" | sed 's/^/    /'
check "snapper took the classic ambit" grep -qi 'Ambit is classic' <<<"$rollback_out"
check "snapper made the undo snapshot (a copy of the state that was broken)" \
    grep -qi 'read-only snapshot of default subvolume' <<<"$rollback_out"
check "snapper made a writable copy of the snapshot it was booted in" \
    grep -qi 'read-write snapshot of current subvolume' <<<"$rollback_out"
check "snapper repointed the default subvolume" grep -qi 'Setting default subvolume' <<<"$rollback_out"
new_default="$(default_subvol)"
echo "  default subvolume now: ${new_default:-none}"
check "the default subvolume moved to a new snapshot" \
    bash -c '[[ -n "$1" && "$1" != "$2" && "$1" == */.snapshots/[0-9]*/snapshot ]]' _ "$new_default" "$before_default"

# ── 5. reboot through the install's own entry ─────────────────────────────────
step "reboot into the restored system"
set_default_selection "$install_entry"
reboot_guest
if ! wait_for_ssh 180; then
    bad "the restored system did not come up"
    exit 1
fi
restored="$(as_root 'findmnt -n -o SOURCE /' | subvol_of)"
echo "  restored root: ${restored:-none}"
check "the default entry boots the restored system" bash -c '[[ "$1" == "$2" ]]' _ "$restored" "$new_default"
check "the restored root is writable" as_root 'touch /root/.aelum-write-probe && rm -f /root/.aelum-write-probe'
check_not "the marker written after the snapshot is gone (the state we chose came back)" \
    as_root "test -f $MARKER"
check_not "the restored system does not announce a snapshot boot (the prompt stays quiet)" \
    as_root 'test -e /run/aelum-snapshot-boot'

# ── 6. the history and the menu are still consistent ──────────────────────────
step "the history and the boot menu after a rollback"
check "snapper works in the restored system" as_root 'snapper -c root list'
snapper_list="$(as_root 'snapper -c root list 2>/dev/null')"
check "the undo snapshot is listed (the rollback is itself undoable)" \
    bash -c 'grep -q "rollback backup of" <<<"$1"' _ "$snapper_list"
check "snapper calls the restored system the default" \
    bash -c 'grep -qE "^[[:space:]]*[0-9]+\*" <<<"$1"' _ "$snapper_list"
entry_roots="$(as_root "grep -hoE 'rootflags=subvol=[^ \"]+' /efi/EFI/refind/aelum/*.conf" | sed 's/^rootflags=subvol=//' | sort -u)"
subvols="$(as_root 'btrfs subvolume list / | awk "{print \$NF}"')"
bad_roots=""
for want in $entry_roots; do grep -qxF "$want" <<<"$subvols" || bad_roots="$bad_roots $want"; done
if [ -z "$entry_roots" ]; then
    bad "no snapshot entry names a root subvolume"
elif [ -n "$bad_roots" ]; then
    bad "the menu names subvolumes that are not in the filesystem tree:$bad_roots"
else
    ok "every snapshot entry still names a subvolume that exists ($(printf '%s\n' "$entry_roots" | grep -c .) of them)"
fi
check_not "the menu does not offer the system the user is in" \
    bash -c 'grep -qF "rootflags=subvol=${1#/}" <<<"$2"' _ "$new_default" "$entry_roots"

echo
if [ "$fails" = 0 ]; then
    echo "SNAPSHOT ROLLBACK: PASS (snapshot $snapshot -> $new_default)"
    exit 0
fi
echo "SNAPSHOT ROLLBACK: FAIL ($fails check(s) failed)"
exit 1
