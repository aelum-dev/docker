#!/usr/bin/env bash
set -uo pipefail

# fake-snapshot-restore.sh — run the snapshot-restore helper the live ISO ships,
# against a fixture, on the host, with no disk and no root.
#
#   ./scripts/fake-snapshot-restore.sh
#   HELPER=/tmp/aelum-snapshot-restore ./scripts/fake-snapshot-restore.sh
#
# The helper is source in the live ISO (airootfs/usr/local/bin/aelum-snapshot-restore)
# and the installer copies it unchanged, so this is the only place its *behaviour* is
# checked: the installer's own tests assert the text of the files it writes, and there
# is no such text here any more. What it runs is the exact command the prompt's OK
# button runs, and what it checks is the two things a wrong answer would cost:
#
#   - running a rollback from an ordinary boot, which would roll the system back onto
#     itself (snapper rollback with no number means "the state I am booted in");
#   - taking a second rollback when the caller only asked for a reboot, which would
#     leave an undo snapshot of a system that is already restored.
#
# snapper and systemctl are stubbed on PATH and record their argv; AELUM_SNAPSHOT_MARKER
# is the helper's own seam for the /run marker, the same reason the menu generator
# takes --root. The parsing and the decisions in between are the helper's.

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DISTRO_DIR="$(cd "$PROFILE_DIR/.." && pwd)"
LIVE_ISO_DIR="${LIVE_ISO_DIR:-$DISTRO_DIR/live-iso}"
HELPER="${HELPER:-$LIVE_ISO_DIR/airootfs/usr/local/bin/aelum-snapshot-restore}"
KEEP="${KEEP:-0}"

fails=0
ok()  { echo "  ok   - $*"; }
bad() { echo "  FAIL - $*"; fails=$((fails + 1)); }

FAKE=$(mktemp -d /tmp/aelum-fake-snapshot-restore.XXXXXX)
[ "$KEEP" = 1 ] || trap 'rm -rf "$FAKE"' EXIT
BIN="$FAKE/bin"
mkdir -p "$BIN"

if [ ! -f "$HELPER" ]; then
    echo "no shipped helper to run: $HELPER (set LIVE_ISO_DIR or HELPER)" >&2
    exit 1
fi

# The mode pkexec requires of any program an action execs: executable, and not
# group- or world-writable. mkarchiso only applies modes it is told about, so this
# is also what profiledef.sh's file_permissions entry has to keep true in the ISO.
mode=$(stat -c '%a' "$HELPER")
if [ $(( 0$mode & 0111 )) -eq 0 ]; then
    bad "the shipped helper is not executable ($mode)"
elif [ $(( 0$mode & 0022 )) -ne 0 ]; then
    bad "the shipped helper is group/world-writable ($mode): pkexec refuses to exec it"
else
    ok "the shipped helper has a mode pkexec accepts ($mode)"
fi

cat > "$BIN/snapper" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >> "$SNAPPER_LOG"
printf 'Ambit is classic\nread-only snapshot of default subvolume\nread-write snapshot of current subvolume\nSetting default subvolume\n'
SH

cat > "$BIN/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >> "$SYSTEMCTL_LOG"
SH

# A stub `id` is how the non-root case is reachable from a host that is root: the
# helper asks the same question pkexec answers it with.
cat > "$BIN/id" <<'SH'
#!/bin/sh
if [ "$1" = "-u" ]; then printf '%s\n' "${FAKE_UID:-0}"; else command id "$@"; fi
SH

chmod 755 "$BIN/snapper" "$BIN/systemctl" "$BIN/id"

MARKER="$FAKE/boot-marker"
SNAPPER_LOG="$FAKE/snapper.argv"
SYSTEMCTL_LOG="$FAKE/systemctl.argv"

# run <label> <args...> — the helper is run the way the prompt runs it: as root, with
# the marker in place unless the case says otherwise.
run() {
    local label=$1; shift
    : > "$SNAPPER_LOG"; : > "$SYSTEMCTL_LOG"
    out=$(PATH="$BIN:$PATH" SNAPPER_LOG="$SNAPPER_LOG" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        AELUM_SNAPSHOT_MARKER="$MARKER" "$HELPER" "$@" 2>&1)
    code=$?
    printf '    %s\n' "$out" | sed 's/^/      /'
    echo "    [$label: exit $code]"
}

snapper_called() { [ -s "$SNAPPER_LOG" ]; }
systemctl_called() { [ -s "$SYSTEMCTL_LOG" ]; }

echo "helper: $HELPER"

section() { echo; echo "── $*"; }

section "an ordinary boot refuses (no marker)"
rm -f "$MARKER"
run "no marker"
[ "$code" -ne 0 ] && ok "refused with a non-zero exit" || bad "an ordinary boot was not refused"
grep -qi 'not a snapshot' <<<"$out" && ok "the refusal names the reason" || bad "the refusal did not say why"
! snapper_called && ok "no rollback was attempted" || bad "it rolled back without a snapshot boot"

section "a snapshot boot runs the rollback the OK button asks for"
: > "$MARKER"
printf 'SNAPSHOT=7\n' > "$MARKER"
run "rollback"
[ "$code" -eq 0 ] && ok "the rollback succeeded" || bad "the rollback failed (exit $code)"
grep -qxF -- '--no-dbus' "$SNAPPER_LOG" && grep -qxF -- 'rollback' "$SNAPPER_LOG" &&
    grep -qxF -- 'root' "$SNAPPER_LOG" && ok "snapper ran: -c root rollback, --no-dbus" ||
    bad "snapper argv was not the rollback the polkit action names: $(tr '\n' ' ' < "$SNAPPER_LOG")"
! systemctl_called && ok "it did not reboot on its own" || bad "it rebooted when nothing asked it to"

section "--reboot rolls back and reboots (the terminal spelling)"
run "--reboot" --reboot
snapper_called && systemctl_called && ok "rollback then reboot" || bad "expected a rollback and a reboot"

section "--reboot-only only reboots (the prompt's REBOOT button)"
run "--reboot-only" --reboot-only
! snapper_called && ok "no second rollback, so no second undo snapshot" || bad "it rolled back again: $(tr '\n' ' ' < "$SNAPPER_LOG")"
systemctl_called && ok "it rebooted" || bad "it did not reboot"

section "an unknown argument is a usage error"
run "unknown" --scope-probe
[ "$code" -ne 0 ] && ok "refused with a non-zero exit" || bad "an unknown argument was accepted"
grep -q 'usage: aelum-snapshot-restore' <<<"$out" && ok "it printed its usage" || bad "it said nothing about its usage"
! snapper_called && ok "nothing was rolled back" || bad "an unknown argument still ran the rollback"

section "it must run as root"
rm -f "$MARKER"
: > "$MARKER"
FAKE_UID=1000 out=$(PATH="$BIN:$PATH" SNAPPER_LOG="$SNAPPER_LOG" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    AELUM_SNAPSHOT_MARKER="$MARKER" FAKE_UID=1000 "$HELPER" 2>&1)
code=$?
printf '    %s\n' "$out" | sed 's/^/      /'
[ "$code" -ne 0 ] && ok "a non-root run was refused" || bad "a non-root run was accepted"
! snapper_called && ok "it did not try the rollback as a normal user" || bad "it ran snapper as a normal user"

echo
if [ "$fails" -eq 0 ]; then
    echo "FAKE RESTORE: PASS"
    exit 0
fi
echo "FAKE RESTORE: FAIL ($fails check(s) failed)"
exit 1
