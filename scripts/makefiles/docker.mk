###############################################################################
###                                Docker                                  ###
###############################################################################

RUNNER_BASE_IMAGE_DISTROLESS := gcr.io/distroless/static-debian11
RUNNER_BASE_IMAGE_ALPINE := alpine:3.17
RUNNER_BASE_IMAGE_NONROOT := gcr.io/distroless/static-debian11:nonroot

# ---------------------------------------------------------------------------
# WASMVM support — platform agnostic
#
# All musl static libs are staged into build/wasmvm/ for verification
# and multi-arch Docker builds.
# ---------------------------------------------------------------------------

# Sibling repo paths (for local zk development)
ZK_WASMVM_DIR ?= ./crates/zk-wasmvm
ZK_WASMD_DIR  ?= ./crates/zk-wasmd

WASMVM_VERSION ?= $(shell grep 'CosmWasm/wasmvm' go.mod 2>/dev/null | grep -v '=>' | awk '{print $$2}')
_HOST_ARCH := $(shell uname -m | sed 's/arm64/aarch64/; s/x86_64/x86_64/')

.PHONY: docker docker-help docker-build docker-build-distroless docker-build-alpine \
	docker-build-nonroot docker-build-localnet docker-localterp docker-clean \
	build-zk-local build-zk-local-localnet _docker-stage-zk-lib \
	docker-build-zk docker-build-zk-localnet docker-stage-zk docker-clean-zk \
	_docker-stage _docker-stage-all-libs wasmvm-download-libs wasmvm-build-libs

docker-help:
	@echo "docker subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make docker-build                          	   # GitHub wasmvm (multi-lib)"
	@echo "  make docker-build WASMVM_SOURCE=local||github     # local zk-wasmvm"
	@echo ""
	@echo "Available Commands:"
	@echo "  docker-build                Build Docker image (distroless)"
	@echo "  docker-build-alpine         Build alpine Docker image"
	@echo "  docker-build-nonroot        Build nonroot Docker image"
	@echo "  docker-build-localnet       Build localterp dev image"
	@echo "  build-zk-local              Build with local ../zk-wasmvm (all libs)"
	@echo "  wasmvm-download-libs        Download official libs into build/wasmvm/"
	@echo "  wasmvm-build-libs           Build libs locally (if you have zk-wasmvm)"
	@echo "  docker-clean                Clean staged artifacts"
	@echo ""
	@echo "Current config:"
	@echo "  WASMVM_VERSION = $(WASMVM_VERSION)"
	@echo "  Build dir libs: build/wasmvm/"

docker: docker-help

# ---------------------------------------------------------
# Stage ALL wasmvm libs + zk source (platform agnostic)
# ---------------------------------------------------------

_docker-stage-all-libs:
	@echo "==> Staging all wasmvm libraries to build/wasmvm/ ..."
	@mkdir -p build/wasmvm
	# Copy any pre-existing libs from zk-wasmvm
	@find $(ZK_WASMVM_DIR) -name 'libwasmvm_muslc.*.a' -exec cp {} build/wasmvm/ \; 2>/dev/null || true
	# Also support artifacts/ dir convention
	@find $(ZK_WASMVM_DIR)/libwasmvm/artifacts -name 'libwasmvm_muslc.*.a' -exec cp {} build/wasmvm/ \; 2>/dev/null || true
	@echo "Staged libs:"
	@ls -lh build/wasmvm/ 2>/dev/null || echo "  (none)"

_docker-stage:
	$(MAKE) _docker-stage-all-libs
ifdef WASMVM_LIB
	@echo "==> Additional single lib override: $(WASMVM_LIB)"
	@cp $(WASMVM_LIB) build/wasmvm/ 2>/dev/null || true
endif
	@echo "==> Staging zk-wasmvm / zk-wasmd Go source ..."
	@mkdir -p build/zk-deps/zk-wasmvm build/zk-deps/zk-wasmd
	@rsync -a --delete \
		--exclude='target/' \
		--exclude='.git/' \
		--exclude='**/libwasmvm/target/' \
		$(ZK_WASMVM_DIR)/ build/zk-deps/zk-wasmvm/ 2>/dev/null || true
	@rsync -a --delete \
		--exclude='.git/' \
		$(ZK_WASMD_DIR)/ build/zk-deps/zk-wasmd/ 2>/dev/null || true

docker-clean:
	@echo "==> Removing staged wasmvm + zk artifacts ..."
	rm -rf build/zk-deps build/wasmvm
	@echo "Done."

# ---------------------------------------------------------
# Convenience: Download / Build libs
# ---------------------------------------------------------

wasmvm-download-libs:
	@echo "==> Downloading official wasmvm musl libs for verification..."
	@mkdir -p build/wasmvm
	@for arch in x86_64 aarch64; do \
		url="https://github.com/CosmWasm/wasmvm/releases/download/$(WASMVM_VERSION)/libwasmvm_muslc.$$arch.a"; \
		echo "  $$arch -> $$url"; \
		curl -L -f -o build/wasmvm/libwasmvm_muslc.$$arch.a $$url || echo "  Warning: Failed $$arch"; \
	done
	@ls -lh build/wasmvm/

wasmvm-build-libs:
	@echo "==> Building wasmvm libs locally (requires zk-wasmvm setup)..."
	@cd $(ZK_WASMVM_DIR) && make build-wasmvm-alpine || echo "Build command may vary"
	$(MAKE) _docker-stage-all-libs

# ---------------------------------------------------------
# Build targets — respect multi-lib staging
# ---------------------------------------------------------

docker-build: _docker-stage
	@DOCKER_BUILDKIT=1 docker build \
		-t terpnetwork/terp-core:local \
		--target runtime \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg RUNNER_IMAGE=$(RUNNER_BASE_IMAGE_DISTROLESS) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg WASMVM_VERSION=$(WASMVM_VERSION) \
		--build-arg WASMVM_SOURCE=${WASMVM_SOURCE} \
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
		--build-arg WASMVM_VERSION=$(WASMVM_VERSION) \
		--build-arg WASMVM_SOURCE=${WASMVM_SOURCE} \
		-f Dockerfile .

docker-build-nonroot: _docker-stage
	@DOCKER_BUILDKIT=1 docker build \
		-t terpnetwork/terp-core:local-nonroot \
		--target runtime \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg RUNNER_IMAGE=$(RUNNER_BASE_IMAGE_NONROOT) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg WASMVM_VERSION=$(WASMVM_VERSION) \
		--build-arg WASMVM_SOURCE=${WASMVM_SOURCE} \
		-f Dockerfile .

docker-build-localnet: _docker-stage
	@DOCKER_BUILDKIT=1 docker buildx build \
		--target localterp \
		--build-arg WASMVM_VERSION=$(WASMVM_VERSION) \
		--build-arg WASMVM_SOURCE=${WASMVM_SOURCE} \
		-t terpnetwork/terp-core:localterp --load .

docker-localterp: docker-build-localnet

# ---------------------------------------------------------
# Local zk-wasmvm targets
# ---------------------------------------------------------

build-zk-local: _docker-stage-zk-lib
	@DOCKER_BUILDKIT=1 docker build \
		-t terpnetwork/terp-core:local-zk \
		--target runtime \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg RUNNER_IMAGE=$(RUNNER_BASE_IMAGE_ALPINE) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg WASMVM_SOURCE=${WASMVM_SOURCE} \
		-f Dockerfile .

build-zk-local-localnet: _docker-stage-zk-lib
	@DOCKER_BUILDKIT=1 docker buildx build \
		--target localterp \
		--build-arg WASMVM_SOURCE=${WASMVM_SOURCE} \
		-t terpnetwork/terp-core:localterp-zk --load .

_docker-stage-zk-lib:
	@if [ ! -d "$(ZK_WASMVM_DIR)" ]; then \
		echo "ERROR: zk-wasmvm not found at $(ZK_WASMVM_DIR)"; exit 1; \
	fi
	$(MAKE) _docker-stage

# Backwards compatibility
docker-build-zk: build-zk-local
docker-build-zk-localnet: build-zk-local-localnet
docker-stage-zk: _docker-stage
docker-clean-zk: docker-clean