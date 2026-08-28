.PHONY: build shell stop attach clean image

image:
	docker compose build $(BUILD_FLAGS)

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

