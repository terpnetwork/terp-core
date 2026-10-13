###############################################################################
###                             e2e (ict-rs binaries)                       ###
# tests/interchaintest is the rust crate of e2e bins (old Go package removed).
# `make e2e-ict -- EXAMPLE=ibc_hooks` forwards to crates/ict-rs.
# CI: .github/workflows/interchaintest-E2E.yml (ict-ci docker suites).
#
# MAINNET SAFETY: no target here may touch morocco-1 / mainnet. Docker suites
# spin ephemeral local chains (120u-1, circuit-epoch-1); image ensures run
# with PUSH=0 / BUILD=0 (read-only pulls). Known live-capable files that must
# NEVER be wired here: crates/ict-rs/examples/bootstrap_mainnet.rs
# (state-syncs morocco-1), crates/terp-rs/tests/bin/polytone_migrate.rs and
# ibc_info.rs (accept morocco-1). Suites use TERP_IMAGE_REPO and TERP_IMAGE_VERSION.
###############################################################################
E2E_MANIFEST := tests/interchaintest/Cargo.toml
E2E_RUN = cargo run --manifest-path $(E2E_MANIFEST)

e2e-help:
	@echo "e2e (tests/interchaintest rust bins + ict-rs)"
	@echo "  make e2e-basic              TestBasicTerpStart (terp image)"
	@echo "  make e2e-tokenfactory       TestTerpTokenFactory (terp image)"
	@echo "  make e2e-feeshare           TestTerpFeeShare (terp image)"
	@echo "  make e2e-drip               TestTerpDrip (terp image)"
	@echo "  make e2e-clock              TestTerpClock (terp image)"
	@echo "  make e2e-circuit-deposit    circuit deposit pay/query (terp image)"
	@echo "  make e2e-circuit-runway     3-val epoch settle on TERP_IMAGE_REPO:TERP_IMAGE_VERSION"
	@echo "  make e2e-ibc                TestTerpGaiaIBCTransfer (docker)"
	@echo "  make e2e-ibchooks           TestTerpIBCHooks"
	@echo "  make e2e-pfm                TestPacketForwardMiddlewareRouter"
	@echo "  make e2e-polytone           TestPolytoneOnTerp (docker)"
	@echo "  make e2e-statesync          TestTerpStateSync (docker)"
	@echo "  make e2e-upgrade            TestBasicTerpUpgrade (docker; ICT_UPGRADE_NAME=v6.1 for IAVL dual-store)"
	@echo "  make e2e-zk                 TestTerpZkCosmwasmVm (docker)"
	@echo "  make e2e-all-mock-extended  single-chain image suites, then ict-rs and terp-rs"
	@echo "  make e2e-all-docker         all docker suites (one image ensure)"
	@echo "  make e2e-all                everything: mock-extended then docker"
	@echo "  make e2e-ict-rs-build       Compile ict-ci + CI examples"
	@echo "  make e2e-ict EXAMPLE=name  Shim: cargo run -p ict-rs --example \$$EXAMPLE"
	@echo "  make e2e-page               Serve tests/e2e at http://127.0.0.1:8765"

e2e: e2e-help

e2e-basic:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin basic

e2e-tokenfactory:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin tokenfactory

e2e-feeshare:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin feeshare

e2e-drip:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin drip

e2e-clock:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin clock

e2e-circuit-deposit:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin circuit_deposit

e2e-circuit-runway:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin circuit_runway_epoch

e2e-circuit-runway-docker:
	@$(MAKE) docker-ensure-image PUSH=0
	$(E2E_RUN) --bin circuit_runway_epoch

# Single-chain image gate. Needs TERP_IMAGE_VERSION.
e2e-all-mock: e2e-basic e2e-tokenfactory e2e-feeshare e2e-drip e2e-clock e2e-circuit-deposit e2e-circuit-runway

e2e-ict:
	$(E2E_RUN) --bin ict -- $(EXAMPLE)

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

# Catalog page lives in tests/e2e. Foreground; Ctrl-C stops it.
e2e-page:
	python3 scripts/e2e/serve.py

.PHONY: e2e e2e-help e2e-basic e2e-tokenfactory e2e-feeshare e2e-drip e2e-clock e2e-circuit-deposit \
	e2e-circuit-runway e2e-circuit-runway-docker e2e-all-mock \
	e2e-ibc e2e-ibchooks e2e-pfm e2e-polytone e2e-statesync e2e-upgrade e2e-zk \
	e2e-all-docker e2e-ict-rs-mock e2e-ict-rs-unit e2e-ict-rs-test-docker \
	e2e-terp-rs-mock e2e-all-mock-extended e2e-all \
	e2e-ict-rs-build e2e-ict-rs-pack e2e-ict-rs-docker e2e-ict-rs-from-tarball e2e-page e2e-ict
