# Aelum — Build & Run

This repo contains the **Aelum build and run pipeline**. It turns the
[Aelum profile](https://github.com/aelum-dev/live-iso) into a bootable,
fully offline Arch Linux ISO, and launches it in QEMU for testing.

All building and running of Aelum happens here — the profile repo only
holds the content that goes into the ISO.

## What it does

The build toolchain (`git`, `base-devel`, `archiso`, `go`, `nodejs`, `gtk3`,
`webkit2gtk`, `grub`, `memtest86+`) is installed once, in the cached `aelum-image`
built from `./Dockerfile` — so it is not reinstalled on every run. `scripts/
build-iso.sh` runs the rest of the pipeline inside a privileged `archlinux`
container:

1. Clones the [Aelum profile](https://github.com/aelum-dev/live-iso) and the [Aelum Installer](https://github.com/aelum-dev/installer), and builds the installer binaries
2. Downloads every official package needed (via a blank-db `pacman -Syw`, so only the dependency tree is pulled)
3. Builds the listed AUR packages and pulls each one together with its dependency tree into the offline cache
4. Assembles an offline mirror (`repo-add`) into the profile's `airootfs`
5. Runs `mkarchiso` to produce the ISO

The built ISO is written to the mounted `output/` directory.

## Requirements

- Linux host with rootful Docker (the build container is privileged) and the
  Compose v2 plugin (`docker compose`, not the legacy `docker-compose`)
- KVM support (for QEMU testing)
- ~25 GB of free disk space for the build; `make local-build` also needs ~15 GB
  free in its staging directory (`/tmp` by default)
- Network access for the Arch package download and AUR builds

## Build

```bash
make run          # launch the latest ISO in output/ in QEMU
XRES=2560 YRES=1440 make run   # override resolution
make run-clean    # delete OVMF_VARS.fd (recreated on next run) then launch
```

The toolchain image (`aelum-image`) is built from `./Dockerfile` and
cached, so the first `make build` includes the toolchain install while later
builds skip it and only redo the clones, offline-cache download, and AUR builds.
The pipeline then runs in a one-shot container and writes the ISO to `output/`.
The output directory is bind-mounted from the host, and files are handed back to
the host user automatically (via `OUTPUT_UID`/`OUTPUT_GID`, defaulting to `UID`/`GID`).

### Build from your local repos (unpushed changes)

`make build` clones the published `installer/` and `live-iso/` repos, so it
ignores uncommitted work. To build (and then `make run`) an ISO with local
changes, use:

```bash
make local-build
```

It copies `../installer` and `../live-iso` to `/tmp/aelum-local-build`
(excluding `.git`, `live-iso/work`, the offline mirror cache, installer build
output, and `node_modules`), bind-mounts those copies into the same one-shot
container with `SKIP_REPO_CLONE=1`, and writes the ISO to `output/` as usual.
Your real working trees are never written to: the container runs as root and
only touches the staged copies. The stage stays in `/tmp` for inspection and is
removed by `make local-clean`; `LOCAL_STAGE=...` moves it (use a filesystem
with ~15 GB free if `/tmp` is a small tmpfs). If the repos are not siblings of
`docker/`, point at them with `AELUM_LIVE_ISO_SRC=...` /
`AELUM_INSTALLER_SRC=...`. `make build-local` is kept as an alias. For repeated iterations without
restaging or losing the container's package cache, use `make local-dev`.

### Build the toolchain image only

To (re)build just the `aelum-image` image without running the ISO
pipeline:

```bash
make image          # builds & tags aelum-image
# or, forcing a fresh build ignoring cache:
make image NO_CACHE=1   # see below
```

Equivalently with compose directly:

```bash
docker compose build aelum
# or, forcing a fresh build ignoring cache:
docker compose build --no-cache aelum
```

Rebuild with `--no-cache` whenever you change `./Dockerfile` or want to pick up
updated packages in the `archlinux:latest` base.

### Update the toolchain image to the latest Arch packages

`archlinux:latest` is a rolling daily tag, so the base image drifts over time.
To refresh the `aelum-image` against the newest Arch packages (re-pulling the
base and re-running the toolchain install), use:

```bash
make update     # rebuild aelum-image from the latest Arch base, saved
```

This stops/removes any running containers, deletes the old `aelum-image`, and
rebuilds it with `--no-cache` so it re-pulls the current `archlinux:latest` and
bakes in the updated packages. Afterward, every `make build` / `make test`
starts from the updated image. (Equivalently: `docker rmi -f aelum-image &&
docker compose build --no-cache`.)

To debug or work interactively:

```bash
make dev        # start an interactive build container (aelum-shell)
make local-dev  # same, but builds from your local installer/ + live-iso/
make attach     # attach to aelum-shell later
make stop       # stop the interactive shells
make clean      # stop + remove containers and prune volumes
```

`make local-dev` creates a persistent `aelum-local-shell` container with your
working trees bind-mounted at `/app/live-iso` and `/app/installer`, so inside
the shell you can edit on the host and just re-run `./build-iso.sh` — it skips
the GitHub clones and the container's pacman/AUR caches survive between runs.
Re-running `make local-dev` re-attaches to the same container. Unlike
`make local-build`, this mounts the real repos, so build outputs (`live-iso/work`,
the offline mirror, `installer/build/bin`) do appear in them; the script chowns
those back to you after each run. Use `make local-build` when you want an
isolated copy in `/tmp` instead. Non-sibling checkouts can be pointed at with
`AELUM_LIVE_ISO_SRC` / `AELUM_INSTALLER_SRC`.

Or run the pipeline directly:

```bash
docker compose run --rm aelum
```

The resulting ISO appears in `output/`, e.g. `output/aelum-YYYY.MM.DD-x86_64.iso`.

## Releases

The ISO is too large for GitHub Releases, so releases are published to a Cloudflare
[R2](https://developers.cloudflare.com/r2/) bucket, and the download links on
the website are updated **automatically** — no hand-editing. The pieces:

- **`scripts/sign-iso.sh`** — sign + checksum the ISO (GPG detached signature,
  SHA-256/SHA-512). Verifies everything before printing the assets to upload.
- **`scripts/publish-iso.sh`** — upload the assets to the `aelum` R2 bucket
  (`public-read`), then build and upload **`latest.json`** (machine-readable
  release metadata) to the bucket root (served publicly), and generate the
  website's **`release.ts`**.
- **`scripts/publish-website.sh`** — commit the generated `release.ts` to the
  [website](https://github.com/aelum-dev/website) repo's `main` branch, which triggers
  GitHub Pages to redeploy with the fresh download links.

### How to run (local)

The whole release runs locally — there is **no CI job** (the ISO is too large for
GitHub and the release needs your keys + your local ISO). Build the ISO first,
then:

```bash
cp release.env.example release.env   # gitignored — never commit this
$EDITOR release.env                  # fill in your R2 / GPG / website values
make build                           # → output/*.iso
make release                         # sign → upload to R2 → update website links
```

All credentials are read from `release.env` (see [RELEASE.md](RELEASE.md)) and are
never committed, so the same scripts run from any machine. Configure these in
`release.env`:

```bash
R2_ACCOUNT_ID / R2_ACCESS_KEY / R2_SECRET_KEY   # R2 Object Read & Write on `aelum`
AELUM_GPG_KEY                                    # release signing key
AELUM_GPG_PRIVATE_KEY_B64                        # base64 armored private key (headless signing)
GPG_PASSPHRASE                                   # passphrase for the signing key
AELUM_SIGNING_UID / _FP / _FP_TOP / _FP_BOT / _EXPIRES
WEBSITE_DEPLOY_TOKEN                             # GitHub fine-grained PAT (Contents: read+write) for the website repo (empty = use the `gh` CLI login)
R2_PUBLIC_BASE                                   # optional CDN domain for asset URLs (default cdn.aelum.dev)
```

### Sign & checksum only

`scripts/sign-iso.sh`:

```bash
export AELUM_GPG_KEY='0x1234ABCD'     # or 'Name <email>'
./scripts/sign-iso.sh              # newest ISO in output/
# or release a specific one:
./scripts/sign-iso.sh output/aelum-2026.08.28-x86_64.iso
```

Produces SHA-256/SHA-512 checksums and a detached ASCII-armored GPG signature
(the public key is exported locally; distribution is via WKD). It verifies
everything before printing the exact list of assets to upload.

**Upload** — `scripts/publish-iso.sh`:

```bash
export R2_ACCOUNT_ID=xxxx
export R2_ACCESS_KEY=yyy
export R2_SECRET_KEY=zzz
./scripts/publish-iso.sh v2026.08.28
# or with an explicit path:
./scripts/publish-iso.sh v2026.08.28 output/aelum-2026.08.28-x86_64.iso
```

Builds a throwaway rclone config from the env vars (nothing is written to your
main `rclone.conf`) and uploads to the `aelum` bucket as `public-read`. The
release assets (`*.iso`, `*.sha256`, `*.sha512`, `*.asc`) all go to the same R2
folder. The public signing key is served via WKD
(`https://aelum.dev/.well-known/openpgpkey/`), not as a hosted file. It then
uploads `latest.json` to the bucket root and writes `release.ts` to the project
root.

**Update the website** — after publishing, commit the generated `release.ts` to
the website repo:

```bash
export WEBSITE_DEPLOY_TOKEN=xxxx
./scripts/publish-website.sh   # pushes src/lib/release.ts to the website repo → GitHub Pages rebuilds
```

Assets are served directly from R2 (the bucket has public reads) with
`cdn.aelum.dev` CNAME'd to the bucket endpoint — no Worker is needed. See
[RELEASE.md](RELEASE.md) for the full secret list and run-from-any-machine
instructions.

## Run (QEMU)

```bash
make run          # equivalent to the shell command below
# or, directly:
bash scripts/run-iso.sh
```

To clear a possibly-corrupt UEFI NVRAM, delete `OVMF_VARS.fd` (it is recreated
from the system template on next run) with `make run-clean`.

Launches the latest ISO in `output/` in QEMU with:

- KVM acceleration (`-cpu host`)
- 4 cores, 4GB RAM
- VirtIO GPU with GL (virgl), 1920×1080 (override with `XRES`/`YRES`)
- OVMF UEFI firmware (`OVMF_VARS.fd`; created from the system template if missing)
- 20G VirtIO virtual disk (`vdisk.qcow2`; created if missing)
- Shared directory (`$HOME/Projects/shared` by default, override with `SHARED_DIR`, mapped as `shared`)
- User-mode networking with SSH forwarded to host port 2222

`OVMF_VARS.fd` and `vdisk.qcow2` are created on first run if absent.

## Test / boot (headless QEMU + installer CLI)

```bash
bash scripts/test-install.sh        # auto: boot, run a full install, then stop QEMU
MODE=boot bash scripts/test-install.sh   # boot: leave the headless VM running for experiments
```

Two modes, selected with `MODE`:

- `auto` (default) — boots the ISO in a display-less QEMU VM, waits for `sshd`,
  and drives `aelum-installer-cli` over SSH (forwarded port 2222) to run a full
  automatic install against a freshly recreated virtual disk. QEMU is stopped
  when the test finishes. The installer CLI is headless by design — password via
  stdin, JSON progress to stderr — so the graphical frontend is never needed.
- `boot` — boots the ISO headless and leaves it running (detached) so you can
  SSH in and experiment. The virtual disk is left untouched. The host `shared/`
  dir is mounted at `/shared` in the VM automatically, so the freshly built
  installer CLI (from `installer/build/bin/`) can be launched there directly —
  no need to rebuild the ISO to test a new build.

Requires `qemu-system-x86_64`, `sshpass`, `ssh`. KVM is optional (falls back to
software emulation when `/dev/kvm` is absent). Live-ISO `root` (empty password)
is used to log in.

- Override with env vars: `MODE`, `USERNAME`, `USER_PASS`, `ROOT_PASS`,
  `SSH_PORT`, `DISK_PATH`, `FILESYSTEM`, `LUKS`, `LUKS_PASS`, `LVM`, `MANUAL`,
  `REUSE_ESP`, `VERIFY`, `SHARED_INSTALLER`, `QEMU_QVM` (0 disables KVM),
  `QEMU_EXTRA`, `SHARED_DIR`.
- Artifacts land in `logs/`: `test-progress.json` (installer stderr / JSON
  progress in auto mode), `qemu.log` (QEMU output), `matrix/` (per-cell logs).
- Also exposed as make targets: `make test` (runs **every** install variation —
  the full matrix), `make test-one` (a single install, flag-driven), and
  `make test-boot` (boot). `make test-one` forwards `FILESYSTEM` / `LUKS` /
  `LVM` / `MANUAL` / `REUSE_ESP` / `VERIFY` to the script, so
  `make test-one LVM=1` and `LVM=1 make test-one` both work.

### Testing the installer CLI

The installer CLI is headless by design: the password is read from stdin and
progress is emitted as JSON to stderr, so the graphical frontend is never
needed for these tests.

**Automatic mode** — a full install against a fresh virtual disk, then QEMU is
stopped. The disk is recreated from scratch each run so format/partitioning is
exercised against a clean target:

```bash
MODE=auto bash scripts/test-install.sh
# or, via make (single install):
make test-one
# or pin the filesystem / account:
USERNAME=aelum USER_PASS=aelum DISK_PATH=/dev/vda MODE=auto bash scripts/test-install.sh
```

**Manual / dualboot mode** — boot the VM headless (this also mounts the host
`shared/` at `/shared`), then run the freshly built CLI with a `--manual-layout`
JSON. The layout designates exactly one `esp` and one `system` partition; every
other partition on the disk is left untouched, which is what makes it dualboot
safe.

```bash
# 1) Boot headless with /shared mounted, leave the VM running
MODE=boot bash scripts/test-install.sh

# 2) SSH in and run a manual install (password via stdin)
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost
echo 'aelum' | /shared/aelum-installer-cli --install /dev/vda --filesystem btrfs \
  --manual-layout '<json below>' --username aelum
```

The `--manual-layout` JSON is a `ManualLayout` object (`installer/backend/shared/
types.go`). Each partition row carries `path` (existing device, e.g.
`/dev/vda1`, or empty to create a brand-new one), `sizeMB` (`0` = use all
remaining free space), `type` (`"esp"`, `"system"`, or empty to leave it
untouched), and — for existing partitions — the exact `sizeBytes`.

A fresh-disk layout creates both partitions (empty `path`, `sizeMB: 0` = fill
the remaining space):

```json
{
  "disk": "/dev/vda",
  "diskSizeMB": 20480,
  "diskSizeBytes": 21474836480,
  "sectorSizeBytes": 512,
  "partitions": [
    {"index": 0, "path": "", "sizeMB": 512, "type": "esp"},
    {"index": 1, "path": "", "sizeMB": 0, "type": "system"}
  ]
}
```

To reuse an existing ESP (dualboot), point the `esp` row at the existing
partition and set its exact size and filesystem. The installer mounts it as-is:
it is **never formatted**, and its size has no floor. Only a brand-new ESP needs
the 512 MiB minimum.

```json
{
  "disk": "/dev/vda",
  "diskSizeMB": 20480,
  "diskSizeBytes": 21474836480,
  "sectorSizeBytes": 512,
  "partitions": [
    {"index": 0, "path": "/dev/vda1", "sizeMB": 100, "sizeBytes": 104857600, "existingFstype": "vfat", "type": "esp"},
    {"index": 1, "path": "", "sizeMB": 0, "type": "system"}
  ]
}
```

A reused ESP must be FAT (`vfat`, or the `fat32` alias); anything else is
rejected during validation. Other existing partitions on the disk (Windows,
another distro) are represented by rows with an empty `type` and are never
formatted, mounted, or added to the fstab.

Validate the layout before committing to a real install by running the same
command with `--dry-run` appended.

`MANUAL=1` automates the manual path end to end: it builds a fresh-disk layout
(a 512 MiB ESP plus a System partition filling the rest) from the guest's
geometry and drives `--manual-layout` itself, so no hand-written JSON is needed.
Add `REUSE_ESP=1` to pre-create a 100 MiB FAT ESP containing a marker file and
stale `memtest86+` binaries, then install into the remaining free space reusing
it. The post-install check asserts the marker survived (the ESP was not
formatted), the stale memtest files were backed up, and rEFInd was installed
onto it — the full dualboot regression test:

```bash
MANUAL=1 REUSE_ESP=1 make test-one
```

### LVM and the full install matrix

Every supported layout can be exercised without the GUI. `test-install.sh` reads
these from the environment and passes the matching flags to the CLI:

| Variable | Values | Effect |
|----------|--------|--------|
| `FILESYSTEM` | `btrfs` (default) \| `ext4` | root filesystem (on the LVs when `LVM=1`) |
| `LUKS` | `0` (default) \| `1` | LUKS2-encrypt the root partition |
| `LVM` | `0` (default) \| `1` | place root+home on logical volumes in the `aelum` VG |
| `MANUAL` | `0` (default) \| `1` | dualboot-safe manual partitioning (512 MiB ESP + System) |
| `REUSE_ESP` | `0` (default) \| `1` | with `MANUAL=1`: pre-create a 100 MiB FAT ESP and reuse it (dualboot regression) |
| `VERIFY` | `1` (default) \| `0` | inspect the installed system after the install |

```bash
LVM=1 make test-one                       # auto + btrfs + LVM
LVM=1 FILESYSTEM=ext4 make test-one       # auto + ext4 + LVM
LUKS=1 LVM=1 make test-one                # auto + LUKS + LVM
MANUAL=1 LVM=1 make test-one              # manual + LVM
MANUAL=1 REUSE_ESP=1 make test-one        # manual, reuse a pre-made 100 MiB ESP
```

After a successful install, `scripts/verify-installed.sh` runs **inside the
guest** and independently re-inspects the disk: it re-opens LUKS, re-activates
the `aelum` VG, mounts the installed root read-only, and asserts

- the VG exists with exactly two LVs (`root`, `home`) and the PV is the system
  partition (or the LUKS mapper);
- the root and home filesystems match `FILESYSTEM`;
- `/etc/fstab` mounts `/`, the ESP at `/efi`, this install's `aelum/<id>/` boot
  directory at `/boot` (bind), and (LVM or btrfs) `/home` correctly, with the
  right UUIDs and the `@home` subvolume where applicable;
- `/etc/mkinitcpio.conf` `HOOKS` include `lvm2` (LVM) and an encrypt hook (LUKS);
- rEFInd is installed at `EFI/refind/refind_x64.efi` with a per-install menu
  fragment at `EFI/refind/aelum/<id>.conf` (included from `refind.conf`) that
  loads this install's own kernel/initramfs from `aelum/<id>/`; its options root
  at `/dev/mapper/aelum-root` (LVM), carry `rd.luks.name=` (LUKS), and add
  `rootflags=subvol=@` only for btrfs.

`verify-installed.sh` never calls the installer, so it validates the on-disk
result rather than the code that produced it. Set `VERIFY=0` to skip it.

**Every variation by default.** `make test` runs the whole matrix — auto/manual
× btrfs/ext4 × LUKS off/on × LVM off/on (16 cells) — each with a fresh QEMU
boot, install, and verification, then prints a pass/fail summary. Narrow it
while iterating:

```bash
make test                                     # all 16 variations
make test-lvm                                 # only the LVM variations (8)
LVMS=1 make test                              # same as test-lvm
MODES=auto FILESYSTEMS=ext4 LVMS=1 make test
SHARED_INSTALLER=1 make test                  # drive installs from /shared
```

(`make test-matrix` is kept as an explicit alias for `make test`, and
`make test-one` runs a single install.)

The dimensions are `MODES` (`auto manual`), `FILESYSTEMS` (`btrfs ext4`),
`LUKSES` (`0 1`), and `LVMS` (`0 1`). Per-cell logs land in `logs/matrix/`. A
full desktop install is heavy, so the whole matrix takes a long time — narrow
the lists while iterating.

## Layout

```
.
├── Dockerfile                 # Build toolchain image (archlinux + tooling)
├── docker-compose.yml         # aelum (build) + aelum-shell / aelum-local-shell (interactive) services
├── Makefile                   # docker (build / image / update / dev / attach / stop / clean) # and qemu (run / run-clean / vm-clean / test / test-boot)
├── scripts/
│   ├── build-iso.sh           # Full build pipeline (run inside the container)
│   ├── stage-local-repos.sh   # stage local installer/ + live-iso/ for local-build
│   ├── run-iso.sh             # QEMU launch script
│   ├── test-install.sh        # headless QEMU + installer-cli test
│   ├── test-all.sh            # run the full install matrix, print a summary
│   ├── verify-installed.sh    # independent post-install inspection (in the guest)
│   ├── release.sh             # entry point: load secrets, sign, upload, update site
│   ├── sign-iso.sh            # sign + checksum the ISO (GPG) for release
│   ├── gen-release-metadata.sh    # build latest.json + website release.ts
│   ├── publish-iso.sh         # upload ISO + sidecars + latest.json to R2
│   ├── publish-website.sh     # push release.ts to the website repo
│   └── export-wkd.sh          # regenerate the WKD tree in the website repo
├── logs/                      # test artifacts (test-progress.json, test-run.log)
├── output/                    # Built ISO files (bind-mounted from host)
├── OVMF_VARS.fd               # UEFI variables for QEMU
└── vdisk.qcow2                # QEMU virtual disk for testing
```
