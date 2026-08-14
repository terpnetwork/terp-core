###############################################################################
###                           Dependency Updates                            ###
###############################################################################
deps-help:
	@echo "Dependency Update subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make deps-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  clean                    Remove artifacts"
	@echo "  distclean                Remove vendor directory"
	@echo "  draw                     Create a dependency graph"
	@echo "  go-mod-cache             Download go modules to local cache"
	@echo "  go.sum                   Ensure dependencies have not been modified"
	@echo "  tidy-workspace           Tidy workspace"
	@echo "  update-sdk-version       Update SDK version"


go-mod-cache: go.sum
	@echo "--> Download go modules to local cache"
	@go mod download

go.sum: go.mod
	@echo "--> Ensure dependencies have not been modified"
	@go mod verify

draw-deps:
	@# requires brew install graphviz or apt-get install graphviz
	go install github.com/RobotsAndPencils/goviz@latest
	@goviz -i ./cmd/terpd -d 2 | dot -Tpng -o dependency-graph.png

deps-clean:
	rm -rf $(CURDIR)/artifacts/

deps-distclean: clean
	rm -rf vendor/

MODFILES := ./go.mod ./interchaintest/go.mod
# run with VERSION argument specified
# e.g) make update-sdk-version VERSION=v0.45.1-0.20230523200430-193959b898ec
# This will change sdk dependencyu version for go.mod in root directory + all sub-modules in this rep

deps-tidy-workspace:
	@./scripts/tidy_workspace.sh
###############################################################################
###                         Git submodules (monorepo)                       ###
###############################################################################

.PHONY: submodules-init submodules-init-go submodules-status submodules-help

# Fresh clone helper — prefer: git clone --recursive <url>
# or after shallow clone: make submodules-init
submodules-help:
	@echo "Submodule commands (monorepo)"
	@echo ""
	@echo "  make submodules-init       git submodule update --init --recursive"
	@echo "  make submodules-init-go    only crates/zk-wasmd + crates/zk-wasmvm (go.mod path replace)"
	@echo "  make submodules-status     git submodule status"
	@echo ""
	@echo "Fresh checkout:"
	@echo "  git clone --recursive <repo-url>"
	@echo "  # or: git submodule update --init --recursive"

submodules-init:
	@echo "--> Initializing all git submodules (recursive)"
	git submodule update --init --recursive

# Minimal set required for go build/test with monorepo path replaces in go.mod
submodules-init-go:
	@echo "--> Initializing Go path-replace submodules (zk-wasmd, zk-wasmvm)"
	git submodule update --init --depth 1 crates/zk-wasmd crates/zk-wasmvm

submodules-status:
	git submodule status
