.PHONY: build shell stop attach clean image test

image:
	docker compose build $(BUILD_FLAGS)

# Headless QEMU + installer-cli test (runs on the host, needs KVM + sshpass).
#   make test            # real install (default)
#   MODE=dry make test   # dry-run smoke test (fast, no real disk writes)
#   SSH_PORT=2230 make test   # use a different forwarded port
test:
	./scripts/test-iso.sh

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

