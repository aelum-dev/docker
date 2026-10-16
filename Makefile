.PHONY: help build image update dev attach stop clean \
        release release-sign release-upload release-website \
        run run-clean vm-clean measure-boot test test-one test-boot test-matrix test-lvm

BUILD_FLAGS:=
ifeq ($(NO_CACHE),1)
	BUILD_FLAGS:=--no-cache
endif

## Show usage
help:
	@echo "Aelum docker build/run pipeline\n"
	@echo "Build toolchain & ISO:"
	@echo "  make image            Build & tag the toolchain image (aelum-image)"
	@echo "  make image NO_CACHE=1 Force a fresh build (--no-cache)"
	@echo "  make build            Build the ISO (reuses cached image) -> output/*.iso"
	@echo "  make update           Rebuild toolchain from the latest Arch base (--no-cache)"
	@echo ""
	@echo "Interactive dev shell:"
	@echo "  make dev              Start aelum-shell and drop into bash"
	@echo "  make attach           Attach to the running aelum-shell"
	@echo "  make stop             Stop aelum-shell"
	@echo "  make clean            Stop + remove containers, prune anonymous volumes"
	@echo ""
	@echo "Release (sign -> R2 -> website):"
	@echo "  make release          Full pipeline; tag=v<today> (VERSION= to pin, ISO= to pick)"
	@echo "  make release-sign     Sign + checksum the newest ISO in output/"
	@echo "  make release-upload   Upload assets + latest.json to R2 (TAG= required, ISO= optional)"
	@echo "  make release-website  Push release.ts to the website repo"
	@echo ""
	@echo "QEMU (host, needs KVM + sshpass):"
	@echo "  make run          Boot the latest ISO (XRES= YRES= override resolution)"
	@echo "  make run-clean    Delete OVMF_VARS.fd then boot (fix corrupt NVRAM)"
	@echo "  make vm-clean       Delete vdisk.qcow2 + OVMF_VARS.fd (fresh test disk)"
	@echo ""
	@echo "Boot-time measurement (graphical boot, headless GPU):"
	@echo "  make measure-boot      Timeline of every boot component -> logs/boot-timing.*"
	@echo "  DISPLAY_MODE=sdl make measure-boot   Watch the boot live in an SDL window"
	@echo ""
	@echo "Headless test (SSH + installer CLI):"
	@echo "  make test             Run EVERY install variation (auto/manual x btrfs/ext4 x LUKS x LVM)"
	@echo "  make test LVMS=1      Narrow the matrix (only the LVM cells)"
	@echo "  make test-one         Run a single install, stop (MODE=auto, FILESYSTEM=btrfs)"
	@echo "  make test-one LUKS=1  single LUKS2-encrypted install"
	@echo "  make test-one LVM=1   single install on LVM logical volumes"
	@echo "  make test-one MANUAL=1  single dualboot-safe manual install"
	@echo "  make test-lvm         Run only the LVM cells of the matrix"
	@echo "  make test-boot        Boot headless with /shared mounted; leave VM running"

# ===========================================================================
# Docker — ISO build pipeline (privileged container, writes ISO to output/)
# ===========================================================================

## Build & tag the toolchain image (aelum-image)
image:
	docker compose build $(BUILD_FLAGS)

## One-shot ISO build (reuses cached image layers by default)
build:
	docker compose run --rm aelum

# Rebuild the toolchain image from the newest Arch base and bake the updated
# packages into it. The Dockerfile already runs `pacman -Syu`, but Docker's
# layer cache keeps the old `archlinux:latest` digest, so we force a clean
# rebuild (no-cache) to re-pull the base and re-run the toolchain install.
# The result is a saved, updated `aelum-image` for future builds.
update:
	docker compose stop aelum-shell 2>/dev/null || true
	docker rm -f aelum aelum-shell 2>/dev/null || true
	docker rmi -f aelum-image 2>/dev/null || true
	docker compose build --no-cache

# ===========================================================================
# Interactive dev shell (shares the build image, runs on the host's docker)
# ===========================================================================

## Start an interactive build/dev container (aelum-shell) and drop into bash
dev:
	docker compose up -d aelum-shell
	docker exec -it aelum-shell bash || true

## Attach to the running aelum-shell (start it first with `make dev`)
attach:
	@if docker inspect -f '{{.State.Running}}' aelum-shell 2>/dev/null | grep -q true; then \
		docker exec -it aelum-shell bash; \
	else \
		echo "aelum-shell is not running. Start it with: make dev"; \
		exit 1; \
	fi

## Stop the aelum-shell container
stop:
	docker compose stop aelum-shell

## Stop + remove containers and prune anonymous volumes
clean:
	docker compose stop aelum-shell 2>/dev/null || true
	docker rm -f aelum aelum-shell 2>/dev/null || true
	docker volume prune -f

# ===========================================================================
# Release — sign, publish to Cloudflare R2, and update the website links
# ===========================================================================

# Full release pipeline: sign the ISO, upload it to Cloudflare R2, then push the
# updated download links to the website repo. All credentials come from the
# environment (see RELEASE.md for the full list). The tag defaults to today
# (vYYYY.MM.DD) or pin it with VERSION=.
#
#   make release                       # release newest ISO in output/ as v<today>
#   make release VERSION=2026.10.04    # pin the tag
#   make release ISO=output/foo.iso    # release a specific ISO
RELEASE_TAG := $(if $(VERSION),v$(VERSION),v$(shell date +%Y.%m.%d))

# All of the release logic (load secrets, validate, sign, upload, update the
# website) lives in a single shell wrapper so the sourced env vars are visible
# throughout. Pass the tag as $1; the wrapper defaults to today if omitted.
release:
	@./scripts/release.sh "$(RELEASE_TAG)"

## Sign + checksum the newest ISO in output/ (GPG detached sig + SHA-256/512)
release-sign:
	@./scripts/release-iso.sh

## Upload assets + latest.json to R2 (TAG= required, ISO= optional)
##   make release-upload TAG=v2026.10.04
release-upload:
	@if [ -z "$(TAG)" ]; then \
		echo "ERROR: set TAG= (e.g. make release-upload TAG=v2026.10.04)"; exit 1; fi
	@./scripts/publish-iso.sh "$(TAG)" "${ISO:-}"

## Push the generated release.ts to the website repo (triggers GitLab Pages)
release-website:
	@./scripts/publish-website.sh

# ===========================================================================
# QEMU — boot the built ISO (runs on the host, needs KVM + sshpass)
# ===========================================================================

## Launch the latest ISO in output/ in QEMU (XRES= YRES= override resolution)
run:
	@./scripts/run-iso.sh

## Delete OVMF_VARS.fd (recreated on next run) then launch the latest ISO
run-clean:
	@rm -f OVMF_VARS.fd
	@./scripts/run-iso.sh

## Delete vdisk.qcow2 + OVMF_VARS.fd for a fresh virtual disk / clean NVRAM
vm-clean:
	@rm -f vdisk.qcow2 OVMF_VARS.fd

# ===========================================================================
# QEMU — boot-time measurement (graphical boot, headless GPU)
# ===========================================================================

## Measure the boot chain: boots the ISO with a GPU and prints a monotonic
## timeline of every component (kernel → plymouth → greetd → Hyprland →
## installer), focused on the gap between the splash quitting and the installer
## appearing. Writes logs/boot-timing.log + logs/boot-timing.json.
##   make measure-boot                    # headless (egl-headless GPU)
##   DISPLAY_MODE=sdl make measure-boot   # watch it live in an SDL window
##   DISPLAY_MODE=none make measure-boot  # no GPU (non-graphical chain only)
measure-boot:
	@./scripts/measure-boot.sh

# ===========================================================================
# QEMU — headless test (boot + drive aelum-installer-cli over SSH)
# ===========================================================================

## test: run EVERY install variation — auto/manual x btrfs/ext4 x LUKS x LVM
##       (16 cells by default), each with an independent post-install check.
##       This is heavy: every cell boots QEMU and does a full desktop install.
##   make test                              # all 16 variations
##   make test LVMS=1                        # just the LVM variations
##   make test MODES=auto FILESYSTEMS=ext4 LVMS=1
##   VERIFY=0 make test                      # skip the post-install inspection
##   SHARED_INSTALLER=1 make test            # drive installs from /shared
test: test-matrix

## one: run a SINGLE install with the given flags, then stop (for debugging one path)
##   SSH_PORT=2230 make test-one
##   LUKS=1 make test-one                 # encrypt the root partition with LUKS2
##   LUKS_PASS=... make test-one          # LUKS passphrase (default aelum-luks)
##   LVM=1 make test-one                  # place root+home on LVM logical volumes
##   MANUAL=1 make test-one               # dualboot-safe manual partitioning
##   FILESYSTEM=ext4 make test-one        # root filesystem (btrfs | ext4)
##   VERIFY=0 make test-one               # skip the post-install inspection
##   SHARED_INSTALLER=1 make test-one     # drive the install with /shared/aelum-installer-cli
test-one:
	@MODE=auto \
	 FILESYSTEM="$(FILESYSTEM)" LUKS="$(LUKS)" LVM="$(LVM)" MANUAL="$(MANUAL)" \
	 VERIFY="$(VERIFY)" SHARED_INSTALLER="$(SHARED_INSTALLER)" \
	 LUKS_PASS="$(LUKS_PASS)" USER_PASS="$(USER_PASS)" \
	 USERNAME="$(USERNAME)" SSH_PORT="$(SSH_PORT)" \
	 ./scripts/test-iso.sh

## boot: boot headless with /shared mounted; leave VM running
test-boot:
	@MODE=boot ./scripts/test-iso.sh

## matrix: run every install combination and print a pass/fail summary
##       (this is what `make test` runs; kept as an explicit alias)
##   make test-matrix                              # all 16 combinations
##   make test-matrix LVMS=1                        # only the LVM cells
##   make test-matrix MODES=auto FILESYSTEMS=ext4 LVMS=1
##   SHARED_INSTALLER=1 make test-matrix            # drive installs from /shared
test-matrix:
	@MODES="$(MODES)" FILESYSTEMS="$(FILESYSTEMS)" LUKSES="$(LUKSES)" LVMS="$(LVMS)" \
	 VERIFY="$(VERIFY)" SHARED_INSTALLER="$(SHARED_INSTALLER)" \
	 ./scripts/test-matrix.sh

## lvm: run every LVM cell (mode x fs x luks), each with verification
##   make test-lvm
##   make test-lvm MODES=auto FILESYSTEMS=ext4
test-lvm:
	@MODES="$(MODES)" FILESYSTEMS="$(FILESYSTEMS)" LUKSES="$(LUKSES)" LVMS=1 \
	 VERIFY="$(VERIFY)" SHARED_INSTALLER="$(SHARED_INSTALLER)" \
	 ./scripts/test-matrix.sh
