# Aelum — Build & Run

This repo contains the **Aelum build and run pipeline**. It turns the
[Aelum profile](https://gitlab.com/aelum/live-iso) into a bootable,
fully offline Arch Linux ISO, and launches it in QEMU for testing.

All building and running of Aelum happens here — the profile repo only
holds the content that goes into the ISO.

## What it does

The build toolchain (`git`, `base-devel`, `archiso`, `go`, `nodejs`, `gtk3`,
`webkit2gtk`, `grub`, `memtest86+`) is installed once, in the cached `aelum-image`
built from `./Dockerfile` — so it is not reinstalled on every run. `scripts/
build-iso.sh` runs the rest of the pipeline inside a privileged `archlinux`
container:

1. Clones the [Aelum profile](https://gitlab.com/aelum/live-iso) and the [Aelum Installer](https://gitlab.com/aelum/installer), and builds the installer binaries
2. Downloads every official package needed (via a blank-db `pacman -Syw`, so only the dependency tree is pulled)
3. Builds the listed AUR packages and pulls each one together with its dependency tree into the offline cache
4. Assembles an offline mirror (`repo-add`) into the profile's `airootfs`
5. Runs `mkarchiso` to produce the ISO

The built ISO is written to the mounted `output/` directory.

## Requirements

- Docker + Docker Compose
- KVM support (for QEMU testing)
- ~25 GB of free disk space for the build

## Build

```bash
make run-iso          # launch the latest ISO in output/ in QEMU
XRES=2560 YRES=1440 make run-iso   # override resolution
make run-iso-clean    # delete OVMF_VARS.fd (recreated on next run) then launch
```

The toolchain image (`aelum-image`) is built from `./Dockerfile` and
cached, so the first `make build` includes the toolchain install while later
builds skip it and only redo the clones, offline-cache download, and AUR builds.
The pipeline then runs in a one-shot container and writes the ISO to `output/`.
The output directory is bind-mounted from the host, and files are handed back to
the host user automatically (via `OUTPUT_UID`/`OUTPUT_GID`, defaulting to `UID`/`GID`).

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
make run        # start an interactive build container (aelum-shell)
make attach     # attach to it later
make stop       # stop the container
make clean      # stop + remove containers and prune volumes
```

Or run the pipeline directly:

```bash
docker compose run --rm aelum
```

The resulting ISO appears in `output/`, e.g. `output/aelum-YYYY.MM.DD-x86_64.iso`.

## Releases

The ISO is too large for GitLab, so releases are published to a Cloudflare
[R2](https://developers.cloudflare.com/r2/) bucket, and the download links on
the website are updated **automatically** — no hand-editing. The pieces:

- **`scripts/release-iso.sh`** — sign + checksum the ISO (GPG detached signature,
  SHA-256/SHA-512, exported public key). Verifies everything before printing the
  assets to upload.
- **`scripts/publish-iso.sh`** — upload the assets to the `aelum` R2 bucket
  (`public-read`), then build and upload **`latest.json`** (machine-readable
  release metadata) to the bucket root (served publicly), and generate the
  website's **`release.ts`**.
- **`scripts/publish-website.sh`** — commit the generated `release.ts` to the
  [website](https://gitlab.com/aelum/website) repo's `main` branch, which triggers
  GitLab Pages to redeploy with the fresh download links.

### How to run (local)

The whole release runs locally — there is **no CI job** (the ISO is too large for
GitLab and the release needs your keys + your local ISO). Build the ISO first,
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
WEBSITE_DEPLOY_TOKEN                             # GitLab project access token (Owner), write access to the website repo
R2_PUBLIC_BASE                                   # optional CDN domain for asset URLs (default cdn.aelum.dev)
```

### Sign & checksum only

`scripts/release-iso.sh`:

```bash
export AELUM_GPG_KEY='0x1234ABCD'     # or 'Name <email>'
./scripts/release-iso.sh              # newest ISO in output/
# or release a specific one:
./scripts/release-iso.sh output/aelum-2026.08.28-x86_64.iso
```

Produces SHA-256/SHA-512 checksums, a detached ASCII-armored GPG signature,
and exports the public signing key. It verifies everything before printing the
exact list of assets to upload.

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
release assets (`*.iso`, `*.sha256`, `*.sha512`, `*.asc`, `aelum-release-key.asc`)
all go to the same R2 folder. It then uploads `latest.json` to the bucket root
and writes `release.ts` to the project root.

**Update the website** — after publishing, commit the generated `release.ts` to
the website repo:

```bash
export WEBSITE_DEPLOY_TOKEN=xxxx
./scripts/publish-website.sh   # pushes src/lib/release.ts to the website repo → GitLab Pages rebuilds
```

Assets are served directly from R2 (the bucket has public reads) with
`cdn.aelum.dev` CNAME'd to the bucket endpoint — no Worker is needed. See
[RELEASE.md](RELEASE.md) for the full secret list and run-from-any-machine
instructions.

## Run (QEMU)

```bash
make run-iso          # equivalent to the shell command below
# or, directly:
bash scripts/run-iso.sh
```

To clear a possibly-corrupt UEFI NVRAM, delete `OVMF_VARS.fd` (it is recreated
from the system template on next run) with `make run-iso-clean`.

Launches the latest ISO in `output/` in QEMU with:

- KVM acceleration (`-cpu host`)
- 4 cores, 4GB RAM
- VirtIO GPU with GL (virgl), 1920×1080 (override with `XRES`/`YRES`)
- OVMF UEFI firmware (`OVMF_VARS.fd`; created from the system template if missing)
- 16G VirtIO virtual disk (`vdisk.qcow2`; created if missing)
- Shared directory (`$HOME/Projects/shared`, mapped as `shared`)
- User-mode networking with SSH forwarded to host port 2222

`OVMF_VARS.fd` and `vdisk.qcow2` are created on first run if absent.

## Test / boot (headless QEMU + installer CLI)

```bash
bash scripts/test-iso.sh        # auto: boot, run a full install, then stop QEMU
MODE=boot bash scripts/test-iso.sh   # boot: leave the headless VM running for experiments
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
  `SSH_PORT`, `DISK_PATH`, `QEMU_QVM` (0 disables KVM), `QEMU_EXTRA`, `SHARED_DIR`.
- Artifacts land in `logs/`: `test-progress.json` (installer stderr / JSON
  progress in auto mode), `qemu.log` (QEMU output).
- Also exposed as make targets: `make test` (auto) and `make test-boot` (boot).
- `make test` is equivalent to `MODE=auto ./scripts/test-iso.sh`; `make test-boot` to `MODE=boot ./scripts/test-iso.sh`.

### Testing the installer CLI

The installer CLI is headless by design: the password is read from stdin and
progress is emitted as JSON to stderr, so the graphical frontend is never
needed for these tests.

**Automatic mode** — a full install against a fresh virtual disk, then QEMU is
stopped. The disk is recreated from scratch each run so format/partitioning is
exercised against a clean target:

```bash
MODE=auto bash scripts/test-iso.sh
# or pin the filesystem / account:
USERNAME=aelum USER_PASS=aelum DISK_PATH=/dev/vda MODE=auto bash scripts/test-iso.sh
```

**Manual / dualboot mode** — boot the VM headless (this also mounts the host
`shared/` at `/shared`), then run the freshly built CLI with a `--manual-layout`
JSON. The layout designates exactly one `esp` and one `system` partition; every
other partition on the disk is left untouched, which is what makes it dualboot
safe.

```bash
# 1) Boot headless with /shared mounted, leave the VM running
MODE=boot bash scripts/test-iso.sh

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

The exact layout used to test manual mode against the stock 20 GiB virtual
disk (`/dev/vda` = 21474836480 bytes, `/dev/vda1` EFI 128 MiB vfat,
`/dev/vda2` Root ~19.9 GiB ext4):

```json
{
  "disk": "/dev/vda",
  "diskSizeMB": 20480,
  "diskSizeBytes": 21474836480,
  "partitions": [
    {"index": 0, "path": "/dev/vda1", "sizeMB": 128, "sizeBytes": 134217728, "existingFstype": "vfat", "type": "esp"},
    {"index": 1, "path": "/dev/vda2", "sizeMB": 20350, "sizeBytes": 21339553280, "existingFstype": "ext4", "type": "system"}
  ],
  "freeSectors": 2014
}
```

To test the dualboot-safe *preserve* path, add extra rows with an empty `type`
(e.g. another OS's existing partition) — those partitions are never formatted,
mounted, or written to the fstab. Validate the layout before committing to a
real install by running the same command with `--dry-run` appended.

## Layout

```
.
├── Dockerfile                 # Build toolchain image (archlinux + tooling)
├── docker-compose.yml         # aelum (build) + aelum-shell (interactive) services
├── Makefile                   # docker (build / image / update / run / attach / stop / clean) # and qemu (run-iso / run-iso-clean / test / test-boot)
├── scripts/
│   ├── build-iso.sh           # Full build pipeline (run inside the container)
│   ├── run-iso.sh             # QEMU launch script
│   ├── test-iso.sh            # headless QEMU + installer-cli test
│   ├── release.sh             # entry point: load secrets, sign, upload, update site
│   ├── release-iso.sh         # sign + checksum the ISO (GPG) for release
│   ├── build-release-metadata.sh  # build latest.json + website release.ts
│   ├── publish-iso.sh         # upload ISO + sidecars + latest.json to R2
│   └── publish-website.sh     # push release.ts to the website repo
├── logs/                      # test artifacts (test-progress.json, test-run.log)
├── output/                    # Built ISO files (bind-mounted from host)
├── OVMF_VARS.fd               # UEFI variables for QEMU
└── vdisk.qcow2                # QEMU virtual disk for testing
```
