.PHONY: build shell stop

build:
	docker compose run --rm arch

run:
	docker compose up -d arch-shell
	docker exec -it arch-shell bash

stop:
	docker compose stop arch-shell
