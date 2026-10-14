# Targets live in scripts/makefiles/wasmvm.mk, included by the repository Makefile.
# `make -C x/wasm/wasmvm <goal>` forwards there. build/test/format/lint/bench
# keep their old names here and map to the wasmvm-* targets so they do not
# replace the terpd build.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)

.PHONY: build test format lint lint-fix bench
build:
	$(MAKE) -C $(ROOT) wasmvm-build
test:
	$(MAKE) -C $(ROOT) wasmvm-go-test
format:
	$(MAKE) -C $(ROOT) wasmvm-format
lint:
	$(MAKE) -C $(ROOT) wasmvm-lint
lint-fix:
	$(MAKE) -C $(ROOT) wasmvm-lint-fix
bench:
	$(MAKE) -C $(ROOT) wasmvm-bench

%:
	$(MAKE) -C $(ROOT) $@
