.PHONY: build shell stop attach clean image

image:
	docker compose build $(BUILD_FLAGS)

BUILD_FLAGS:=
ifeq ($(NO_CACHE),1)
	BUILD_FLAGS:=--no-cache
endif

build:
	docker compose run --rm aestheticos

run:
	docker compose up -d aestheticos-shell
	docker exec -it aestheticos-shell bash || true

stop:
	docker compose stop aestheticos-shell

attach:
	docker exec -it aestheticos-shell bash

clean:
	docker compose stop aestheticos-shell 2>/dev/null || true
	docker rm -f aestheticos aestheticos-shell 2>/dev/null || true
	docker volume prune -f

