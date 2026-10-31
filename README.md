# Aelum — build, test, release

This repo turns the [live-iso profile](https://github.com/aelum-dev/live-iso) and the
[Aelum installer](https://github.com/aelum-dev/installer) into a released Aelum ISO: it builds the ISO
inside an Arch container, boots it in QEMU and runs every install variation against a real disk, then
publishes the result to Cloudflare R2 — the ISO is too large for GitHub — and updates the
[website](https://aelum.dev) download metadata in the same run.

## Requirements

- Linux with rootful Docker and Compose v2 (`docker compose`) — the build container is privileged
- KVM, plus `qemu-system-x86_64`, `ssh` and `sshpass` for the tests
- ~25 GB free; `make local-build` also wants ~15 GB in its staging dir (`/tmp` by default)
- Network access for the Arch package download and the AUR builds

## Build an ISO

```bash
make build          # from the published repos → output/aelum-YYYY.MM.DD-x86_64.iso
make local-build    # from your local installer/ + live-iso/ (staged in /tmp; your trees are not touched)
make local-dev      # a persistent container with your real repos mounted: edit here, ./build-iso.sh there
```

`make image` and `make update` build or refresh the cached toolchain image. `make help` lists every
target and its flags.

## Boot it

```bash
make run            # latest ISO in a QEMU window (XRES= / YRES= for another resolution)
make run-disk       # boot what is installed on the test disk, through its own boot menu
make vm-clean       # fresh test disk + fresh UEFI variables
```

## Test an install

Tests run in QEMU against a 20 GB virtual disk, not inside the build container: that disk is the only
place a real partition table, LUKS header, volume group, fstab and firmware boot entry exist.

```bash
make test-one LUKS=1 LVM=1 FILESYSTEM=ext4   # one install, then re-inspect what landed on disk
make test                                     # all 16 variations, with a pass/fail summary
make test-boot                                # headless live session, /shared mounted, VM left running
```

`make test-one` takes `FILESYSTEM` `LUKS` `LVM` `MANUAL` `VERIFY`; `make test` narrows with `MODES`,
`FILESYSTEMS`, `LUKSES`, `LVMS`. The guest answers on host port 2222 (root, empty password), and logs
land in `logs/`. For snapshots there are `make demo-snapshots` and `make snapshot-rollback`, plus
fixture scripts that check the boot-menu generators with no disk and no root — `AGENTS.md` says which
one to reach for.

## Release

```bash
cp release.env.example release.env   # your R2 / GPG / website values — never committed
make build
make release                         # sign → upload to R2 → push the website's download metadata
```

There is no CI job: the release runs locally, with your keys and your ISO. The secret list and the
run-from-any-machine notes are in [RELEASE.md](RELEASE.md); what gets published is on
[aelum.dev](https://aelum.dev).

## Working in this repo

`AGENTS.md` holds what was learned the expensive way — which build command to use, how the pipeline and
the scripts are laid out, and the QEMU / OVMF facts that look optional until they bite.
[RELEASE.md](RELEASE.md) is the release reference.

## License

This repo ships no license: it is build and test tooling for the distro, which is GPL-3.0 in
`installer/`, `live-iso/` and `website/`.
