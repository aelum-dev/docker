.PHONY: build shell attach

build:
	docker compose run --rm arch

shell:
	docker compose up -d arch-shell
	docker exec -it arch-shell bash

attach:
	docker exec -it arch-shell bash
