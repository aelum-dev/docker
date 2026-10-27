.PHONY: help build local-build build-local local-clean image update dev local-dev attach stop clean \
        release release-sign release-upload release-website wkd \
        run run-clean run-disk vm-clean test test-one test-boot test-matrix demo-snapshots

BUILD_FLAGS:=
ifeq ($(NO_CACHE),1)
	BUILD_FLAGS:=--no-cache
endif

# The shell does not export UID/GID, so compose's ${UID:-1000} fallback would
# hand the ISO to the wrong owner on hosts where the user is not 1000. Pass the
# real ids explicitly; they are also used to chown the local-build stage back.
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)

## Show usage
help:
	@echo "Aelum docker build/run pipeline"
	@echo ""
	@echo "Build toolchain & ISO:"
	@echo "  make image            Build & tag the toolchain image (aelum-image)"
	@echo "  make image NO_CACHE=1 Force a fresh build (--no-cache)"
	@echo "  make build            Build the ISO (reuses cached image) -> output/*.iso"
	@echo "  make local-build      Build the ISO from local installer/ + live-iso/ (staged in /tmp)"
	@echo "  make local-clean      Remove the staged local-build tree"
	@echo "  make update           Rebuild toolchain from the latest Arch base (--no-cache)"
	@echo ""
	@echo "Interactive dev shell:"
	@echo "  make dev              Start aelum-shell and drop into bash"
	@echo "  make local-dev        Same shell, but builds from the local installer/ + live-iso/"
	@echo "  make attach           Attach to the running aelum-shell"
	@echo "  make stop             Stop the interactive shells"
	@echo "  make clean            Stop + remove containers, prune anonymous volumes"
	@echo ""
	@echo "Release (sign -> R2 -> website):"
	@echo "  make release          Full pipeline; tag=v<today> (VERSION= to pin, ISO= to pick)"
	@echo "  make release-sign     Sign + checksum the newest ISO in output/"
	@echo "  make release-upload   Upload assets + latest.json to R2 (TAG= required, ISO= optional)"
	@echo "  make release-website  Push release.ts to the website repo"
	@echo "  make wkd              Regenerate the Web Key Directory tree (commit it)"
	@echo ""
	@echo "QEMU (host, needs KVM + sshpass):"
	@echo "  make run          Boot the latest ISO (XRES= YRES= override resolution)"
	@echo "  make run-disk     Boot what is installed on vdisk.qcow2 (no ISO; shows its rEFInd)"
	@echo "  make run-clean    Delete OVMF_VARS.fd then boot (fix corrupt NVRAM)"
	@echo "  make vm-clean       Delete vdisk.qcow2 + OVMF_VARS.fd (fresh test disk)"
	@echo ""
	@echo "Headless test (SSH + installer CLI):"
	@echo "  make test             Run EVERY install variation (auto/manual x btrfs/ext4 x LUKS x LVM)"
	@echo "  make test LUKSES=1    Narrow the matrix (only the encrypted cells)"
	@echo "  make test-one         Run a single install, stop (MODE=auto, FILESYSTEM=btrfs)"
	@echo "  make test-one LUKS=1  single LUKS2-encrypted install"
	@echo "  make test-one LVM=1   single LVM install"
	@echo "  make test-one MANUAL=1  single manual install (formats Boot + System)"
	@echo "  make test-boot        Boot headless with /shared mounted; leave VM running"
	@echo "  make demo-snapshots   Put 5 demo snapshots on the test disk (needs test-boot running)"

# ===========================================================================
# Docker — ISO build pipeline (privileged container, writes ISO to output/)
# ===========================================================================

## Build & tag the toolchain image (aelum-image)
image:
	docker compose build $(BUILD_FLAGS)

## One-shot ISO build (reuses cached image layers by default)
build:
	docker compose run --rm \
		-e OUTPUT_UID=$(HOST_UID) \
		-e OUTPUT_GID=$(HOST_GID) \
		aelum

# Local build: build the ISO from the working trees next to docker/ instead of
# cloning the published installer/live-iso repos. The trees are copied to
# $(LOCAL_STAGE) and bind-mounted into the same one-shot container, so unpushed
# changes are included and the repos themselves never collect root-owned build
# artifacts. Output still lands in output/.
#
#   make local-build
#   LOCAL_STAGE=/var/tmp/aelum-dev make local-build
LOCAL_STAGE ?= /tmp/aelum-local-build
LOCAL_STAGE_ABS := $(abspath $(LOCAL_STAGE))

## Build the ISO from the local installer/ + live-iso/ working trees
local-build:
	@AELUM_LOCAL_STAGE="$(LOCAL_STAGE_ABS)" ./scripts/stage-local-repos.sh
	@docker image inspect aelum-image >/dev/null 2>&1 || docker compose build
	@echo "Building ISO from local repos in $(LOCAL_STAGE_ABS) (no git clone)"
	docker compose run --rm \
		-e OUTPUT_UID=$(HOST_UID) \
		-e OUTPUT_GID=$(HOST_GID) \
		-e SKIP_REPO_CLONE=1 \
		-e CHOWN_WORKTREES=1 \
		-v "$(LOCAL_STAGE_ABS)/live-iso:/app/live-iso" \
		-v "$(LOCAL_STAGE_ABS)/installer:/app/installer" \
		aelum

# Kept as an alias: older notes/docs called this target build-local.
build-local: local-build

## Remove the staged local-build tree (/tmp by default)
local-clean:
	@rm -rf "$(LOCAL_STAGE_ABS)" 2>/dev/null || { \
		echo "Removing root-owned staged files via aelum-image..."; \
		docker run --rm -v "$(LOCAL_STAGE_ABS):/stage" aelum-image rm -rf /stage; \
		rm -rf "$(LOCAL_STAGE_ABS)"; \
	}
	@echo "Removed $(LOCAL_STAGE_ABS)"

# Rebuild the toolchain image from the newest Arch base and bake the updated
# packages into it. The Dockerfile already runs `pacman -Syu`, but Docker's
# layer cache keeps the old `archlinux:latest` digest, so we force a clean
# rebuild (no-cache) to re-pull the base and re-run the toolchain install.
# The result is a saved, updated `aelum-image` for future builds.
update:
	docker compose stop aelum-shell aelum-local-shell 2>/dev/null || true
	docker rm -f aelum aelum-shell aelum-local-shell 2>/dev/null || true
	docker rmi -f aelum-image 2>/dev/null || true
	docker compose build --no-cache

# ===========================================================================
# Interactive dev shell (shares the build image, runs on the host's docker)
# ===========================================================================

## Start an interactive build/dev container (aelum-shell) and drop into bash
dev:
	docker compose up -d aelum-shell
	docker exec -it aelum-shell bash || true

## Start the local-repo dev shell (aelum-local-shell) and drop into bash.
## Reuses the same container on every run, so pacman/AUR caches survive; inside,
## run ./build-iso.sh after editing the host repos. Unlike local-build this
## mounts the real repos, so build artifacts (work/, build/bin, mirror) appear
## in them — build-iso.sh chowns them back to you after each run.
local-dev:
	@docker image inspect aelum-image >/dev/null 2>&1 || docker compose build
	@OUTPUT_UID=$(HOST_UID) OUTPUT_GID=$(HOST_GID) docker compose up -d aelum-local-shell
	docker exec -it aelum-local-shell bash || true

## Attach to the running aelum-shell (start it first with `make dev`)
attach:
	@if docker inspect -f '{{.State.Running}}' aelum-shell 2>/dev/null | grep -q true; then \
		docker exec -it aelum-shell bash; \
	else \
		echo "aelum-shell is not running. Start it with: make dev"; \
		exit 1; \
	fi

## Stop the interactive shells
stop:
	docker compose stop aelum-shell aelum-local-shell

## Stop + remove containers and prune anonymous volumes
clean:
	docker compose stop aelum-shell aelum-local-shell 2>/dev/null || true
	docker rm -f aelum aelum-shell aelum-local-shell 2>/dev/null || true
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
	@./scripts/sign-iso.sh

## Regenerate the WKD tree in the website repo (commit website/public/.well-known)
wkd:
	@./scripts/export-wkd.sh

## Upload assets + latest.json to R2 (TAG= required, ISO= optional)
##   make release-upload TAG=v2026.10.04
release-upload:
	@if [ -z "$(TAG)" ]; then \
		echo "ERROR: set TAG= (e.g. make release-upload TAG=v2026.10.04)"; exit 1; fi
	@./scripts/publish-iso.sh "$(TAG)" "${ISO:-}"

## Push the generated release.ts to the website repo (triggers GitHub Pages)
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
# QEMU — headless test (boot + drive aelum-installer-cli over SSH)
# ===========================================================================

## test: run EVERY install variation — auto/manual x btrfs/ext4 x LUKS x LVM
##       (16 cells by default), each with an independent post-install check.
##       This is heavy: every cell boots QEMU and does a full desktop install.
##   make test                              # all 16 variations
##   make test LUKSES=1                      # just the encrypted variations
##   make test LVMS=1                        # just the LVM variations
##   make test MODES=auto FILESYSTEMS=ext4
##   VERIFY=0 make test                      # skip the post-install inspection
##   SHARED_INSTALLER=1 make test            # drive installs from /shared
test: test-matrix

## one: run a SINGLE install with the given flags, then stop (for debugging one path)
##   SSH_PORT=2230 make test-one
##   LUKS=1 make test-one                 # encrypt the root partition with LUKS2
##   LUKS_PASS=... make test-one          # LUKS passphrase (default aelum-luks)
##   LVM=1 make test-one                  # root (and ext4 home) on LVM logical volumes
##   MANUAL=1 make test-one               # manual partitioning (formats Boot + System)
##   FILESYSTEM=ext4 make test-one        # root filesystem (btrfs | ext4)
##   VERIFY=0 make test-one               # skip the post-install inspection
##   SHARED_INSTALLER=1 make test-one     # drive the install with /shared/aelum-installer-cli
test-one:
	@MODE=auto \
	 FILESYSTEM="$(FILESYSTEM)" LUKS="$(LUKS)" LVM="$(LVM)" MANUAL="$(MANUAL)" \
	 VERIFY="$(VERIFY)" SHARED_INSTALLER="$(SHARED_INSTALLER)" \
	 LUKS_PASS="$(LUKS_PASS)" USER_PASS="$(USER_PASS)" \
	 USERNAME="$(USERNAME)" SSH_PORT="$(SSH_PORT)" \
	 ./scripts/test-install.sh

## boot: boot headless with /shared mounted; leave VM running
test-boot:
	@MODE=boot ./scripts/test-install.sh

## matrix: run every install combination and print a pass/fail summary
##       (this is what `make test` runs; kept as an explicit alias)
##   make test-matrix                              # all 16 combinations
##   make test-matrix LUKSES=1                      # only the encrypted cells
##   make test-matrix LVMS=1                        # only the LVM cells
##   make test-matrix MODES=auto FILESYSTEMS=ext4
##   SHARED_INSTALLER=1 make test-matrix            # drive installs from /shared
test-matrix:
	@MODES="$(MODES)" FILESYSTEMS="$(FILESYSTEMS)" LUKSES="$(LUKSES)" LVMS="$(LVMS)" \
	 VERIFY="$(VERIFY)" SHARED_INSTALLER="$(SHARED_INSTALLER)" \
	 ./scripts/test-all.sh

## run-disk: boot the system installed on the test disk, through its own rEFInd
##       (no ISO, no -boot d: OVMF follows its own boot order)
run-disk:
	@BOOT_DISK=1 ./scripts/run-iso.sh

# demo-snapshots: five snapshots on the test disk, so the rEFInd snapshot menu
# has something to show. The live ISO has to be running (test-boot); the script
# itself is copied into shared/, which the guest mounts at /shared.
SSH_PORT ?= 2222
DEMO_FLAGS := $(if $(filter 1,$(RESET)),--reset,)

## demo-snapshots: create 5 demo snapshots in the installed system on the test disk,
##       make sure its firmware entry exists, then power the VM off so
##       `make run-disk` can boot into that menu.
##   make test-boot && make demo-snapshots && make run-disk
##   make demo-snapshots RESET=1     delete the existing snapshots first
demo-snapshots:
	@if ! pgrep -f "qemu-system-x86_64.*vdisk.qcow2" >/dev/null 2>&1; then \
		echo "Start the test VM first:  make -C docker test-boot"; exit 1; \
	fi
	@cp scripts/demo-snapshots.sh ../shared/demo-snapshots.sh
	@ssh -p $(SSH_PORT) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost \
		'mount -o rw,subvol=@ /dev/vda2 /mnt || { echo "could not mount the installed root (LUKS or LVM install? mount it yourself, then run /shared/demo-snapshots.sh --root /mnt)"; exit 1; }; /shared/demo-snapshots.sh --root /mnt $(DEMO_FLAGS); sync; umount -R /mnt; efibootmgr 2>/dev/null | sed -n "s/^Boot\([0-9]*\)\* Aelum.*/\1/p" | xargs -r -n1 -I{} sh -c "efibootmgr -b {} -D >/dev/null"; efibootmgr -c -d /dev/vda -p 1 -L Aelum -l "\\EFI\\refind\\refind_x64.efi" >/dev/null; poweroff'
	@echo "Next:  make -C docker run-disk   (then select the snapshot icon and press F2)"
