.PHONY: help build image update run attach stop clean test test-boot run-iso run-iso-clean release

BUILD_FLAGS:=
ifeq ($(NO_CACHE),1)
	BUILD_FLAGS:=--no-cache
endif

# ===========================================================================
# Docker — ISO build pipeline (privileged container, writes ISO to output/)
# ===========================================================================

# Build the toolchain image (aelum-image) and tag it.
#   make image            # build & tag, using cache
#   make image NO_CACHE=1 # force a fresh build (--no-cache)
image:
	docker compose build $(BUILD_FLAGS)

# One-shot ISO build (reuses cached image layers by default).
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

# Interactive build container (aelum-shell).
run:
	docker compose up -d aelum-shell
	docker exec -it aelum-shell bash || true

attach:
	docker exec -it aelum-shell bash

stop:
	docker compose stop aelum-shell

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

# ===========================================================================
# QEMU — boot the built ISO (runs on the host, needs KVM + sshpass)
# ===========================================================================

# Launch the latest ISO in output/ in QEMU (display, UEFI, shared dir, SSH fwd).
#   XRES=2560 YRES=1440 make run-iso   # override resolution
run-iso:
	./scripts/run-iso.sh

# Remove OVMF_VARS.fd (recreated from the system template on next run) then
# launch the latest ISO in QEMU. Useful when the UEFI NVRAM is corrupted.
run-iso-clean:
	rm -f OVMF_VARS.fd
	./scripts/run-iso.sh

# ===========================================================================
# QEMU — headless test (boot + drive aelum-installer-cli over SSH)
# ===========================================================================

#   make test                 # auto: boot, run a full install, stop (default)
#   make test-boot            # boot headless with /shared mounted; leave VM running
#   SSH_PORT=2230 make test   # use a different forwarded port
test:
	MODE=auto ./scripts/test-iso.sh

test-boot:
	MODE=boot ./scripts/test-iso.sh
