#!/usr/bin/env bash
set -uo pipefail

# fake-snapshot-state.sh — run the snapshot-boot state generator against a
# fixture, on the host, with no disk and no root.
#
#   ./scripts/fake-snapshot-state.sh
#   GEN=/tmp/state.sh ./scripts/fake-snapshot-state.sh
#
# What it checks is the one decision the generator makes: the subvolume the root is
# on is the one the system normally boots (an ordinary boot — write nothing) or it
# is not (a snapshot boot — write a tmpfs mount for each state directory). The
# generator reads both halves from the running system, so the fixture feeds it real
# mountinfo and `btrfs subvolume get-default` output captured from a real install
# and a real snapshot boot of it. The seams only choose where the information comes
# from; the parsing — which is where this once went wrong, by looking for
# `subvolid=` at the start of a field when it lives inside a comma-separated one —
# is still the generator's.
#
# The generator is called the way systemd calls it: the unit directory first, then
# the two more directories systemd actually passes. A generator that only works when
# it is called the way a test calls it fails on every real boot.
#
# This is not the installer's test suite (those check the text of the generator).
# It runs the generator as shell, which is the only way to catch a unit named
# something systemd would refuse, or a mount unit written for a boot that is not a
# snapshot.

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GEN="${GEN:-$PROFILE_DIR/logs/snapshot-menu/aelum-snapshot-state.sh}"
KEEP="${KEEP:-0}"

fails=0
ok()   { echo "  ok   - $*"; }
bad()  { echo "  FAIL - $*"; fails=$((fails + 1)); }
check() { # check <description> <command...>
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc  [$*]"; fi
}
absent() { # absent <description> <pattern> <file>
    local desc=$1 pat=$2 file=$3
    if LC_ALL=C grep -qE "$pat" "$file" 2>/dev/null; then bad "$desc"; else ok "$desc"; fi
}

if [ ! -x "$GEN" ]; then
    echo "extracting the installed scripts from the installer source ..."
    STATE_OUT="$GEN" "$PROFILE_DIR/scripts/extract-snapshot-generator.sh" || exit 1
fi
[ -r "$GEN" ] || { echo "no generator to run: $GEN" >&2; exit 1; }

FAKE=$(mktemp -d /tmp/aelum-fake-snapshot-state.XXXXXX)
[ "$KEEP" = 1 ] || trap 'rm -rf "$FAKE"' EXIT
GENDIR="$FAKE/generator"
UNIT_SYS="$GENDIR/var-lib-systemd.mount"
UNIT_GREETER="$GENDIR/var-lib-greeter.mount"

# Captured from the test install: the entry for / in /proc/self/mountinfo, in an
# ordinary boot and in a snapshot boot of the same disk, and the output of
# `btrfs subvolume get-default` on it. The two mountinfo lines differ in exactly
# one number, which is the whole difference between the two boots.
MI_NORMAL='25 24 0:32 /@/.snapshots/1/snapshot / ro,relatime master:1 - btrfs /dev/vda2 rw,discard=async,space_cache=v2,subvolid=263,subvol=/@/.snapshots/1/snapshot'
MI_SNAPSHOT='25 24 0:32 /@/.snapshots/5/snapshot / ro,relatime master:1 - btrfs /dev/vda2 rw,discard=async,space_cache=v2,subvolid=270,subvol=/@/.snapshots/5/snapshot'
# A root that is not a btrfs subvolume at all (a live ISO, an initrd): the answer
# has to be "I do not know", which is treated as an ordinary boot.
MI_OTHER='36 35 0:33 / / ro,relatime shared:1 - overlay overlay rw,lowerdir=/airootfs,upperdir=/tmp/overlay/upper,workdir=/tmp/overlay/work'
GET_DEFAULT='ID 263 gen 24 top level 262 path @/.snapshots/1/snapshot'

printf '%s\n' "$MI_NORMAL"   > "$FAKE/mountinfo-normal"
printf '%s\n' "$MI_SNAPSHOT" > "$FAKE/mountinfo-snapshot"
printf '%s\n' "$MI_OTHER"    > "$FAKE/mountinfo-other"
printf '%s\n' "$GET_DEFAULT" > "$FAKE/get-default"

reset_dir() { rm -rf "$GENDIR"; mkdir -p "$GENDIR"; }

# run <label> <mountinfo file> — called the way systemd calls a generator: the
# unit directory first, then the two directories systemd adds.
run() {
    local label=$1 mi=$2
    AELUM_MOUNTINFO="$mi" AELUM_GET_DEFAULT="cat $FAKE/get-default" \
        sh "$GEN" "$GENDIR" "$FAKE/generator.early" "$FAKE/generator.late" \
        >"$FAKE/$label.out" 2>"$FAKE/$label.err"
    local rc=$?
    [ "$rc" = 0 ] && ok "$label: exits 0" || bad "$label: exited $rc: $(cat "$FAKE/$label.err")"
}

units() { ls -1 "$GENDIR" 2>/dev/null | grep '\.mount$' | tr '\n' ' '; }
requires() { ls -1 "$GENDIR/local-fs.target.requires" 2>/dev/null | tr '\n' ' '; }

echo "== an ordinary boot: the root is the subvolume the system normally boots =="
reset_dir
run ordinary "$FAKE/mountinfo-normal"
[ -z "$(units)" ] && ok "no unit written (got: $(units))" || bad "units written for an ordinary boot: $(units)"
[ ! -d "$GENDIR/local-fs.target.requires" ] && ok "no pull-in either" || bad "local-fs.target.requires written for an ordinary boot"

echo "== a snapshot boot: the root is some other subvolume =="
reset_dir
run snapshot "$FAKE/mountinfo-snapshot"
check "var-lib-systemd.mount written for logind's state directory" test -f "$UNIT_SYS"
check "var-lib-greeter.mount written for the greeter's state directory" test -f "$UNIT_GREETER"
[ "$(units)" = "var-lib-greeter.mount var-lib-systemd.mount " ] &&
    ok "one unit per state directory, and nothing else (got: $(units))" || bad "units written: $(units)"
check "the unit is a tmpfs" grep -qE '^Type=tmpfs$' "$UNIT_SYS"
check "it mounts tmpfs" grep -qE '^What=tmpfs$' "$UNIT_SYS"
check "its Where= is the path in the running system" grep -qE '^Where=/var/lib/systemd$' "$UNIT_SYS"
check "its name is what systemd expects for that path" \
    bash -c '[[ "$(basename "$1")" == "$(echo "${2#/}" | tr / -).mount" ]]' _ "$UNIT_SYS" /var/lib/systemd
# The window a fstab mount gets, plus the unit this all exists for: without this
# ordering the mount lands after systemd-logind has already failed.
check "it is ordered before local-fs.target and before systemd-logind" \
    grep -qE '^Before=local-fs\.target systemd-logind\.service$' "$UNIT_SYS"
check "it is ordered after local-fs-pre.target" grep -qE '^After=local-fs-pre\.target$' "$UNIT_SYS"
# A snapshot that predates the directory: mount(8) can create the mount point,
# nothing else on a read-only root can.
check "it creates the mount point if the snapshot does not have one" \
    grep -qE '^Options=.*X-mount\.mkdir' "$UNIT_SYS"
# Writing a mount unit does not start it: a mount unit runs when something
# requires it. systemd's own generators link them from
# local-fs.target.requires/, and so does this one. Measured on a real snapshot
# boot: /var/lib/systemd was mounted only because systemd-logind and five other
# units have RequiresMountsFor= on it, and /var/lib/greeter - which nobody asks
# for - stayed inactive while tmpfiles.d failed to chmod it.
check "local-fs.target requires the unit (otherwise it is never started)" \
    test -L "$GENDIR/local-fs.target.requires/var-lib-systemd.mount"
check "the pull-in resolves to the unit that was written" \
    test -e "$GENDIR/local-fs.target.requires/var-lib-systemd.mount"
check "the greeter's state directory is pulled in too" \
    test -L "$GENDIR/local-fs.target.requires/var-lib-greeter.mount"
[ "$(requires)" = "var-lib-greeter.mount var-lib-systemd.mount " ] &&
    ok "one pull-in per state directory, and nothing else (got: $(requires))" ||
    bad "local-fs.target.requires holds: $(requires)"
absent "it is not a service" '^\[Service\]' "$UNIT_SYS"
absent "it does not decide with ConditionPathIsReadWrite (unmet in a real snapshot boot)" 'ConditionPathIsReadWrite' "$UNIT_SYS"

echo "== a root that is not a btrfs subvolume: unknown means an ordinary boot =="
reset_dir
run other "$FAKE/mountinfo-other"
[ -z "$(units)" ] && ok "no unit written (got: $(units))" || bad "units written for a root with no subvolume id: $(units)"

echo "== asked about the running system, with no help from the fixture =="
# The real invocation: no seams set, so the generator reads /proc/self/mountinfo
# and btrfs itself. Whatever the host's root is, a generator must not fail a boot.
reset_dir
AELUM_MOUNTINFO=/proc/self/mountinfo AELUM_GET_DEFAULT="btrfs subvolume get-default /" \
    sh "$GEN" "$GENDIR" "$FAKE/generator.early" "$FAKE/generator.late" \
    >"$FAKE/unseeded.out" 2>"$FAKE/unseeded.err"
rc=$?
[ "$rc" = 0 ] && ok "unseeded: exits 0 (units: $(units))" || bad "unseeded: exited $rc: $(cat "$FAKE/unseeded.err")"

echo "== nowhere to write =="
reset_dir
rm -rf "$GENDIR"
run nogendir "$FAKE/mountinfo-snapshot"
[ ! -e "$UNIT_SYS" ] && ok "nothing was written" || bad "a unit was written with no generator directory"

echo "== running it twice writes the same units =="
reset_dir
run first "$FAKE/mountinfo-snapshot"
cp "$UNIT_SYS" "$FAKE/first.mount"
run second "$FAKE/mountinfo-snapshot"
check "the unit is identical" cmp -s "$FAKE/first.mount" "$UNIT_SYS"

echo
if [ "$fails" = 0 ]; then
    echo "all checks passed"
    [ "$KEEP" = 1 ] && echo "fixture kept: $FAKE"
    exit 0
fi
echo "$fails check(s) failed"
[ "$KEEP" = 1 ] && echo "fixture kept: $FAKE"
exit 1
