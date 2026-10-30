# Aelum docker — Agent Context

This repo builds every Aelum ISO (`output/aelum-*.iso`), runs the QEMU test matrix against
`vdisk.qcow2`, and publishes releases. The full pipeline is in `README.md` and `RELEASE.md`;
the cross-repo rules are in the workspace-root `AGENTS.md`. This file holds the build rules
an agent must not relearn the expensive way.

## Which build command to use (read before starting any build)

- **Iterating on a feature and testing it in a bootable ISO → `make local-dev`, then
  `./build-iso.sh` inside the container.** `aelum-local-shell` bind-mounts the real
  `installer/` + `live-iso/` working trees and **keeps its pacman package cache, AUR build
  cache, and archiso work dir warm across runs**, so a rebuild after a small change
  re-downloads only what changed. This is the normal loop.
- **`make local-build` and `make build` are one-shot containers** (`docker compose run --rm`):
  every cache dies with the container, so each run re-downloads the full package set from the
  internet — slow on a metered line. Use them only when you actually want a clean throwaway
  build (e.g. the final ISO before a release), not to test a change you just made.
- A build killed halfway can leave root-owned files in `/tmp/aelum-local-build` or a leftover
  `aelum*` container holding the stage busy. Clean with `make local-clean` (and
  `docker rm <container>` if the stage reports "Device or resource busy") before retrying.
- Never run two ISO builds at once: they share the image, the stage dir, and `output/`.

## After the ISO exists

Tests run on the host against QEMU, not inside Docker (see root `AGENTS.md` →
"Where to run anything that needs root"): `make test-one …`, `make test-boot`,
`make snapshot-rollback`, `./scripts/fake-snapshot-*.sh` (host-only fixtures, no root).
The guest's disk is `docker/vdisk.qcow2` = `/dev/vda`; the installed test system is throwaway —
fix the source, rebuild (via `local-dev`), and re-run the test.
