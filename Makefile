.PHONY: build shell attach

build:
	docker compose run --rm arch

shell:
	docker compose run --rm arch-shell || true

attach:
	docker exec -it arch-shell bash
