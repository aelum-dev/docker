.PHONY: build shell stop attach

build:
	docker compose run --rm arch

run:
	docker compose up -d arch-shell
	docker exec -it arch-shell bash || true

stop:
	docker compose stop arch-shell

attach:
	docker exec -it arch bash
