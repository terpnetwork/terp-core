# Builds the Rust library libwasmvm.
# 4.0.0-zk: ALWAYS terpnetwork/zk-*-builder (see docs/BUILDERS.md).
# CosmWasm libwasmvm-builder:0103-* is rustc 1.86 and cannot compile Path A.
# Contains a full Go dev environment including CGO support in order to run Go tests on the built shared library
# This image is currently not published.
ALPINE_TESTER := cosmwasm/alpine-tester:local

USER_ID := $(shell id -u)
USER_GROUP = $(shell id -g)

# ---------------------------------------------------------------------------
# Local path dependencies — auto-detected from libwasmvm/Cargo.toml
#
# If Cargo.toml has path deps like ../../cosmwasm/packages/std,
# the Docker builder must mount that source tree or the build will fail.
# From inside the container /code = libwasmvm/, so the relative path
# ../../cosmwasm resolves to /cw/zk-cosmwasm.
#
# Override the local path:
#   make release-build-alpine ZK_COSMWASM_DIR=/path/to/zk-cosmwasm
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
_HAS_LOCAL_DEPS := $(shell grep -q 'path = "../../cosmwasm' libwasmvm/Cargo.toml 2>/dev/null && echo yes)
ZK_COSMWASM_DIR ?= $(shell cd "$$(pwd)/../cosmwasm" 2>/dev/null && pwd)
ZK_ZCASH_DIR ?= $(shell cd "$$(pwd)/../zcash" 2>/dev/null && pwd)
ZK_ZAKURA_DIR ?= $(shell cd "$$(pwd)/../zakura-common" 2>/dev/null && pwd)
ZK_FLOCK_DIR ?= $(shell cd "$$(pwd)/../flock" 2>/dev/null && pwd)

# Extra docker volume mounts when local path deps are detected.
# Container paths must match Cargo.toml: /cosmwasm, /zakura-common, /flock, /zcash.
_LOCAL_MOUNTS = $(if $(_HAS_LOCAL_DEPS),-v $(ZK_COSMWASM_DIR):/cosmwasm -v $(ZK_ZCASH_DIR):/zcash -v $(ZK_ZAKURA_DIR):/zakura-common -v $(ZK_FLOCK_DIR):/flock)


# 4.0.0-zk: ALWAYS our images. Do not pull cosmwasm/libwasmvm-builder:0103-*.
# Build once: (cd builders && make docker-images-4.0.0-zk)
DOCKER_PLATFORM ?= linux/amd64
ZK_ALPINE_BUILDER ?= terpnetwork/zk-alpine-builder:4.0.0-zk
ZK_DEBIAN_BUILDER ?= terpnetwork/zk-debian-builder:4.0.0-zk
ZK_CROSS_BUILDER ?= terpnetwork/zk-cross-builder:4.0.0-zk
_ALPINE_BUILDER = $(ZK_ALPINE_BUILDER)
_DEBIAN_BUILDER = $(ZK_DEBIAN_BUILDER)
_CROSS_BUILDER = $(ZK_CROSS_BUILDER)
_DOCKER_RUN = docker run --rm --platform $(DOCKER_PLATFORM) -v $(shell pwd)/libwasmvm:/code $(_LOCAL_MOUNTS)

SHARED_LIB_SRC = "" # File name of the shared library as created by the Rust build system
SHARED_LIB_DST = "" # File name of the shared library that we store
ifeq ($(OS),Windows_NT)
	SHARED_LIB_SRC = wasmvm.dll
	SHARED_LIB_DST = wasmvm.dll
else
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S),Linux)
		SHARED_LIB_SRC = libwasmvm.so
		SHARED_LIB_DST = libwasmvm.$(shell rustc --print cfg | grep target_arch | cut  -d '"' -f 2).so
	endif
	ifeq ($(UNAME_S),Darwin)
		SHARED_LIB_SRC = libwasmvm.dylib
		SHARED_LIB_DST = libwasmvm.dylib
	endif
endif

test-filenames:
	echo $(SHARED_LIB_DST)
	echo $(SHARED_LIB_SRC)

.PHONY: build
build:
	make build-libwasmvm
	make build-go

# Use debug build for quick testing.
# In order to use "--features backtraces" here we need a Rust nightly toolchain, which we don't have by default
.PHONY: build-libwasmvm-debug
build-libwasmvm-debug:
	(cd libwasmvm && cargo build)
	cp libwasmvm/target/debug/$(SHARED_LIB_SRC) internal/api/$(SHARED_LIB_DST)
	make update-bindings

# use release build to actually ship - smaller and much faster
.PHONY: build-libwasmvm
build-libwasmvm:
	(cd libwasmvm && cargo build --release)
	cp libwasmvm/target/release/$(SHARED_LIB_SRC) internal/api/$(SHARED_LIB_DST)
	make update-bindings

# build and show the Rust documentation of the wasmvm
.PHONY: doc-rust
doc-rust:
	(cd libwasmvm && cargo doc --no-deps --open)

.PHONY: build-go
build-go:
	go build ./...
	go build -o build/demo ./cmd/demo

.PHONY: test
test:
	# Use package list mode to include all subdirectores. The -count=1 turns off caching.
	RUST_BACKTRACE=1 go test -v -count=1 ./...

.PHONY: test-safety
test-safety:
	# Use package list mode to include all subdirectores. The -count=1 turns off caching.
	GOEXPERIMENT=cgocheck2 go test -race -v -count=1 ./...

# Run all Go benchmarks
.PHONY: bench
bench:
	go test -bench . -benchtime=2s -run=^Benchmark ./...

# Creates a release build in a containerized build environment of the static library for Alpine Linux (.a)
release-build-alpine:
	@echo "$(_ALPINE_BUILDER)" | grep -q 'terpnetwork/zk-alpine-builder' \
		|| { echo "ERROR: alpine builder must be terpnetwork/zk-alpine-builder:4.0.0-zk, not CosmWasm 0103. Got $(_ALPINE_BUILDER)" >&2; exit 1; }
ifdef _HAS_LOCAL_DEPS
	@echo "==> Detected local path deps — mounting $(ZK_COSMWASM_DIR) at /cw/zk-cosmwasm"
endif
	@echo "==> Using builder: $(_ALPINE_BUILDER)"
	$(_DOCKER_RUN) $(_ALPINE_BUILDER)
	cp libwasmvm/artifacts/libwasmvm_muslc.x86_64.a internal/api
	cp libwasmvm/artifacts/libwasmvm_muslc.aarch64.a internal/api
	make update-bindings

# glibc Linux .so — this is what `go test` on Linux links (NOT the muslc .a).
# Must be OUR debian image. CosmWasm 0103-debian is the mixed-generation trip.
release-build-linux:
	@echo "$(_DEBIAN_BUILDER)" | grep -q 'terpnetwork/zk-debian-builder' \
		|| { echo "ERROR: debian builder must be terpnetwork/zk-debian-builder:4.0.0-zk, not CosmWasm 0103. Got $(_DEBIAN_BUILDER)" >&2; exit 1; }
	@echo "==> Using builder: $(_DEBIAN_BUILDER)"
	$(_DOCKER_RUN) $(_DEBIAN_BUILDER) build_gnu_x86_64.sh
	$(_DOCKER_RUN) $(_DEBIAN_BUILDER) build_gnu_aarch64.sh
	cp libwasmvm/artifacts/libwasmvm.x86_64.so internal/api
	cp libwasmvm/artifacts/libwasmvm.aarch64.so internal/api
	make update-bindings

# macOS .dylib (osxcross). Native Darwin: make build-libwasmvm.
release-build-macos:
	$(_DOCKER_RUN) $(_CROSS_BUILDER) build_macos.sh
	cp libwasmvm/artifacts/libwasmvm.dylib internal/api
	make update-bindings

# Creates a release build in a containerized build environment of the static library for macOS (.a)
# UNIVERSAL=1 (docker only) also builds x86_64 and lipo. Default is aarch64-only.
release-build-macos-static:
	$(_DOCKER_RUN) -e UNIVERSAL=$(UNIVERSAL) $(_CROSS_BUILDER) build_macos_static.sh
	cp libwasmvm/artifacts/libwasmvmstatic_darwin.a internal/api/libwasmvmstatic_darwin.a
	make update-bindings

# Native Darwin arm64 static archive (no Docker). Use this on a Mac to curate
# libwasmvmstatic_darwin.a for `go build -tags static_wasm`.
.PHONY: release-build-macos-static-arm64
release-build-macos-static-arm64:
	@bash builders/host/build_macos_static_arm64.sh

# Creates a release build in a containerized build environment of the shared library for Windows (.dll)
release-build-windows:
	$(_DOCKER_RUN) $(_CROSS_BUILDER) build_windows.sh
	cp libwasmvm/artifacts/wasmvm.dll internal/api
	make update-bindings
	
BUILDER_IMAGE ?= terpnetwork/zk-alpine-builder:4.0.0-zk

release-build-alpine-custom:
	@echo "==> Using builder: $(BUILDER_IMAGE)"
	$(_DOCKER_RUN) $(BUILDER_IMAGE)
	cp libwasmvm/artifacts/libwasmvm_muslc.x86_64.a internal/api
	cp libwasmvm/artifacts/libwasmvm_muslc.aarch64.a internal/api
	make update-bindings


update-bindings:
# After we build libwasmvm, we have to copy the generated bindings for Go code to use.
# We cannot use symlinks as those are not reliably resolved by `go get` (https://github.com/CosmWasm/wasmvm/pull/235).
	cp libwasmvm/bindings.h internal/api

# One generation of ALL host libs into internal/api. Do not recut muslc
# without also recutting glibc .so — Linux go test links the .so.
.PHONY: release-build
release-build:
	$(MAKE) release-build-alpine
	$(MAKE) release-build-linux
	$(MAKE) release-build-macos
	$(MAKE) verify-libwasmvm

.PHONY: verify-libwasmvm
verify-libwasmvm:
	@chmod +x builders/host/verify_libwasmvm.sh
	@bash builders/host/verify_libwasmvm.sh

.PHONY: create-tester-image
create-tester-image:
	docker build -t $(ALPINE_TESTER) - < ./Dockerfile.alpine_tester

test-alpine: release-build-alpine create-tester-image
# try running go tests using this lib with muslc
	docker run --rm -u $(USER_ID):$(USER_GROUP) -v $(shell pwd):/mnt/testrun -w /mnt/testrun $(ALPINE_TESTER) go build -tags muslc ./...
# Use package list mode to include all subdirectores. The -count=1 turns off caching.
	docker run --rm -u $(USER_ID):$(USER_GROUP) -v $(shell pwd):/mnt/testrun -w /mnt/testrun $(ALPINE_TESTER) go test -tags muslc -count=1 ./...

	@# Build a Go demo binary called ./demo that links the static library from the previous step.
	@# Whether the result is a statically linked or dynamically linked binary is decided by `go build`
	@# and it's a bit unclear how this is decided. We use `file` to see what we got.
	docker run --rm -u $(USER_ID):$(USER_GROUP) -v $(shell pwd):/mnt/testrun -w /mnt/testrun $(ALPINE_TESTER) ./build_demo.sh
	docker run --rm -u $(USER_ID):$(USER_GROUP) -v $(shell pwd):/mnt/testrun -w /mnt/testrun $(ALPINE_TESTER) file ./demo

	@# Run the demo binary on Alpine machines
	@# See https://de.wikipedia.org/wiki/Alpine_Linux#Versionen for supported versions
	docker run --rm --read-only -v $(shell pwd):/mnt/testrun -w /mnt/testrun alpine:3.18 ./demo ./testdata/hackatom.wasm
	docker run --rm --read-only -v $(shell pwd):/mnt/testrun -w /mnt/testrun alpine:3.17 ./demo ./testdata/hackatom.wasm
	docker run --rm --read-only -v $(shell pwd):/mnt/testrun -w /mnt/testrun alpine:3.16 ./demo ./testdata/hackatom.wasm
	docker run --rm --read-only -v $(shell pwd):/mnt/testrun -w /mnt/testrun alpine:3.15 ./demo ./testdata/hackatom.wasm
	docker run --rm --read-only -v $(shell pwd):/mnt/testrun -w /mnt/testrun alpine:3.14 ./demo ./testdata/hackatom.wasm

	@# Run binary locally if you are on Linux
	@# ./demo ./testdata/hackatom.wasm

.PHONY: format
format:
	find . -name '*.go' -type f | xargs gofumpt -w

.PHONY: lint
lint:
	golangci-lint run

.PHONY: lint-fix
lint-fix:
	golangci-lint run --fix
