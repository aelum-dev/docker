#!/usr/bin/env bash
set -euo pipefail

# extract-snapshot-generator.sh — write out the shell scripts the installer embeds
# in its Go source, exactly as it would install them.
#
#   ./scripts/extract-snapshot-generator.sh            # both, into logs/snapshot-menu/
#   OUT=/tmp/gen.sh ./scripts/extract-snapshot-generator.sh   # only the menu generator
#   STATE_OUT=/tmp/state.sh ./scripts/extract-snapshot-generator.sh   # only the state generator
#
# They live in the installer's Go source as constants
# (backend/install/configure/{refind_snapshots,snapshot_state}.go), so reading
# them means running the package's tests with a throwaway test file that dumps
# them. The Go file is removed again on the way out; nothing in the installer tree
# is left changed.
#
# What they are for: the Go tests check the text of the scripts. Running the
# scripts themselves (see fake-snapshot-menu.sh and fake-snapshot-state.sh) checks
# that the text still works as shell.

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DISTRO_DIR="$(cd "$PROFILE_DIR/.." && pwd)"
INSTALLER_DIR="${INSTALLER_DIR:-$DISTRO_DIR/installer}"
OUT="${OUT:-$PROFILE_DIR/logs/snapshot-menu/aelum-refind-snapshots.sh}"
STATE_OUT="${STATE_OUT:-$PROFILE_DIR/logs/snapshot-menu/aelum-snapshot-state.sh}"

[ -d "$INSTALLER_DIR/backend/install/configure" ] || {
    echo "installer repo not found at $INSTALLER_DIR (set INSTALLER_DIR)" >&2
    exit 1
}

PKG_DIR="$INSTALLER_DIR/backend/install/configure"
TMP_GO="$PKG_DIR/zz_extract_snapshot_menu_test.go"

if [ -e "$TMP_GO" ]; then
    echo "refusing to run: $TMP_GO already exists" >&2
    exit 1
fi

# go test writes into the package directory, so the throwaway file has to live
# there. Remove it whatever happens, including a failed build.
cleanup() { rm -f "$TMP_GO"; }
trap cleanup EXIT

cat >"$TMP_GO" <<'GO'
package configure

import (
	"os"
	"testing"
)

// Not a test of behaviour: it dumps the embedded shell scripts so they can be run
// on their own (docker/scripts/fake-snapshot-menu.sh,
// docker/scripts/fake-snapshot-state.sh). The paths come from the environment
// because `go test` does not take arguments.
func TestZZExtractSnapshotScripts(t *testing.T) {
	menu := os.Getenv("SNAPSHOT_MENU_OUT")
	state := os.Getenv("SNAPSHOT_STATE_OUT")
	if menu == "" && state == "" {
		t.Fatal("neither SNAPSHOT_MENU_OUT nor SNAPSHOT_STATE_OUT is set")
	}
	if menu != "" {
		if err := os.WriteFile(menu, []byte(snapshotMenuScript), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if state != "" {
		if err := os.WriteFile(state, []byte(snapshotStateGenerator), 0o755); err != nil {
			t.Fatal(err)
		}
	}
}
GO

mkdir -p "$(dirname "$OUT")" "$(dirname "$STATE_OUT")"
if ! (cd "$INSTALLER_DIR" && SNAPSHOT_MENU_OUT="$OUT" SNAPSHOT_STATE_OUT="$STATE_OUT" go test ./backend/install/configure/ \
        -run TestZZExtractSnapshotScripts -count=1 >/dev/null); then
    echo "go test failed (see the installer package build errors above)" >&2
    exit 1
fi

# Each requested output is checked and chmod'd the same way: a script that is not
# executable is a generator systemd never runs.
check_script() { # <path> <label>
    local path=$1 label=$2
    if ! head -n 1 "$path" | grep -q '^#!'; then
        echo "no script in $path ($label: the test output was not the generator)" >&2
        cat "$path" >&2
        exit 1
    fi
    chmod +x "$path"
    sh -n "$path" && echo "extracted: $path ($(wc -l <"$path") lines, shell syntax ok)"
}

check_script "$OUT" "boot-menu generator"
check_script "$STATE_OUT" "snapshot state generator"
