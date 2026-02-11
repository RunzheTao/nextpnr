SHELL := /usr/bin/env bash

BOOTSTRAP_ARCHES := \
	ice40 \
	ecp5 \
	nexus \
	machxo2 \
	mistral \
	generic \
	himbaechel-gowin \
	himbaechel-ng-ultra \
	himbaechel-gatemate

BOOTSTRAP_TARGETS := $(addprefix bootstrap-,$(BOOTSTRAP_ARCHES))
BOOTSTRAP_SYSTEM_TARGETS := $(addsuffix -system,$(BOOTSTRAP_TARGETS))

.PHONY: $(BOOTSTRAP_TARGETS) $(BOOTSTRAP_SYSTEM_TARGETS) \
	bootstrap-arch-deps \
	bootstrap-ecp5-python bootstrap-ecp5-python-system \
	build-ice40 \
	test-blinky test-blinky-system \
	test-ecp5-bookshelf test-ecp5-bookshelf-system \
	test-generic test-generic-system \
	test-machxo2 test-machxo2-system \
	clean-bench \
	toolchain-env toolchain-env-% deps-env

bootstrap-arch-deps:
	@./scripts/common/install_external_deps.sh

$(BOOTSTRAP_TARGETS):
	@./scripts/$(@:bootstrap-%=%)/bootstrap.sh

$(BOOTSTRAP_SYSTEM_TARGETS):
	@NEXTPNR_MVP_DEPS_BACKEND=system ./scripts/$(@:bootstrap-%-system=%)/bootstrap.sh

bootstrap-ecp5-python:
	@NEXTPNR_MVP_BUILD_PYTHON=1 ./scripts/ecp5/bootstrap.sh

bootstrap-ecp5-python-system:
	@NEXTPNR_MVP_DEPS_BACKEND=system NEXTPNR_MVP_BUILD_PYTHON=1 ./scripts/ecp5/bootstrap.sh

build-ice40: bootstrap-ice40

test-blinky:
	@./scripts/ice40/e2e_blinky.sh

test-blinky-system:
	@NEXTPNR_MVP_DEPS_BACKEND=system ./scripts/ice40/e2e_blinky.sh

test-ecp5-bookshelf:
	@./scripts/ecp5/e2e_bookshelf_unified.sh

test-ecp5-bookshelf-system:
	@NEXTPNR_MVP_DEPS_BACKEND=system ./scripts/ecp5/e2e_bookshelf_unified.sh

test-generic:
	@./scripts/generic/e2e_smoke.sh

test-generic-system:
	@NEXTPNR_MVP_DEPS_BACKEND=system ./scripts/generic/e2e_smoke.sh

test-machxo2:
	@./scripts/machxo2/e2e_smoke.sh

test-machxo2-system:
	@NEXTPNR_MVP_DEPS_BACKEND=system ./scripts/machxo2/e2e_smoke.sh

clean-bench:
	@rm -rf ./_bench/ecp5_unified/out
	@rm -f ./_bench/ecp5_unified/synth.log ./_bench/ecp5_unified/netlist.sha256 ./_bench/ecp5_unified/unified_bench.json

toolchain-env:
	@echo "Run: source ./scripts/ice40/env.sh"

toolchain-env-%:
	@echo "Run: source ./scripts/$*/env.sh"

deps-env:
	@echo "Run: source ./_deps/arch-deps.env"
