.PHONY: build shell attach

build:
	docker compose run --rm arch

shell:
	docker compose run --rm arch-shell

attach:
	docker exec -it arch-shell bash
