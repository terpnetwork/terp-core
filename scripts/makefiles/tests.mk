###############################################################################
###                                Testing                                  ###
###############################################################################

APP = ./app
BINDIR ?= $(GOPATH)/bin

 
test: test-unit
test-all: check test-race test-cover

test-node:
	CHAIN_ID="local-1" HOME_DIR="~/.terp1" TIMEOUT_COMMIT="500ms" CLEAN=true sh scripts/test_node.sh

test-unit:
	@VERSION=$(VERSION) go test -mod=readonly -tags='ledger test_ledger_mock' ./...

benchmark:
	@go test -mod=readonly -bench=. ./...

test-sim-multi-seed-short: runsim
	@echo "Running short multi-seed application simulation. This may take awhile!"
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(APP) -ExitOnFail 50 5 TestFullAppSimulation

test-sim-deterministic: runsim
	@echo "Running short multi-seed application simulation. This may take awhile!"
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(APP) -ExitOnFail 1 1 TestAppStateDeterminism