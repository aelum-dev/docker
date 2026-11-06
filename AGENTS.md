# Aelum docker — Agent Context

This repo builds every Aelum ISO (`output/aelum-*.iso`), runs the QEMU test matrix against
`vdisk.qcow2`, and publishes releases. `README.md` is for users, `RELEASE.md` is the release
reference; this file holds the build rules an agent must not relearn the expensive way. Cross-repo
rules (live ISO vs installed system, where root work happens, artifacts are never source, the guest
gotchas) are in the workspace-root `AGENTS.md`.

## Which build command to use (read before starting any build)

- **Iterating on a feature and testing it in a bootable ISO → `make local-dev`, then
  `./build-iso.sh` inside the container.** `aelum-local-shell` bind-mounts the real
  `installer/` + `live-iso/` working trees and **keeps its pacman package cache and AUR build cache
  warm across runs**, so a rebuild after a small change re-downloads only what changed; the offline
  mirror is rebuilt from the current resolution every run, so the warm loop never ships older
  packages (see *The pipeline* step 5). This is the normal loop. Re-running `make local-dev`
  re-attaches to the same container.
- **`make local-build` and `make build` are one-shot containers** (`docker compose run --rm`): every
  cache dies with the container, so each run re-downloads the full package set from the internet —
  slow on a metered line. Use them only when you actually want a clean throwaway build (e.g. the
  final ISO before a release), not to test a change you just made.
- `local-build` stages copies in `/tmp/aelum-local-build` (`stage-local-repos.sh`, excluding `.git`,
  `live-iso/work`, the offline mirror, installer build output, `node_modules`) and never writes your
  real trees; `local-dev` mounts them, so build outputs *do* appear in them and the script chowns
  them back to you after each run. `LOCAL_STAGE=` moves the stage, `AELUM_LIVE_ISO_SRC` /
  `AELUM_INSTALLER_SRC` point at non-sibling checkouts, `make local-clean` removes the stage.
- A build killed halfway can leave root-owned files in the stage or a leftover `aelum*` container
  holding it busy. Clean with `make local-clean` (and `docker rm <container>` if it reports "Device or
  resource busy") before retrying.
- Never run two ISO builds at once: they share the image, the stage dir, and `output/`.

## After the ISO exists

Tests run on the host against QEMU, not inside Docker (see root `AGENTS.md` → "Where to run anything
that needs root"): `make test-one …`, `make test-boot`, `make snapshot-rollback`,
`./scripts/fake-snapshot-*.sh` (host-only fixtures, no root). The guest's disk is
`docker/vdisk.qcow2` = `/dev/vda`; the installed test system is throwaway — fix the source, rebuild
(via `local-dev`), and re-run the test.

## The pipeline (`scripts/build-iso.sh`, inside the container)

1. Gets the two repos: clones them, or uses the bind-mounted local trees when `SKIP_REPO_CLONE=1`.
   Either way the rest of the script works on `/app/live-iso` + `/app/installer`.
2. Builds the installer and copies `aelum-installer{,-cli}` into `live-iso/airootfs/usr/local/bin/`.
3. `pacman -Syw --dbpath <empty dir> --cachedir <offline cache>` — a blank DB on purpose, so only the
   dependency trees of `packages.x86_64` **plus the installer's own package lists** are pulled, not
   the whole world — the second set comes from `go run ./backend/scripts/pkg-list.go` in the installer
   tree, so the mirror is exactly "what the live session runs ∪ what an install writes" and neither
   list is duplicated by hand (live-iso/AGENTS.md → the mirror note). `pacman -S --print` then
   records the exact files the just-synced repos resolve to. Both calls run through a generated config
   (`Include = /etc/pacman.conf` + `[aelum]`, `SigLevel = Never` scoped to that repo), so the
   distro's own repository resolves too and its packages (currently `aelum-video-player` and
    `aelum-package-installer`) are baked
   into the mirror like any other. `mkarchiso` itself never sees `[aelum]` — it installs everything
   from the mirror, which is what keeps the live session and the mirror on the same versions.
4. Builds `packages.aur.x86_64` with `makepkg` as a throwaway `makepkg` user behind a local
   `[aur-local]` repo (`repo-add --prevent-downgrade`, so an older build kept in the warm PKGDEST
   can never win the DB), and resolves those names + their dependency trees the same way.
5. **The offline mirror is rebuilt from the resolved list on every run.** The download cache and
   PKGDEST stay warm — that is what makes a rebuild cheap — but they accumulate every version ever
   downloaded; copying them wholesale bakes that history into the ISO (repo-add keeps the newest per
   name in the DB but never removes superseded files, and indexes its arguments in glob order, which
   for versions like `9.3` vs `9.10` picks the older one). The mirror is emptied first, only the
   resolved files are copied in, and its DB is built fresh.
6. `mkarchiso -v -w work -o output -C pacman-offline.conf -m iso .` → `output/aelum-*.iso`,
   bind-mounted to the host and chowned via `OUTPUT_UID`/`OUTPUT_GID` (the Makefile passes the real
   `id -u`/`id -g`; the shell doesn't export them).

`CHOWN_WORKTREES=1` hands the mounted trees back to the host user **including on failure** — the next
staging pass cannot replace root-owned files. Git `safe.directory` entries are exported so Go VCS
stamping works on host-owned trees.

## Toolchain image

`aelum-image` (from `Dockerfile`) holds the whole toolchain — `git base-devel archiso go
nodejs-lts-jod npm gtk3 webkit2gtk-4.1 libsoup3 grub memtest86+` — installed once and cached; per-run
work stays in `build-iso.sh`. The Dockerfile pins `go env -w GOTOOLCHAIN=go1.26.0` because Arch's
patched go breaks wails' `go list -export` binding generation; the module pins go 1.26.0.

- `make image` / `make image NO_CACHE=1` — build or rebuild it.
- `make update` — `archlinux:latest` is a rolling daily tag, so refresh the image against the newest
  Arch packages: it stops the running containers, deletes `aelum-image`, and rebuilds with `--no-cache`.

## QEMU (`scripts/run-iso.sh`)

KVM (`-cpu host`), 4 cores, 4 GB RAM, 20 G `vdisk.qcow2` as `virtio-blk-pci` (the guest sees
`/dev/vda`), OVMF (`OVMF_VARS.fd`, created from the system template when missing), `../shared` mapped
as `/shared`, user-mode networking with SSH on host port 2222. Knobs: `XRES`/`YRES`, `UI=sdl|gtk`,
`FULLSCREEN`, `GL=0` (plain VGA), `HEADLESS=1 MONITOR=…` (no window, QEMU monitor driven +
screenshotted), `SERIAL`, `BOOT_DISK=1` (boot the installed disk, no `-cdrom` — this is `run-disk`),
`SHARED_DIR`, `SSH_PORT`, `QEMU_EXTRA`, `QEMU_QVM=0` (drop KVM).

- **`make vm-clean`** recreates `vdisk.qcow2` + `OVMF_VARS.fd`. **`make run-clean`** only drops the
  NVRAM (a corrupt `BootOrder` otherwise boots nothing).
- `test-install.sh` resets `OVMF_VARS.fd` on **auto** runs only (an install needs a clean boot order);
  **boot** runs preserve it, because `run-disk` and `snapshot-rollback` follow the entries an install
  wrote. Before an ISO boot it promotes the ISO's own firmware entry with
  `scripts/uefi-vars.py promote "QEMU DVD-ROM"`: while that variable exists OVMF boots strictly from
  it and ignores `-boot d`, and the order it rebuilds when `BootOrder` is missing puts a persisted
  install entry ahead of the CD — a boot run would otherwise boot the installed disk and hang there.
- A stale `Aelum` entry pointing at a disk that has since been recreated fails with
  `BdsDxe: … Not Found`; `make demo-snapshots` deletes the old entries and writes a fresh one instead
  of reusing them.

## Install tests (`scripts/test-install.sh`, `scripts/test-all.sh`)

- `MODE=auto` (default): headless boot, wait for `sshd`, drive `aelum-installer-cli` over SSH against
  a freshly recreated disk, run `verify-installed.sh`, stop QEMU. `MODE=boot`: leave the VM running
  with `/shared` mounted and the disk untouched — that's where a freshly built CLI from
  `installer/build/bin/` gets tested without rebuilding the ISO (`SHARED_INSTALLER=1`).
- Knobs: `MODE` `USERNAME` `USER_PASS` `ROOT_PASS` `LUKS_PASS` `SSH_PORT` `DISK_PATH` `FILESYSTEM`
  `LUKS` `LVM` `MANUAL` `VERIFY` `ISO` `SHARED_DIR` `QEMU_QVM` `QEMU_EXTRA`.
- `make test` = the full matrix `MODES` × `FILESYSTEMS` × `LUKSES` × `LVMS` (16 cells), each a fresh
  boot + install + verify, then a summary. Narrow it while iterating (`LUKSES=1 make test`). A full
  desktop install is heavy — the whole matrix takes a long time. Per-cell logs in `logs/matrix/`, plus
  `logs/test-progress.json` (the CLI's JSON progress) and `logs/qemu.log`.
- `MANUAL=1` builds a fresh-disk `--manual-layout` from the guest's geometry instead of hand-written
  JSON. A hand-written layout (see `installer/backend/shared/types.go`) designates exactly one `esp`
  and one `system` row; only those two are formatted, every other row is left untouched, and Aelum
  always gets its own ESP. Validate with `--dry-run` before a real install.

## What `verify-installed.sh` proves

Beyond the layout checks (fstab UUIDs, no pinned `subvol=`, rEFInd entry + kernel in the
per-install ESP dir, packages, user, hostname) it also proves the **package repository**
setup: the `[aelum]` block in the installed `pacman.conf` (section + `SigLevel` + `Server`
lines, and that the stock file was appended to, not rewritten), the release public key at
`/usr/share/aelum/keyring/aelum-release.gpg` (carried by an isocopy job), and that the key
is in the target's pacman keyring **valid** — a copy of the target's whole `gnupg` dir read
with `gpg --no-autostart` (pacman 7.1 + gnupg 2.5 use the classic `pubring.gpg`; the trust
lives in the target's own trustdb). `pub:f:` — signed by the Pacman Keyring Master Key —
is what `--lsign-key` produces and what pacman requires before it accepts a signature.
It also proves the target keeps **no sync database for a repository its pacman.conf does not
name**: `pacstrap -K` resolves everything through the live session's `[aelum-offline]` and
pacman writes that database under the `--root` it was given, and a stale `.db` in the sync
directory is invisible to pacman but not to anything that reads the directory — the package
manager showed a second copy of every package in it. Same checks on ext4 and btrfs — the
repository is not snapshot machinery. The publisher itself is tested on the host:
`repo/fake-repo.sh` (offline fixture) and, once published, real-pacman `-Sy`/`-Sp`/`-Sw`
against `cdn.aelum.dev/repo/…` (see `repo/REPO.md`).

It runs **inside the guest** and never calls the installer — it re-opens LUKS, mounts the installed
root read-only and asserts the on-disk result: root filesystem type; fstab mounting `/`, the ESP at
`/efi`, this install's `aelum/<id>/` at `/boot` (bind) and `@home` + `/.snapshots` on btrfs with the
right UUIDs (**no `subvol=` for `/`** — the default subvolume *is* the system, which is what a
rollback moves); LVM VG/LVs and `lvm2` after `sd-encrypt` in mkinitcpio `HOOKS`; rEFInd installed with
a per-install `<id>.conf` fragment rooting at `root=UUID=…`, never a `/dev/mapper` path; on btrfs the
snapper configs, the pre/post + important pacman hooks, `aelum-refind-snapshots` + its service + the
snapper plugin, and `<id>-snapshots.conf` included **after** the install's own entry. An ext4 install
is checked to have **none** of that. `VERIFY=0` skips it.

## Snapshot menu tests

From cheapest to real — use the cheapest one that can falsify what you changed:

| Script | What it needs | What it asserts |
|---|---|---|
| `fake-snapshot-menu.sh` | nothing (fake ESP + snapper store + stub `findmnt`) | the generated fragment: one entry, snapshots as `submenuentry`, boots the newest *pre* else the newest `important=yes`, never a `timeline` snapshot, never the subvolume the system already is, titles = number + date + type only, ASCII-only, idempotent, empty when there are no snapshots, fails when the ESP isn't mounted |
| `fake-snapshot-state.sh` | captured `mountinfo` + `get-default` output from a real install | the one decision the systemd generator makes, by **subvolume id**: ordinary boot → no units; snapshot boot → tmpfs `.mount` units named as systemd expects, ordered before `local-fs.target` and `systemd-logind.service`. Called the way systemd calls a generator (unit dir + the two extra dirs) |
| `fake-snapshot-restore.sh` | stubs on `PATH` (`snapper`, `systemctl`, `id`) | the shipped helper **from `live-iso/`** (the installer copies it unchanged): refuses in an ordinary boot without touching snapper, `--reboot-only` reboots without a second rollback, and the file mode is one `pkexec` will accept |
| `menu-shots.sh` | an install on `vdisk.qcow2` | the real menu, headless: screenshots of the menu and its submenu in `logs/menu/`; `--entry 0`, `--boot-snapshot`, `--then-boot`, `KEEP_UP=1` + `qemu-mon.py "sendkey …" "screendump …"` for manual keys |
| `make demo-snapshots` | a live ISO with the install mounted | five realistic snapshots (two pacman pre/post pairs with a file changed between them, one described) + a fresh `Aelum` firmware entry |
| `test-snapshot-rollback.sh` | a real install on `vdisk.qcow2`, VM not held by `test-boot` | the whole feature: boot a snapshot through the entry the installed system generated, assert the shape of a snapshot boot, `snapper rollback` with no number from inside it, reboot through the install's own entry, assert the restored system |

`menu-shots.sh --then-boot` matters: a menu written by an **older** installer is one boot behind it —
run it once, and the screenshots after that are current.

## Layout

```
Dockerfile                 # toolchain image (archlinux + build tooling)
docker-compose.yml         # aelum (build) + aelum-shell / aelum-local-shell (interactive)
Makefile                   # every target; `make help` prints the list
release.env(.example)      # secrets — .env is gitignored, never commit it
scripts/
  build-iso.sh             # the pipeline above (inside the container)
  stage-local-repos.sh     # stage local trees for local-build
  run-iso.sh               # QEMU launch (ISO or installed disk; HEADLESS/MONITOR for capture)
  test-install.sh          # headless QEMU + installer CLI
  test-all.sh              # the matrix + summary
  verify-installed.sh      # post-install inspection, inside the guest
  demo-snapshots.sh  menu-shots.sh  menu-shots.py  qemu-mon.py  uefi-vars.py
  extract-snapshot-generator.sh  fake-snapshot-{menu,state,restore}.sh
  test-snapshot-rollback.sh
  release.sh  sign-iso.sh  gen-release-metadata.sh  publish-iso.sh  publish-website.sh  export-wkd.sh
output/                    # the built ISO + release sidecars (bind-mounted, gitignored)
logs/                      # test artifacts (gitignored)
vdisk.qcow2  OVMF_VARS.fd  # QEMU scratch: the guest's /dev/vda and its NVRAM (gitignored)
release.ts                 # generated website metadata — committed to the website repo, not here
```

## Scratch, never source

`output/`, `logs/`, `vdisk.qcow2`, `OVMF_VARS.fd`, `release.env`, `release.ts` are generated. The
installed system on `vdisk.qcow2` is throwaway: never repair it by hand — change the source, rebuild,
re-run the test.
