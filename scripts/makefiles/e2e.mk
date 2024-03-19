###############################################################################
###                             e2e interchain test                         ###
###############################################################################

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
	@echo "  ictest-basic						   Run basic test"
	@echo "  ictest-upgrade   				       Run basic planned upgrade test"
	@echo "  ictest-upgrade-local 				   Run basic upgrade locally after compiling a local image as terpnetwork:local"
	@echo "  ictest-statesync					   Run basic test on node statesync capabilities"
	@echo "  ictest-ibc   				           Run basic ibc test"
	@echo "  ictest-pfm					           Run basic packet-forward-middleware test"
	@echo "  ictest-ibchooks					   Run basic ibc-hooks test"
	@echo "  ictest-tokenfactory				   Run basic x/tokenfactory test"
	@echo "  ictest-feeshare   				       Run basic x/feeshare test"

e2e: e2e-help


 # Executes basic chain tests via interchaintest
ictest-basic: rm-testcache
	cd interchaintest && go test -race -v -run TestBasicTerpStart .

ictest-statesync: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpStateSync .

ictest-ibchooks: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpIBCHooks .

ictest-pfm: rm-testcache
	cd interchaintest && go test -race -v -run TestPacketForwardMiddlewareRouter .

ictest-tokenfactory: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpTokenFactory .

# ictest-clock: rm-testcache
# 	cd interchaintest &&  go test -race -v -run TestTerpClock .

ictest-feeshare: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpFeeShare . 

ictest-upgrade: rm-testcache
	cd interchaintest && go test -race -v -run TestBasicTerpUpgrade .

ictest-upgrade-local: local-image ictest-upgrade

# Executes IBC tests via interchaintest
ictest-ibc: rm-testcache
	cd interchaintest && go test -race -v -run TestTerpGaiaIBCTransfer .

rm-testcache:
	go clean -testcache

.PHONY: test-mutation ictest-basic ictest-upgrade ictest-ibc 