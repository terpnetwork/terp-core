###############################################################################
###                             e2e (ict-rs binaries)                       ###
# tests/interchaintest is the rust crate of e2e bins (old Go package removed).
# CI: .github/workflows/interchaintest-E2E.yml (ict-ci mock + docker suites).
#
# MAINNET SAFETY: no target here may touch morocco-1 / mainnet. Docker suites
# spin ephemeral local chains (120u-1, circuit-epoch-1); image ensures run
# with PUSH=0 / BUILD=0 (read-only pulls). Known live-capable files that must
# NEVER be wired here: crates/ict-rs/examples/bootstrap_mainnet.rs
# (state-syncs morocco-1), crates/terp-rs/tests/bin/polytone_migrate.rs and
# ibc_info.rs (accept morocco-1). Mock targets run ICT_MOCK=1 only.
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
	@echo "  make e2e-all-mock-extended  all mock: bins + ict-rs + terp-rs"
	@echo "  make e2e-all-docker         all docker suites (one image ensure)"
	@echo "  make e2e-all                everything: mock-extended then docker"
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
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin circuit_runway_epoch

# Mock-only gate (no Docker). Docker suites need TERP_IMAGE_VERSION set.
e2e-all-mock: e2e-basic e2e-tokenfactory e2e-feeshare e2e-drip e2e-clock e2e-circuit-deposit e2e-circuit-runway

e2e-ibc:
ifeq ($(ICT_MOCK),1)
	ICT_MOCK=1 $(E2E_RUN) --bin ibc
else
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin ibc
endif

e2e-ibchooks:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin ibchooks

e2e-pfm:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin pfm

e2e-polytone:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin polytone

e2e-statesync:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin statesync

e2e-upgrade:
	@$(MAKE) docker-ensure-image PUSH=0
	@IMAGE_REPO=$(or $(IMAGE_REPO),registry.terp.network/terp-core) TERP_IMAGE_VERSION=$(or $(ICT_UPGRADE_FROM),v5.2.0) BUILD=0 PUSH=0 \
		./scripts/release/ensure_registry_terp_image.sh $(or $(ICT_UPGRADE_FROM),v5.2.0)
	$(E2E_RUN) --bin upgrade

e2e-zk:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin zk

# Full docker sweep — one image ensure, then every docker-backed suite.
# Upgrade uses ICT_UPGRADE_* env (defaults below); override per release.
e2e-all-docker:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin ibc
	$(E2E_RUN) --bin ibchooks
	$(E2E_RUN) --bin pfm
	$(E2E_RUN) --bin polytone
	$(E2E_RUN) --bin statesync
	$(E2E_RUN) --bin zk
	$(E2E_RUN) --bin circuit_runway_epoch
	$(E2E_RUN) --bin circuit_deposit
	@$(MAKE) e2e-upgrade

# ict-rs Rust suites (crates/ict-rs/justfile). Mock needs no Docker.
e2e-ict-rs-mock:
	cd crates/ict-rs && just test

e2e-ict-rs-unit:
	cd crates/ict-rs && just test-unit

e2e-ict-rs-test-docker:
	cd crates/ict-rs && just test-docker

# terp-rs suites (crates/terp-rs/tests, pkg terp-scripts).
# Offline-safe subset only — *_live / testnet / zakura need mainnet env.
e2e-terp-rs-mock:
	cd crates/terp-rs/tests && cargo test -p terp-scripts --test ibc_unit --test ibc_golden --test hashmerchant_planes --test vsck_vote_sdk --test nostr_orch_suite

e2e-all-mock-extended: e2e-all-mock e2e-ict-rs-mock e2e-terp-rs-mock

# Everything: all mock suites (interchaintest + ict-rs + terp-rs) then all
# docker suites. Requires TERP_IMAGE_VERSION set; docker pulls are read-only.
e2e-all: e2e-all-mock-extended e2e-all-docker

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
	e2e-all-docker e2e-ict-rs-mock e2e-ict-rs-unit e2e-ict-rs-test-docker \
	e2e-terp-rs-mock e2e-all-mock-extended e2e-all \
	e2e-ict-rs-build e2e-ict-rs-pack e2e-ict-rs-docker e2e-ict-rs-from-tarball
