###############################################################################
###                            Build & Install                              ###
###############################################################################
build-help:
	@echo "build subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make build-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  build-check-version                    Check Go version"
	@echo "  build                        Build development version"
	@echo "  install                      Install development build"
	@echo "  build-linux                            Build for Linux"
	@echo "  build-reproducible                     Build reproducible binaries"
	@echo "  build-reproducible-amd64               Build reproducible amd64 binary"
	@echo "  build-reproducible-arm64               Build reproducible arm64 binary"

build-check-version:
	@echo "Go version: $(GO_MAJOR_VERSION).$(GO_MINOR_VERSION)"
	@if [ $(GO_MAJOR_VERSION) -gt $(GO_MINIMUM_MAJOR_VERSION) ]; then \
		echo "Go version is sufficient"; \
		exit 0; \
	elif [ $(GO_MAJOR_VERSION) -lt $(GO_MINIMUM_MAJOR_VERSION) ]; then \
		echo '$(GO_VERSION_ERR_MSG)'; \
		exit 1; \
	elif [ $(GO_MINOR_VERSION) -lt $(GO_MINIMUM_MINOR_VERSION) ]; then \
		echo '$(GO_VERSION_ERR_MSG)'; \
		exit 1; \
	fi

install: build-check-version go.sum
	go install -mod=readonly $(BUILD_FLAGS) ./cmd/terpd

build-linux: go.sum
	LEDGER_ENABLED=false GOOS=linux GOARCH=amd64 $(MAKE) build

build-windows: go.sum
	GOOS=windows GOARCH=amd64 go build -mod=readonly $(BUILD_FLAGS) -o build/terpd.exe ./cmd/terpd

build-dev-install: go.sum
	GOWORK=off go install $(DEBUG_BUILD_FLAGS) $(GC_FLAGS) $(GO_MODULE)/cmd/terpd

build-dev-build:
	mkdir -p $(BUILDDIR)/
	GOWORK=off go build $(GC_FLAGS) -mod=readonly -ldflags '$(DEBUG_LDFLAGS)' -gcflags "all=-N -l" -trimpath -o $(BUILDDIR) ./...;

# Cross-building for arm64 from amd64 (or vice-versa) takes
# a lot of time due to QEMU virtualization but it's the only way (afaik)
# to get a statically linked binary with CosmWasm
# ZK branch default. Stock CosmWasm muslc: WASMVM_SOURCE=github
WASMVM_SOURCE ?= local
WASMVM_VERSION ?= $(shell grep 'CosmWasm/wasmvm' go.mod 2>/dev/null | grep -v '=>' | awk '{print $$2}')

define extract_binary
	$(DOCKER) rm -f terpbinary 2>/dev/null || true
	$(DOCKER) create -ti --name terpbinary $(1)
	$(DOCKER) cp terpbinary:/usr/local/bin/terpd $(2)
	$(DOCKER) rm -f terpbinary
endef

build-reproducible: build-reproducible-amd64 build-reproducible-arm64

build-reproducible-amd64: go.sum
	@if [ "$(WASMVM_SOURCE)" = "local" ]; then $(MAKE) _docker-stage; fi
	mkdir -p $(BUILDDIR)
	$(DOCKER) buildx create --name terpbuilder || true
	$(DOCKER) buildx use terpbuilder

	$(DOCKER) buildx build \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg WASMVM_VERSION=$(WASMVM_VERSION) \
		--build-arg WASMVM_SOURCE=$(WASMVM_SOURCE) \
		--build-arg RUNNER_IMAGE=alpine:3.17 \
		--platform linux/amd64 \
		--target runtime \
		-t terp-core:local-amd64 \
		--load \
		-f Dockerfile .

	$(call extract_binary,terp-core:local-amd64,$(BUILDDIR)/terpd-linux-amd64)

build-reproducible-arm64: go.sum
	@if [ "$(WASMVM_SOURCE)" = "local" ]; then $(MAKE) _docker-stage; fi
	mkdir -p $(BUILDDIR)
	$(DOCKER) buildx create --name terpbuilder || true
	$(DOCKER) buildx use terpbuilder
	$(DOCKER) buildx build \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg WASMVM_VERSION=$(WASMVM_VERSION) \
		--build-arg WASMVM_SOURCE=$(WASMVM_SOURCE) \
		--build-arg RUNNER_IMAGE=alpine:3.17 \
		--platform linux/arm64 \
		--target runtime \
		-t terp-core:local-arm64 \
		--load \
		-f Dockerfile .
	$(call extract_binary,terp-core:local-arm64,$(BUILDDIR)/terpd-linux-arm64)
