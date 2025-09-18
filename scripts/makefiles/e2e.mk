###############################################################################
###                             e2e interchain test                         ###
###############################################################################
E2E_UPGRADE_VERSION := "v4"
e2e-help:
	@echo "e2e subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make e2e-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  build-script                          Build e2e script"
	@echo "  check-image-sha                       Check e2e image SHA"
	@echo "  docker-build-debug                    Build e2e debug Docker image"
	@echo "  docker-build-e2e-init-chain           Build e2e init chain Docker image"
	@echo "  docker-build-e2e-init-node            Build e2e init node Docker image"
	@echo "  remove-resources                      Remove e2e resources"
	@echo "  setup                                 Set up e2e environment"
	@echo "  basic						           Run basic test"
	@echo "  upgrade   				       Run basic planned upgrade test"
	@echo "  upgrade-local 				   Run basic upgrade locally after compiling a local image as terpnetwork/terp-core:local"
	@echo "  statesync					   Run basic test on node statesync capabilities"
	@echo "  ibc   				           Run basic ibc test"
	@echo "  pfm					           Run basic packet-forward-middleware test"
	@echo "  ibchooks					   Run basic ibc-hooks test"
	@echo "  tokenfactory				   Run basic x/tokenfactory test"
	@echo "  feeshare   				       Run basic x/feeshare test"

e2e: e2e-help


 # Executes basic chain tests via interchaintest
e2e-basic: rm-testcache
	cd interchaintest && go test -race -v -run TestBasicTerpStart .

e2e-statesync: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpStateSync .

e2e-ibchooks: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpIBCHooks .

e2e-pfm: rm-testcache
	cd interchaintest && go test -race -v -run TestPacketForwardMiddlewareRouter .

e2e-tokenfactory: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpTokenFactory .

e2e-clock: rm-testcache
	cd interchaintest &&  go test -race -v -run TestTerpClock .

e2e-feeshare: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpFeeShare . 

e2e-upgrade: rm-testcache
	cd interchaintest && go test -race -v -run TestBasicTerpUpgrade .

e2e-upgrade-local: local-image ictest-upgrade

# Executes IBC tests via interchaintest
e2e-ibc: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpGaiaIBCTransfer .

rm-testcache:
	go clean -testcache

.PHONY: test-mutation ictest-basic ictest-upgrade ictest-ibc 