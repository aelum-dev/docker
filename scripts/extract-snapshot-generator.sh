#!/usr/bin/env bash
set -euo pipefail

# extract-snapshot-generator.sh — write out the boot-menu generator exactly as
# the installer would install it at /usr/local/bin/aelum-refind-snapshots.
#
#   ./scripts/extract-snapshot-generator.sh            # -> logs/snapshot-menu/aelum-refind-snapshots.sh
#   OUT=/tmp/gen.sh ./scripts/extract-snapshot-generator.sh
#
# The script lives in the installer's Go source as a constant
# (backend/install/configure/refind_snapshots.go), so reading it means running
# the package's tests with a throwaway test file that dumps it. The Go file is
# removed again on the way out; nothing in the installer tree is left changed.
#
# What it is for: the Go tests check the text of the script. Running the script
# itself (see fake-snapshot-menu.sh) checks that the text still works as shell.

PROFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DISTRO_DIR="$(cd "$PROFILE_DIR/.." && pwd)"
INSTALLER_DIR="${INSTALLER_DIR:-$DISTRO_DIR/installer}"
OUT="${OUT:-$PROFILE_DIR/logs/snapshot-menu/aelum-refind-snapshots.sh}"

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

// Not a test of behaviour: it dumps the embedded generator so the shell script
// can be run on its own (docker/scripts/fake-snapshot-menu.sh). The path comes
// from the environment because `go test` does not take arguments.
func TestZZExtractSnapshotMenuScript(t *testing.T) {
	out := os.Getenv("SNAPSHOT_MENU_OUT")
	if out == "" {
		t.Fatal("SNAPSHOT_MENU_OUT is not set")
	}
	if err := os.WriteFile(out, []byte(snapshotMenuScript), 0o755); err != nil {
		t.Fatal(err)
	}
}
GO

mkdir -p "$(dirname "$OUT")"
if ! (cd "$INSTALLER_DIR" && SNAPSHOT_MENU_OUT="$OUT" go test ./backend/install/configure/ \
        -run TestZZExtractSnapshotMenuScript -count=1 >/dev/null); then
    echo "go test failed (see the installer package build errors above)" >&2
    exit 1
fi

if ! head -n 1 "$OUT" | grep -q '^#!'; then
    echo "no script in $OUT (the test output was not the generator)" >&2
    cat "$OUT" >&2
    exit 1
fi

chmod +x "$OUT"
sh -n "$OUT" && echo "extracted: $OUT ($(wc -l <"$OUT") lines, shell syntax ok)"
