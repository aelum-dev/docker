.PHONY: build shell stop attach clean

build:
	docker compose run --rm arch

run:
	docker compose up -d arch-shell
	docker exec -it arch-shell bash || true

stop:
	docker compose stop arch-shell

attach:
	docker exec -it arch-shell bash

clean:
	docker compose stop arch-shell 2>/dev/null || true
	docker rm -f arch arch-shell 2>/dev/null || true
	docker volume prune -f

