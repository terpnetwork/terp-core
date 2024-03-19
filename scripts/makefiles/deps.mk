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