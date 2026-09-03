###############################################################################
###                             e2e (ict-rs binaries)                       ###
# tests/interchaintest is the rust crate of e2e bins (old Go package removed).
# CI: .github/workflows/interchaintest-E2E.yml (ict-ci mock + docker suites).
###############################################################################
E2E_MANIFEST := tests/interchaintest/Cargo.toml
E2E_RUN = cargo run --manifest-path $(E2E_MANIFEST)

e2e-help:
	@echo "e2e (tests/interchaintest rust bins + ict-rs)"
	@echo "  make e2e-basic              TestBasicTerpStart (mock)"
	@echo "  make e2e-tokenfactory       TestTerpTokenFactory (mock)"
	@echo "  make e2e-feeshare           TestTerpFeeShare (mock)"
	@echo "  make e2e-drip               TestTerpDrip (mock)"
	@echo "  make e2e-clock              TestTerpClock (mock)"
	@echo "  make e2e-circuit-deposit    circuit runway pay/query (mock)"
	@echo "  make e2e-circuit-runway     3-val epoch settle (ICT_MOCK=1 smoke; omit for Docker local-zk)"
	@echo "  make e2e-ibc                TestTerpGaiaIBCTransfer (docker)"
	@echo "  make e2e-ibchooks           TestTerpIBCHooks"
	@echo "  make e2e-pfm                TestPacketForwardMiddlewareRouter"
	@echo "  make e2e-polytone           TestPolytoneOnTerp (docker)"
	@echo "  make e2e-statesync          TestTerpStateSync (docker)"
	@echo "  make e2e-upgrade            TestBasicTerpUpgrade (docker; ICT_UPGRADE_NAME=v6.1 for IAVL dual-store)"
	@echo "  make e2e-zk                 TestTerpZkCosmwasmVm (docker)"
	@echo "  make e2e-ict-rs-build       Compile ict-ci + CI examples"

e2e: e2e-help

e2e-basic:
	ICT_MOCK=1 $(E2E_RUN) --bin basic

e2e-tokenfactory:
	ICT_MOCK=1 $(E2E_RUN) --bin tokenfactory

e2e-feeshare:
	ICT_MOCK=1 $(E2E_RUN) --bin feeshare

e2e-drip:
	ICT_MOCK=1 $(E2E_RUN) --bin drip

e2e-clock:
	ICT_MOCK=1 $(E2E_RUN) --bin clock

e2e-circuit-deposit:
	ICT_MOCK=1 $(E2E_RUN) --bin circuit_deposit

e2e-circuit-runway:
	@echo "==> mock: ICT_MOCK=1  docker: make build-zk-local && make e2e-circuit-runway-docker"
	ICT_MOCK=1 $(E2E_RUN) --bin circuit_runway_epoch

e2e-circuit-runway-docker:
	$(E2E_RUN) --bin circuit_runway_epoch

# Mock-only local gate (no Docker). Docker suites need terpnetwork/terp-core:local-zk.
e2e-all-mock: e2e-basic e2e-tokenfactory e2e-feeshare e2e-drip e2e-clock e2e-circuit-deposit e2e-circuit-runway

e2e-ibc:
	$(E2E_RUN) --bin ibc

e2e-ibchooks:
	$(E2E_RUN) --bin ibchooks

e2e-pfm:
	$(E2E_RUN) --bin pfm

e2e-polytone:
	$(E2E_RUN) --bin polytone

e2e-statesync:
	$(E2E_RUN) --bin statesync

e2e-upgrade:
	$(E2E_RUN) --bin upgrade

e2e-zk:
	$(E2E_RUN) --bin zk

e2e-ict-rs-build:
	bash scripts/ci/ict-rs-submodules.sh
	cd crates/ict-rs && just ci-build

e2e-ict-rs-pack:
	cd crates/ict-rs && just ci-pack

e2e-ict-rs-docker:
	cd crates/ict-rs && just ci-build-docker

e2e-ict-rs-from-tarball:
	bash scripts/ci/run-e2e-from-tarball.sh $(TARBALL) $(SUITE)

.PHONY: e2e e2e-help e2e-basic e2e-tokenfactory e2e-feeshare e2e-drip e2e-clock e2e-circuit-deposit \
	e2e-circuit-runway e2e-circuit-runway-docker e2e-all-mock \
	e2e-ibc e2e-ibchooks e2e-pfm e2e-polytone e2e-statesync e2e-upgrade e2e-zk \
	e2e-ict-rs-build e2e-ict-rs-pack e2e-ict-rs-docker e2e-ict-rs-from-tarball
