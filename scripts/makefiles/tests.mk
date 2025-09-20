APP = ./app
BINDIR ?= $(GOPATH)/bin

# Default test target: show help
test-help:
	@echo ""
	@echo "test subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make test-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  unit            Run unit tests"
	@echo "  race            Run tests with race detector"
	@echo "  cover           Run coverage tests"
	@echo "  node            Run node integration test"
	@echo "  sim-multi-seed-short  Run short multi-seed simulation test"
	@echo "  sim-deterministic   Run app state determinism simulation test"
	@echo "  all             Run all tests (unit, race, cover)"
	@echo ""

test: test-help

# Individual test targets
test-unit:
	@VERSION=$(VERSION) go test -mod=readonly -tags='ledger test_ledger_mock' ./...

test-race:
	@VERSION=$(VERSION) go test -mod=readonly -race ./...

test-cover:
	@go test -mod=readonly -coverprofile=coverage.txt -covermode=atomic ./...

test-node:
	CHAIN_ID="local-1" HOME_DIR="~/.terp1" TIMEOUT_COMMIT="500ms" CLEAN=true sh scripts/test_node.sh

benchmark:
	@go test -mod=readonly -bench=. ./...

test-sim-multi-seed-short: runsim
	@echo "Running short multi-seed application simulation. This may take awhile!"
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(APP) -ExitOnFail 50 5 TestFullAppSimulation

test-sim-deterministic: runsim
	@echo "Running app state determinism simulation test..."
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(APP) -ExitOnFail 1 1 TestAppStateDeterminism

test-all: test-unit test-race test-cover