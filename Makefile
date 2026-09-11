.PHONY: build shell stop attach clean image test test-boot

image:
	docker compose build $(BUILD_FLAGS)

# Headless QEMU driver for the Aelum ISO (runs on the host, needs KVM + sshpass).
#   make test                 # auto: boot, run a full install, stop (default)
#   make test-boot            # boot headless with /shared mounted; leave VM running to launch the freshly built CLI from /shared
#   SSH_PORT=2230 make test   # use a different forwarded port
test:
	MODE=auto ./scripts/test-iso.sh

test-boot:
	MODE=boot ./scripts/test-iso.sh

BUILD_FLAGS:=
ifeq ($(NO_CACHE),1)
	BUILD_FLAGS:=--no-cache
endif

build:
	docker compose run --rm aelum

run:
	docker compose up -d aelum-shell
	docker exec -it aelum-shell bash || true

stop:
	docker compose stop aelum-shell

attach:
	docker exec -it aelum-shell bash

clean:
	docker compose stop aelum-shell 2>/dev/null || true
	docker rm -f aelum aelum-shell 2>/dev/null || true
	docker volume prune -f

