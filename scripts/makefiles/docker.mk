###############################################################################
###                                Docker                                  ###
###############################################################################

RUNNER_BASE_IMAGE_DISTROLESS := gcr.io/distroless/static-debian11
RUNNER_BASE_IMAGE_ALPINE := alpine:3.17
RUNNER_BASE_IMAGE_NONROOT := gcr.io/distroless/static-debian11:nonroot

# ---------------------------------------------------------------------------
# WASMVM_LIB — optional path to a pre-built libwasmvm_muslc .a file.
#
# Standard build (download from CosmWasm GitHub releases):
#   make docker-build
#
# Local build (use your own pre-built static lib):
#   make docker-build WASMVM_LIB=../zk-wasmvm/internal/api/libwasmvm_muslc.aarch64.a
#
# When WASMVM_LIB is set, the lib + Go source for zk-wasmvm and zk-wasmd
# are staged into build/ so the Dockerfile can COPY them.
# ---------------------------------------------------------------------------

WASMVM_LIB ?=

# Upstream version for GitHub download URL (auto-detected from go.mod).
COSMWASM_VERSION ?= $(shell grep 'CosmWasm/wasmvm' go.mod 2>/dev/null | grep -v '=>' | awk '{print $$2}')

# Derived source mode: local when WASMVM_LIB is set, github otherwise.
_WASMVM_SOURCE = $(if $(WASMVM_LIB),local,github)

# Sibling repo paths for staging Go source (only used when WASMVM_LIB is set).
ZK_WASMVM_DIR ?= ../zk-wasmvm
ZK_WASMD_DIR  ?= ../zk-wasmd

.PHONY: docker docker-help docker-build docker-build-distroless docker-build-alpine \
	docker-build-nonroot docker-build-localnet docker-localterp docker-clean \
	build-zk-local build-zk-local-localnet _docker-stage-zk-lib \
	docker-build-zk docker-build-zk-localnet docker-stage-zk docker-clean-zk \
	_docker-stage

docker-help:
	@echo "docker subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make docker-build                                         # GitHub wasmvm"
	@echo "  make docker-build WASMVM_LIB=path/to/libwasmvm_muslc.a    # local wasmvm"
	@echo ""
	@echo "Available Commands:"
	@echo "  docker-build                Build Docker image (distroless runtime)"
	@echo "  docker-build-alpine         Build alpine Docker image"
	@echo "  docker-build-nonroot        Build nonroot Docker image"
	@echo "  docker-build-localnet       Build localterp dev image"
	@echo "  docker-localterp            Alias for docker-build-localnet"
	@echo "  build-zk-local              Build with ../zk-wasmvm (auto-detect lib)"
	@echo "  build-zk-local-localnet     Build localterp with ../zk-wasmvm"
	@echo "  docker-clean                Remove staged wasmvm dependencies"
	@echo ""
	@echo "Current config:"
	@echo "  WASMVM_LIB       = $(or $(WASMVM_LIB),(unset — will download from GitHub))"
	@echo "  COSMWASM_VERSION = $(COSMWASM_VERSION)"
	@echo "  WASMVM_SOURCE    = $(_WASMVM_SOURCE)"
docker: docker-help

# ---------------------------------------------------------
# Stage local wasmvm lib + Go source (no-op when WASMVM_LIB is unset)
# ---------------------------------------------------------

_docker-stage:
ifdef WASMVM_LIB
	@echo "==> Staging local wasmvm lib: $(WASMVM_LIB)"
	@mkdir -p build/wasmvm build/zk-deps/zk-wasmvm build/zk-deps/zk-wasmd
	@cp $(WASMVM_LIB) build/wasmvm/
	@echo "==> Staging zk-wasmvm Go source (excluding target/ and .git/) ..."
	@rsync -a --delete \
		--exclude='libwasmvm/target/' \
		--exclude='.git/' \
		$(ZK_WASMVM_DIR)/ build/zk-deps/zk-wasmvm/
	@echo "==> Staging zk-wasmd Go source ..."
	@rsync -a --delete \
		--exclude='.git/' \
		$(ZK_WASMD_DIR)/ build/zk-deps/zk-wasmd/
	@echo "==> Staged:"
	@ls -lh build/wasmvm/
endif

docker-clean:
	@echo "==> Removing staged wasmvm dependencies ..."
	rm -rf build/zk-deps build/wasmvm
	@echo "Done."

# ---------------------------------------------------------
# Build targets — all respect WASMVM_LIB
# ---------------------------------------------------------

docker-build: _docker-stage
	@DOCKER_BUILDKIT=1 docker build \
		-t terpnetwork/terp-core:local \
		--target runtime \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg RUNNER_IMAGE=$(RUNNER_BASE_IMAGE_DISTROLESS) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg COSMWASM_VERSION=$(COSMWASM_VERSION) \
		--build-arg WASMVM_SOURCE=$(_WASMVM_SOURCE) \
		-f Dockerfile .

docker-build-distroless: docker-build

docker-build-alpine: _docker-stage
	@DOCKER_BUILDKIT=1 docker build \
		-t terpnetwork/terp-core:local-alpine \
		--target runtime \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg RUNNER_IMAGE=$(RUNNER_BASE_IMAGE_ALPINE) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg COSMWASM_VERSION=$(COSMWASM_VERSION) \
		--build-arg WASMVM_SOURCE=$(_WASMVM_SOURCE) \
		-f Dockerfile .

docker-build-nonroot: _docker-stage
	@DOCKER_BUILDKIT=1 docker build \
		-t terpnetwork/terp-core:local-nonroot \
		--target runtime \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg RUNNER_IMAGE=$(RUNNER_BASE_IMAGE_NONROOT) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg COSMWASM_VERSION=$(COSMWASM_VERSION) \
		--build-arg WASMVM_SOURCE=$(_WASMVM_SOURCE) \
		-f Dockerfile .

docker-build-localnet: _docker-stage
	@DOCKER_BUILDKIT=1 docker buildx build \
		--target localterp \
		--build-arg COSMWASM_VERSION=$(COSMWASM_VERSION) \
		--build-arg WASMVM_SOURCE=$(_WASMVM_SOURCE) \
		-t terpnetwork/terp-core:localterp --load .

docker-localterp: docker-build-localnet

# ---------------------------------------------------------
# Local zk-wasmvm convenience targets
#
# Auto-resolve WASMVM_LIB from ../zk-wasmvm so you can just run:
#   make build-zk-local
# ---------------------------------------------------------

# Map macOS arm64 → aarch64 to match CosmWasm lib naming convention.
_HOST_ARCH := $(shell uname -m | sed 's/arm64/aarch64/')

# Check internal/api first, then libwasmvm/artifacts as fallback.
_ZK_DEFAULT_LIB = $(firstword \
	$(wildcard $(ZK_WASMVM_DIR)/internal/api/libwasmvm_muslc.$(_HOST_ARCH).a) \
	$(wildcard $(ZK_WASMVM_DIR)/libwasmvm/artifacts/libwasmvm_muslc.$(_HOST_ARCH).a))

build-zk-local: _docker-stage-zk-lib
	@DOCKER_BUILDKIT=1 docker build \
		-t terpnetwork/terp-core:local-zk \
		--target runtime \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg RUNNER_IMAGE=$(RUNNER_BASE_IMAGE_ALPINE) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg WASMVM_SOURCE=local \
		-f Dockerfile .

build-zk-local-localnet: _docker-stage-zk-lib
	@DOCKER_BUILDKIT=1 docker buildx build \
		--target localterp \
		--build-arg WASMVM_SOURCE=local \
		-t terpnetwork/terp-core:localterp-zk --load .

# Stage the auto-resolved lib + Go source for zk builds.
_docker-stage-zk-lib:
	@if [ -z "$(_ZK_DEFAULT_LIB)" ]; then \
		echo "ERROR: libwasmvm_muslc.$(_HOST_ARCH).a not found in $(ZK_WASMVM_DIR)."; \
		echo "Build it first:  just build-wasmvm-alpine"; \
		exit 1; \
	fi
	$(MAKE) _docker-stage WASMVM_LIB=$(_ZK_DEFAULT_LIB)

# Backwards-compat aliases
docker-build-zk: build-zk-local
docker-build-zk-localnet: build-zk-local-localnet
docker-stage-zk: _docker-stage
docker-clean-zk: docker-clean
