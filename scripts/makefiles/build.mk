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
	@echo "  all                              Build all targets"
	@echo "  check-version                    Check Go version"
	@echo "  dev-build                        Build development version"
	@echo "  dev-install                      Install development build"
	@echo "  linux                            Build for Linux"
	@echo "  windows                          Build for Windows"
	@echo "  reproducible                     Build reproducible binaries"
	@echo "  reproducible-amd64               Build reproducible amd64 binary"
	@echo "  reproducible-arm64               Build reproducible arm64 binary"

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

all: install
	@echo "--> project root: go mod tidy"	
	@go mod tidy	
	@echo "--> project root: linting --fix"	
	@GOGC=1 golangci-lint run --fix --timeout=8m

install: go.sum
	go install -mod=readonly $(BUILD_FLAGS) ./cmd/terpd

build: go.sum
ifeq ($(OS),Windows_NT)
	$(error terpd server not supported. Use "make build-windows" for client)
	exit 1
else
	go build -mod=readonly $(BUILD_FLAGS) -o build/terpd ./cmd/terpd
endif

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

build-reproducible: build-reproducible-amd64 build-reproducible-arm64

build-reproducible-amd64: go.sum
	mkdir -p $(BUILDDIR)
	$(DOCKER) buildx create --name terpbuilder || true
	$(DOCKER) buildx use terpbuilder
	$(DOCKER) buildx build \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg RUNNER_IMAGE=alpine:3.17 \
		--platform linux/amd64 \
		-t terp-core:local-amd64 \
		--load \
		-f Dockerfile .
	$(DOCKER) rm -f terpbinary || true
	$(DOCKER) create -ti --name terpbinary terpn-core:local-amd64
	$(DOCKER) cp terpbinary:/bin/terpd $(BUILDDIR)/terpd-linux-amd64
	$(DOCKER) rm -f terpbinary

build-reproducible-arm64: go.sum
	mkdir -p $(BUILDDIR)
	$(DOCKER) buildx create --name terpbuilder || true
	$(DOCKER) buildx use terpbuilder
	$(DOCKER) buildx build \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg GIT_VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(COMMIT) \
		--build-arg RUNNER_IMAGE=alpine:3.17 \
		--platform linux/arm64 \
		-t terp-core:local-arm64 \
		--load \
		-f Dockerfile .
	$(DOCKER) rm -f terpbinary || true
	$(DOCKER) create -ti --name terpbinary terp-core:local-arm64
	$(DOCKER) cp osmobinary:/bin/terpd $(BUILDDIR)/terpd-linux-arm64
	$(DOCKER) rm -f terpbinary

build-linux: go.sum
	LEDGER_ENABLED=false GOOS=linux GOARCH=amd64 $(MAKE) build


# build-install-with-autocomplete: build-check-version go.sum
# 	GOWORK=off go install -mod=readonly $(BUILD_FLAGS) $(GO_MODULE)/cmd/terpd
# 	@PARENT_SHELL=$$(ps -o ppid= -p $$PPID | xargs ps -o comm= -p); \
# 	if echo "$$PARENT_SHELL" | grep -q "zsh"; then \
# 		if ! grep -q ". <(terpd enable-cli-autocomplete zsh)" ~/.zshrc; then \
# 			echo ". <(terpd enable-cli-autocomplete zsh)" >> ~/.zshrc; \
# 			echo; \
# 			echo "Autocomplete enabled. Run 'source ~/.zshrc' to complete installation."; \
# 		else \
# 			echo; \
# 			echo "Autocomplete already enabled in ~/.zshrc"; \
# 		fi \
# 	elif echo "$$PARENT_SHELL" | grep -q "bash" && [ "$$(uname)" = "Darwin" ]; then \
# 		if ! grep -q -e "\. <(terpd enable-cli-autocomplete bash)" -e '\[\[ -r "/opt/homebrew/etc/profile.d/bash_completion.sh" \]\] && \. "/opt/homebrew/etc/profile.d/bash_completion.sh"' ~/.bash_profile; then \
# 			brew install bash-completion; \
# 			echo '[ -r "/opt/homebrew/etc/profile.d/bash_completion.sh" ] && . "/opt/homebrew/etc/profile.d/bash_completion.sh"' >> ~/.bash_profile; \
# 			echo ". <(terpd enable-cli-autocomplete bash)" >> ~/.bash_profile; \
# 			echo; \
# 			echo; \
# 			echo "Autocomplete enabled. Run 'source ~/.bash_profile' to complete installation."; \
# 		else \
# 			echo "Autocomplete already enabled in ~/.bash_profile"; \
# 		fi \
# 	elif echo "$$PARENT_SHELL" | grep -q "bash" && [ "$$(uname)" = "Linux" ]; then \
# 		if ! grep -q ". <(terpd enable-cli-autocomplete bash)" ~/.bash_profile; then \
# 			sudo apt-get install -y bash-completion; \
# 			echo '[ -r "/etc/bash_completion" ] && . "/etc/bash_completion"' >> ~/.bash_profile; \
# 			echo ". <(terpd enable-cli-autocomplete bash)" >> ~/.bash_profile; \
# 			echo; \
# 			echo "Autocomplete enabled. Run 'source ~/.bash_profile' to complete installation."; \
# 		else \
# 			echo; \
# 			echo "Autocomplete already enabled in ~/.bash_profile"; \
# 		fi \
# 	else \
# 		echo "Shell or OS not recognized. Skipping autocomplete setup."; \
# 	fi