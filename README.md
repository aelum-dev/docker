# Aelum — Build & Run

This repo contains the **Aelum build and run pipeline**. It turns the
[Aelum profile](https://gitlab.com/aelum/live-iso) into a bootable,
fully offline Arch Linux ISO, and launches it in QEMU for testing.

All building and running of Aelum happens here — the profile repo only
holds the content that goes into the ISO.

## What it does

The build toolchain (`git`, `base-devel`, `archiso`, `go`, `nodejs`, `gtk3`,
`webkit2gtk`, `grub`, `memtest86+`) is installed once, in the cached `aelum-image`
built from `./Dockerfile` — so it is not reinstalled on every run. `build.sh`
runs the rest of the pipeline inside a privileged `archlinux` container:

1. Clones the [Aelum profile](https://gitlab.com/aelum/live-iso) and the [Aelum Installer](https://gitlab.com/aelum/installer), and builds the installer binaries
2. Downloads every official package needed (via a blank-db `pacman -Syw`, so only the dependency tree is pulled)
3. Builds the listed AUR packages and pulls each one together with its dependency tree into the offline cache
4. Assembles an offline mirror (`repo-add`) into the profile's `airootfs`
5. Runs `mkarchiso` to produce the ISO

The built ISO is written to the mounted `output/` directory.

## Requirements

- Docker + Docker Compose
- KVM support (for QEMU testing)
- ~25 GB of free disk space for the build (the 16G `vdisk.qcow2` and ~3.5 GB ISO are created under `output/` and `.`)

## Build

```bash
make build
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
[R2](https://developers.cloudflare.com/r2/) bucket and the download link is
updated on the website by hand. Two scripts handle this locally:

**Sign & checksum** — `scripts/make-release.sh`:

```bash
export AELUM_GPG_KEY='0x1234ABCD'     # or 'Name <email>'
./scripts/make-release.sh             # newest ISO in output/
# or release a specific one:
./scripts/make-release.sh output/aelum-2026.08.28-x86_64.iso
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
all go to the same R2 folder.

## Run (QEMU)

```bash
bash run.sh
```

Launches the latest ISO in `output/` in QEMU with:

- KVM acceleration (`-cpu host`)
- 4 cores, 4GB RAM
- VirtIO GPU with GL (virgl), 1920×1080 (override with `XRES`/`YRES`)
- OVMF UEFI firmware (`OVMF_VARS.fd`; created from the system template if missing)
- 16G VirtIO virtual disk (`vdisk.qcow2`; created if missing)
- Shared directory (`$HOME/Projects/shared`, mapped as `shared`)
- User-mode networking with SSH forwarded to host port 2222

`OVMF_VARS.fd` and `vdisk.qcow2` are created on first run if absent.

## Layout

```
.
├── Dockerfile               # Build toolchain image (archlinux + tooling)
├── build.sh                 # Full build pipeline (run inside the container)
├── docker-compose.yml       # aelum (build) + aelum-shell (interactive) services
├── Makefile                 # build / image / run / stop / attach / clean
├── run.sh                   # QEMU launch script
├── output/                  # Built ISO files (bind-mounted from host)
├── scripts/
│   ├── make-release.sh      # sign + checksum the ISO for release
│   └── publish-iso.sh       # upload the ISO to Cloudflare R2
├── OVMF_VARS.fd             # UEFI variables for QEMU
└── vdisk.qcow2              # QEMU virtual disk for testing
```
