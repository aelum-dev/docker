# AestheticOS — Build & Run

This repo contains the **AestheticOS build and run pipeline**. It turns the
[AestheticOS profile](https://gitlab.com/aestheticos/live-iso) into a bootable,
fully offline Arch Linux ISO, and launches it in QEMU for testing.

All building and running of AestheticOS happens here — the profile repo only
holds the content that goes into the ISO.

## What it does

`build.sh` runs the full pipeline inside a privileged `archlinux` container:

1. Installs build tooling (`git`, `base-devel`, `archiso`, `grub`, etc.)
2. Clones the [AestheticOS profile](https://gitlab.com/aestheticos/live-iso) and the [AestheticOS Installer](https://gitlab.com/aestheticos/installer), and builds the installer binaries
3. Downloads every official package needed (via a blank-db `pacman -Syw`, so only the dependency tree is pulled)
4. Builds the listed AUR packages and pulls each one together with its dependency tree into the offline cache
5. Assembles an offline mirror (`repo-add` + `file://` server) into the profile's `airootfs`
6. Runs `mkarchiso` to produce the ISO

The built ISO is written to the mounted `output/` directory.

## Requirements

- Docker + Docker Compose
- KVM support (for QEMU testing)
- ~15 GB of free disk space for the build and the ~4.7 GB installed OS

## Build

```bash
make build
```

The toolchain image (`aestheticos-image`) is built from `./Dockerfile` and
cached, so the first `make build` includes the toolchain install while later
builds skip it and only redo the clones, offline-cache download, and AUR builds.
The pipeline then runs in a one-shot container and writes the ISO to `output/`.
The output directory is bind-mounted from the host, and files are handed back to
the host user automatically (via `OUTPUT_UID`/`OUTPUT_GID`, defaulting to `UID`/`GID`).

### Build the toolchain image only

To (re)build just the `aestheticos-image` image without running the ISO
pipeline:

```bash
make image          # builds & tags aestheticos-image
# or, forcing a fresh build ignoring cache:
make image NO_CACHE=1   # see below
```

Equivalently with compose directly:

```bash
docker compose build aestheticos
# or, forcing a fresh build ignoring cache:
docker compose build --no-cache aestheticos
```

Rebuild with `--no-cache` whenever you change `./Dockerfile` or want to pick up
updated packages in the `archlinux:latest` base.

To debug or work interactively:

```bash
make run        # start an interactive build container (aestheticos-shell)
make attach     # attach to it later
make stop       # stop the container
make clean      # stop + remove containers and prune volumes
```

Or run the pipeline directly:

```bash
docker compose run --rm aestheticos
```

The resulting ISO appears in `output/`, e.g. `output/aestheticos-YYYY.MM.DD-x86_64.iso`.

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
├── docker-compose.yml       # aestheticos (build) + aestheticos-shell (interactive) services
├── Makefile                 # build / run / stop / attach / clean
├── run.sh                   # QEMU launch script
├── output/                  # Built ISO files (bind-mounted from host)
├── OVMF_VARS.fd             # UEFI variables for QEMU
└── vdisk.qcow2              # QEMU virtual disk for testing
```
