SHELL := /usr/bin/env bash

.PHONY: bootstrap-ice40 build-ice40 test-blinky toolchain-env

bootstrap-ice40:
	@./scripts/ice40/bootstrap.sh

bootstrap-ice40-system:
	@NEXTPNR_MVP_DEPS_BACKEND=system ./scripts/ice40/bootstrap.sh

build-ice40:
	@./scripts/ice40/bootstrap.sh

test-blinky:
	@./scripts/ice40/e2e_blinky.sh

test-blinky-system:
	@NEXTPNR_MVP_DEPS_BACKEND=system ./scripts/ice40/e2e_blinky.sh

toolchain-env:
	@echo "Run: source ./scripts/ice40/env.sh"
