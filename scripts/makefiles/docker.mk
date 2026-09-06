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
	_docker-stage _docker-stage-all-libs wasmvm-download-libs wasmvm-build-libs \
	docker-publish-dev docker-push-dev

# Canonical image: $(IMAGE_REPO):$(TERP_IMAGE_VERSION)
# TERP_IMAGE_VERSION is required for build/e2e. No registry tag named local / local-zk.
RELEASE_TAG ?= v5.3.0-dev
IMAGE_REPO ?= registry.terp.network/terp-core
TERP_IMAGE_VERSION ?=
export IMAGE_REPO
export TERP_IMAGE_VERSION
export TERP_IMAGE_REPO ?= $(IMAGE_REPO)
export ICT_IMAGE_REPO = $(IMAGE_REPO)
export ICT_IMAGE_VERSION = $(TERP_IMAGE_VERSION)

define require_image_version
	@if [ -z "$(TERP_IMAGE_VERSION)" ] || [ "$(TERP_IMAGE_VERSION)" = "local" ] || [ "$(TERP_IMAGE_VERSION)" = "local-zk" ]; then \
	  echo "ERROR: set TERP_IMAGE_VERSION to a real tag (git sha, v6.1.0-dev, …). local / local-zk are retired."; \
	  exit 1; \
	fi
endef

docker-help:
	@echo "docker subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make docker-build                          	   # GitHub wasmvm (multi-lib)"
	@echo "  make docker-build WASMVM_SOURCE=local||github     # local zk-wasmvm"
	@echo "  make docker-publish-dev RELEASE_TAG=v5.3.0-dev    # ZK build + version tags"
	@echo "  make docker-push-dev RELEASE_TAG=v5.3.0-dev       # push to IMAGE_REPO"
	@echo ""
	@echo "Available Commands:"
	@echo "  docker-build                Build Docker image (distroless)"
	@echo "  docker-build-alpine         Build alpine Docker image"
	@echo "  docker-build-nonroot        Build nonroot Docker image"
	@echo "  docker-build-localnet       Build localterp dev image"
	@echo "  build-zk-local              Build with local ../zk-wasmvm (all libs)"
	@echo "  docker-publish-dev          ZK build + tag as RELEASE_TAG + local-zk + ghcr name"
	@echo "  docker-push-dev             docker push IMAGE_REPO:RELEASE_TAG"
	@echo "  wasmvm-download-libs        Download official libs into build/wasmvm/"
	@echo "  wasmvm-build-libs           Build libs locally (if you have zk-wasmvm)"
	@echo "  docker-clean                Clean staged artifacts"
	@echo ""
	@echo "Current config:"
	@echo "  WASMVM_VERSION = $(WASMVM_VERSION)"
	@echo "  RELEASE_TAG    = $(RELEASE_TAG)"
	@echo "  IMAGE_REPO          = $(IMAGE_REPO)"
	@echo "  TERP_IMAGE_VERSION  = $(TERP_IMAGE_VERSION)"
	@echo "  Build dir libs: build/wasmvm/"

docker: docker-help

# ---------------------------------------------------------
# Stage ALL wasmvm libs + zk source (platform agnostic)
# ---------------------------------------------------------

_docker-stage-all-libs:
	@echo "==> Staging wasmvm muslc from zk-wasmvm internal/api (cgo SRCDIR) ..."
	@mkdir -p build/wasmvm
	@rm -f build/wasmvm/libwasmvm_muslc.*.a
	@src="$(ZK_WASMVM_DIR)/internal/api"; \
	if [ ! -d "$$src" ]; then echo "ERROR: missing $$src"; exit 1; fi; \
	host="$$(uname -m | sed 's/arm64/aarch64/')"; \
	n=0; \
	for arch in aarch64 x86_64; do \
	  srcf="$$src/libwasmvm_muslc.$$arch.a"; \
	  [ -f "$$srcf" ] || continue; \
	  if ! grep -a -q -F verify_stwo_host_proof "$$srcf"; then \
	    echo "ERROR: $$srcf has no verify_stwo_host_proof (host cgo waist of Path A / proof-instance-verify). Do not copy artifacts/. Rebuild that arch with nightly STWO muslc."; \
	    if [ "$$arch" = "$$host" ]; then exit 1; fi; \
	    echo "not staging $$arch (not host $$host); e2e uses this host image, not a second guest FFI"; \
	    continue; \
	  fi; \
	  cp -f "$$srcf" build/wasmvm/; \
	  n=$$((n+1)); \
	  echo "ok STWO libwasmvm_muslc.$$arch.a $$(ls -lh $$srcf | awk '{print $$5}')"; \
	done; \
	if [ "$$n" = 0 ]; then echo "ERROR: no STWO muslc in $$src for this host"; exit 1; fi; \
	if [ ! -f "build/wasmvm/libwasmvm_muslc.$$host.a" ]; then echo "ERROR: host muslc libwasmvm_muslc.$$host.a missing STWO"; exit 1; fi
	@echo "Staged libs:"
	@ls -lh build/wasmvm/

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
		--exclude='**/target/' \
		--exclude='.git/' \
		--exclude='artifacts/' \
		--exclude='testdata/' \
		--exclude='builders/' \
		--exclude='libwasmvm/target/' \
		--exclude='internal/api/*.a' \
		$(ZK_WASMVM_DIR)/ build/zk-deps/zk-wasmvm/ 2>/dev/null || true
	@rsync -a --delete \
		--exclude='.git/' \
		$(ZK_WASMD_DIR)/ build/zk-deps/zk-wasmd/ 2>/dev/null || true
	@echo "==> Staging ibc-hooks-v11 (store/v2 keeper patch) ..."
	@mkdir -p build/zk-deps/ibc-hooks-v11
	@rsync -a --delete --exclude='.git/' \
		./crates/ibc-hooks-v11/ build/zk-deps/ibc-hooks-v11/ 2>/dev/null || true

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
	$(require_image_version)
	@DOCKER_BUILDKIT=1 docker build \
		-t $(IMAGE_REPO):$(TERP_IMAGE_VERSION) \
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
	$(require_image_version)
	@DOCKER_BUILDKIT=1 docker build \
		-t $(IMAGE_REPO):$(TERP_IMAGE_VERSION) \
		--target runtime \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg RUNNER_IMAGE=$(RUNNER_BASE_IMAGE_ALPINE) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg WASMVM_SOURCE=${WASMVM_SOURCE} \
		-f Dockerfile .

.PHONY: docker-ensure-image
docker-ensure-image:
	$(require_image_version)
	@IMAGE_REPO=$(IMAGE_REPO) TERP_IMAGE_VERSION=$(TERP_IMAGE_VERSION) BUILD=$(or $(BUILD),0) PUSH=$(or $(PUSH),0) \
		./scripts/release/ensure_registry_terp_image.sh $(or $(TAG),$(TERP_IMAGE_VERSION))

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

# ---------------------------------------------------------
# Version-aligned ZK publish (testnet lineage, e.g. v5.3.0-dev)
# ---------------------------------------------------------

# Build (or SKIP_BUILD=1 retag) as IMAGE_REPO:RELEASE_TAG. No local-zk alias.
docker-publish-dev:
	@RELEASE_TAG=$(RELEASE_TAG) IMAGE_REPO=$(IMAGE_REPO) TERP_IMAGE_VERSION=$(RELEASE_TAG) \
		WASMVM_SOURCE=local SKIP_BUILD=$(or $(SKIP_BUILD),0) \
		./scripts/release/publish_docker_dev.sh

# Push the versioned image to the registry (requires docker login).
docker-push-dev:
	@echo "==> Pushing $(IMAGE_REPO):$(RELEASE_TAG)"
	@docker push $(IMAGE_REPO):$(RELEASE_TAG)
	@echo "Pushed $(IMAGE_REPO):$(RELEASE_TAG)"
	@docker image inspect $(IMAGE_REPO):$(RELEASE_TAG) --format 'RepoDigests={{json .RepoDigests}}' || true