###############################################################################
###                              libwasmvm                                  ###
###############################################################################
# Host-library builds for x/wasm/wasmvm. Included from the repository Makefile.
# 4.0.0-zk uses terpnetwork/zk-*-builder. CosmWasm libwasmvm-builder:0103-*
# is rustc 1.86 and cannot compile Path A.

WASMVM_DIR ?= x/wasm/wasmvm

ALPINE_TESTER := cosmwasm/alpine-tester:local

USER_ID := $(shell id -u)
USER_GROUP = $(shell id -g)

# Cargo path deps are ../../../../crates/cosmwasm from libwasmvm.
# Inside the builder, /code is libwasmvm, so that collapses to /crates/cosmwasm.
_HAS_LOCAL_DEPS := $(shell grep -q 'path = "../../../../crates/cosmwasm' $(WASMVM_DIR)/libwasmvm/Cargo.toml 2>/dev/null && echo yes)
ZK_COSMWASM_DIR ?= $(abspath $(CURDIR)/crates/cosmwasm)
ZK_ZCASH_DIR ?= $(abspath $(CURDIR)/crates/zcash)
ZK_ZAKURA_DIR ?= $(abspath $(CURDIR)/crates/zakura-common)
ZK_FLOCK_DIR ?= $(abspath $(CURDIR)/crates/flock)
ZK_VOTE_DIR ?= $(abspath $(CURDIR)/crates/vote-sdk)

_LOCAL_MOUNTS = $(if $(_HAS_LOCAL_DEPS),-v $(ZK_COSMWASM_DIR):/crates/cosmwasm -v $(ZK_ZCASH_DIR):/crates/zcash -v $(ZK_ZAKURA_DIR):/crates/zakura-common -v $(ZK_FLOCK_DIR):/crates/flock -v $(ZK_VOTE_DIR):/crates/vote-sdk)

# Build the images once: (cd builders && make docker-images-4.0.0-zk)
DOCKER_PLATFORM ?= linux/amd64
ZK_ALPINE_BUILDER ?= terpnetwork/zk-alpine-builder:4.0.0-zk
ZK_DEBIAN_BUILDER ?= terpnetwork/zk-debian-builder:4.0.0-zk
ZK_CROSS_BUILDER ?= terpnetwork/zk-cross-builder:4.0.0-zk
_ALPINE_BUILDER = $(ZK_ALPINE_BUILDER)
_DEBIAN_BUILDER = $(ZK_DEBIAN_BUILDER)
_CROSS_BUILDER = $(ZK_CROSS_BUILDER)
_DOCKER_RUN = docker run --rm --platform $(DOCKER_PLATFORM) -v $(abspath $(WASMVM_DIR))/libwasmvm:/code $(_LOCAL_MOUNTS)

SHARED_LIB_SRC = ""
SHARED_LIB_DST = ""
ifeq ($(OS),Windows_NT)
	SHARED_LIB_SRC = wasmvm.dll
	SHARED_LIB_DST = wasmvm.dll
else
	WASMVM_UNAME_S := $(shell uname -s)
	ifeq ($(WASMVM_UNAME_S),Linux)
		SHARED_LIB_SRC = libwasmvm.so
		SHARED_LIB_DST = libwasmvm.$(shell rustc --print cfg | grep target_arch | cut -d '"' -f 2).so
	endif
	ifeq ($(WASMVM_UNAME_S),Darwin)
		SHARED_LIB_SRC = libwasmvm.dylib
		SHARED_LIB_DST = libwasmvm.dylib
	endif
endif

.PHONY: wasmvm-help
wasmvm-help:
	@echo "libwasmvm (x/wasm/wasmvm, scripts/makefiles/wasmvm.mk)"
	@echo ""
	@echo "  wasmvm-build                         cargo release lib + go build of the wasmvm module"
	@echo "  build-libwasmvm                      native cargo release into internal/api"
	@echo "  release-build                        alpine muslc + glibc .so + macos dylib, then verify"
	@echo "  release-build-linux                  glibc .so only (what Linux go test links)"
	@echo "  release-build-macos-static-arm64     native Darwin static archive"
	@echo "  verify-libwasmvm                     fail if muslc and .so are mixed generations"
	@echo "  wasmvm-release-build                 same as release-build (release.mk alias)"

test-filenames:
	echo $(SHARED_LIB_DST)
	echo $(SHARED_LIB_SRC)

.PHONY: wasmvm-build
wasmvm-build:
	$(MAKE) build-libwasmvm
	$(MAKE) build-go

.PHONY: build-libwasmvm-debug
build-libwasmvm-debug:
	cd $(WASMVM_DIR)/libwasmvm && cargo build
	cp $(WASMVM_DIR)/libwasmvm/target/debug/$(SHARED_LIB_SRC) $(WASMVM_DIR)/internal/api/$(SHARED_LIB_DST)
	$(MAKE) update-bindings

.PHONY: build-libwasmvm
build-libwasmvm:
	cd $(WASMVM_DIR)/libwasmvm && cargo build --release
	cp $(WASMVM_DIR)/libwasmvm/target/release/$(SHARED_LIB_SRC) $(WASMVM_DIR)/internal/api/$(SHARED_LIB_DST)
	$(MAKE) update-bindings

.PHONY: doc-rust
doc-rust:
	cd $(WASMVM_DIR)/libwasmvm && cargo doc --no-deps --open

.PHONY: build-go
build-go:
	cd $(WASMVM_DIR) && go build ./...
	cd $(WASMVM_DIR) && go build -o build/demo ./cmd/demo

.PHONY: wasmvm-go-test
wasmvm-go-test:
	cd $(WASMVM_DIR) && RUST_BACKTRACE=1 go test -v -count=1 ./...

.PHONY: test-safety
test-safety:
	cd $(WASMVM_DIR) && GOEXPERIMENT=cgocheck2 go test -race -v -count=1 ./...

.PHONY: wasmvm-bench
wasmvm-bench:
	cd $(WASMVM_DIR) && go test -bench . -benchtime=2s -run=^Benchmark ./...

release-build-alpine:
	@echo "$(_ALPINE_BUILDER)" | grep -q 'terpnetwork/zk-alpine-builder' \
		|| { echo "ERROR: alpine builder must be terpnetwork/zk-alpine-builder:4.0.0-zk, not CosmWasm 0103. Got $(_ALPINE_BUILDER)" >&2; exit 1; }
ifdef _HAS_LOCAL_DEPS
	@echo "==> Detected local path deps — mounting $(ZK_COSMWASM_DIR) at /crates/cosmwasm"
endif
	@echo "==> Using builder: $(_ALPINE_BUILDER)"
	$(_DOCKER_RUN) $(_ALPINE_BUILDER)
	cp $(WASMVM_DIR)/libwasmvm/artifacts/libwasmvm_muslc.x86_64.a $(WASMVM_DIR)/internal/api
	cp $(WASMVM_DIR)/libwasmvm/artifacts/libwasmvm_muslc.aarch64.a $(WASMVM_DIR)/internal/api
	$(MAKE) update-bindings

release-build-linux:
	@echo "$(_DEBIAN_BUILDER)" | grep -q 'terpnetwork/zk-debian-builder' \
		|| { echo "ERROR: debian builder must be terpnetwork/zk-debian-builder:4.0.0-zk, not CosmWasm 0103. Got $(_DEBIAN_BUILDER)" >&2; exit 1; }
	@echo "==> Using builder: $(_DEBIAN_BUILDER)"
	$(_DOCKER_RUN) $(_DEBIAN_BUILDER) build_gnu_x86_64.sh
	$(_DOCKER_RUN) $(_DEBIAN_BUILDER) build_gnu_aarch64.sh
	cp $(WASMVM_DIR)/libwasmvm/artifacts/libwasmvm.x86_64.so $(WASMVM_DIR)/internal/api
	cp $(WASMVM_DIR)/libwasmvm/artifacts/libwasmvm.aarch64.so $(WASMVM_DIR)/internal/api
	$(MAKE) update-bindings

release-build-macos:
	$(_DOCKER_RUN) $(_CROSS_BUILDER) build_macos.sh
	cp $(WASMVM_DIR)/libwasmvm/artifacts/libwasmvm.dylib $(WASMVM_DIR)/internal/api
	$(MAKE) update-bindings

release-build-macos-static:
	$(_DOCKER_RUN) -e UNIVERSAL=$(UNIVERSAL) $(_CROSS_BUILDER) build_macos_static.sh
	cp $(WASMVM_DIR)/libwasmvm/artifacts/libwasmvmstatic_darwin.a $(WASMVM_DIR)/internal/api/libwasmvmstatic_darwin.a
	$(MAKE) update-bindings

.PHONY: release-build-macos-static-arm64
release-build-macos-static-arm64:
	@bash $(CURDIR)/builders/host/build_macos_static_arm64.sh

release-build-windows:
	$(_DOCKER_RUN) $(_CROSS_BUILDER) build_windows.sh
	cp $(WASMVM_DIR)/libwasmvm/artifacts/wasmvm.dll $(WASMVM_DIR)/internal/api
	$(MAKE) update-bindings

BUILDER_IMAGE ?= terpnetwork/zk-alpine-builder:4.0.0-zk

release-build-alpine-custom:
	@echo "==> Using builder: $(BUILDER_IMAGE)"
	$(_DOCKER_RUN) $(BUILDER_IMAGE)
	cp $(WASMVM_DIR)/libwasmvm/artifacts/libwasmvm_muslc.x86_64.a $(WASMVM_DIR)/internal/api
	cp $(WASMVM_DIR)/libwasmvm/artifacts/libwasmvm_muslc.aarch64.a $(WASMVM_DIR)/internal/api
	$(MAKE) update-bindings

update-bindings:
	cp $(WASMVM_DIR)/libwasmvm/bindings.h $(WASMVM_DIR)/internal/api

.PHONY: release-build
release-build:
	$(MAKE) release-build-alpine
	$(MAKE) release-build-linux
	$(MAKE) release-build-macos
	$(MAKE) verify-libwasmvm

.PHONY: verify-libwasmvm
verify-libwasmvm:
	@chmod +x $(CURDIR)/builders/host/verify_libwasmvm.sh
	@bash $(CURDIR)/builders/host/verify_libwasmvm.sh

.PHONY: create-tester-image
create-tester-image:
	docker build -t $(ALPINE_TESTER) - < $(WASMVM_DIR)/Dockerfile.alpine_tester

test-alpine: release-build-alpine create-tester-image
	docker run --rm -u $(USER_ID):$(USER_GROUP) -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun $(ALPINE_TESTER) go build -tags muslc ./...
	docker run --rm -u $(USER_ID):$(USER_GROUP) -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun $(ALPINE_TESTER) go test -tags muslc -count=1 ./...
	docker run --rm -u $(USER_ID):$(USER_GROUP) -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun $(ALPINE_TESTER) ./build_demo.sh
	docker run --rm -u $(USER_ID):$(USER_GROUP) -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun $(ALPINE_TESTER) file ./demo
	docker run --rm --read-only -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun alpine:3.18 ./demo ./artifacts/hackatom.wasm
	docker run --rm --read-only -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun alpine:3.17 ./demo ./artifacts/hackatom.wasm
	docker run --rm --read-only -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun alpine:3.16 ./demo ./artifacts/hackatom.wasm
	docker run --rm --read-only -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun alpine:3.15 ./demo ./artifacts/hackatom.wasm
	docker run --rm --read-only -v $(abspath $(WASMVM_DIR)):/mnt/testrun -w /mnt/testrun alpine:3.14 ./demo ./artifacts/hackatom.wasm

.PHONY: wasmvm-format
wasmvm-format:
	find $(WASMVM_DIR) -name '*.go' -type f | xargs gofumpt -w

.PHONY: wasmvm-lint
wasmvm-lint:
	cd $(WASMVM_DIR) && golangci-lint run

.PHONY: wasmvm-lint-fix
wasmvm-lint-fix:
	cd $(WASMVM_DIR) && golangci-lint run --fix
