###############################################################################
###                                Release                                  ###
###############################################################################

GORELEASER_IMAGE := ghcr.io/goreleaser/goreleaser-cross:v$(GO_VERSION)
WASMVM_VERSION=$(go list -m github.com/CosmWasm/wasmvm/v3 | awk '{print $2}')

.PHONY: release release-help release-publish release-dry-run release-snapshot \
	create-binaries create-checksums release-prep create-binaries-json \
	create-upgrade-guide release-proposal upgrade-proposal \
	release-bundle release-s3 release-dev release-control \
	sync-upgrade-pack verify-upgrade-pack test-upgrade-pack recurate-upgrade-binaries \
	sync-chain-registry

# Shared with docker.mk for version-aligned testnet/ZK releases
RELEASE_TAG ?= v6.0.0-dev
# S3 releases bucket folder = project/repo name (see scripts/release/S3-LAYOUT.md)
PROJECT ?= terp-core
NETWORK ?= testnet
CHAIN_ID ?= 120u-1
MINIO_ALIAS ?= usb2
S3_BUCKET ?= releases
DRY_RUN ?= 0
PUBLISH_LATEST ?= 0

release-help:
	@echo "release subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make release-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  release                  Full end-to-end release pipeline"
	@echo "  release-help             Print this help message"
	@echo "  release-publish          Goreleaser release to GitHub (requires GITHUB_TOKEN)"
	@echo "  release-dry-run          Goreleaser dry run (no publish)"
	@echo "  release-snapshot         Goreleaser snapshot build"
	@echo "  create-binaries          Build reproducible binaries (linux amd64+arm64)"
	@echo "  create-checksums         Generate build/sha256sum.txt for raw binaries only"
	@echo "  release-prep             Create tarballs + unified sha256sum.txt (binaries + tarballs)"
	@echo "  create-binaries-json     Generate cosmovisor-compatible binaries JSON"
	@echo "  verify-artifacts         Fetch S3 pack, checksum, load image, ict/tsh"
	@echo "  create-upgrade-guide     Generate upgrade guide (rolling or coordinated)"
	@echo "  release-proposal         Dry-run v6 gov proposal via cw-orch (scripts/release/.env)"
	@echo "  upgrade-proposal         Same as release-proposal; add BROADCAST=1 to submit"
	@echo ""
	@echo "Testnet ZK / S3 verifiable distribution (see scripts/release/README.md, S3-LAYOUT.md):"
	@echo "  release-bundle           Deterministic source.tar.gz + manifest.json"
	@echo "  release-s3               Upload to releases/\$$PROJECT/\$$TAG/ (MINIO_ALIAS=$(MINIO_ALIAS))"
	@echo "  wasmvm-curate            Pack libwasmvm artifacts + SHA256SUMS + VERSIONS.txt"
	@echo "  preflight-upgrade       Gate Cosmovisor plan + local tarballs + ZK muslc (no upload)"
	@echo "  sync-upgrade-pack       Rewrite pack JSON/SOURCE_DEPS from ARTIFACT_LOCK (WRITE=1 from tarballs)"
	@echo "  verify-upgrade-pack     Fail-closed: binaries.json == cosmovisor.json == proposal == lock"
	@echo "  test-upgrade-pack       Drift regression (corrupt binaries.json must fail verify)"
	@echo "  recurate-upgrade-binaries  Rebuild tagged ELF and compare ARTIFACT_LOCK"
	@echo "  release-dev              bundle + s3 for RELEASE_TAG (default $(RELEASE_TAG))"
	@echo "  docker-publish-dev       (docker.mk) ZK image tagged RELEASE_TAG"
	@echo "  docker-push-dev          (docker.mk) push IMAGE_REPO:RELEASE_TAG"
	@echo ""
	@echo "  PROJECT=$(PROJECT)  S3_BUCKET=$(S3_BUCKET)  →  releases/$(PROJECT)/$(RELEASE_TAG)/"

###############################################################################
# Full end-to-end release pipeline
###############################################################################

release:
ifndef RELEASE_TAG
	@echo ""; \
	echo "=== Terp-Core Release Pipeline ==="; \
	echo ""; \
	read -p "Enter release version (e.g. v5.0.0): " tag; \
	if [ -z "$$tag" ]; then \
		echo "Error: version tag is required."; \
		exit 1; \
	fi; \
	echo ""; \
	echo "Starting release pipeline for $$tag ..."; \
	echo ""; \
	echo "Step 1/5: Building reproducible binaries..."; \
	$(MAKE) create-binaries; \
	echo "Step 2/5: Preparing release artifacts (tarballs + checksums)..."; \
	$(MAKE) release-prep RELEASE_TAG=$$tag; \
	echo "Step 3/5: Generating cosmovisor binaries JSON..."; \
	$(MAKE) create-binaries-json RELEASE_TAG=$$tag; \
	echo "Step 4/5: Generating upgrade guide..."; \
	$(MAKE) create-upgrade-guide; \
	echo "Step 5/5: Publishing release to GitHub..."; \
	$(MAKE) release-publish; \
	echo ""; \
	echo "=== Release pipeline complete for $$tag ==="
else
	@echo ""; \
	echo "=== Terp-Core Release Pipeline for $(RELEASE_TAG) ==="; \
	echo ""; \
	echo "Step 1/5: Building reproducible binaries...";
	$(MAKE) create-binaries
	@echo "Step 2/5: Preparing release artifacts (tarballs + checksums)...";
	$(MAKE) release-prep RELEASE_TAG=$(RELEASE_TAG)
	@echo "Step 3/5: Generating cosmovisor binaries JSON...";
	$(MAKE) create-binaries-json RELEASE_TAG=$(RELEASE_TAG)
	@echo "Step 4/5: Generating upgrade guide...";
	$(MAKE) create-upgrade-guide
	@echo "Step 5/5: Publishing release to GitHub...";
	$(MAKE) release-publish
	@echo ""; \
	echo "=== Release pipeline complete for $(RELEASE_TAG) ==="
endif

###############################################################################
# Goreleaser targets
###############################################################################

release-publish:
ifndef GITHUB_TOKEN
	$(error GITHUB_TOKEN is not set. Please export GITHUB_TOKEN before running 'make release-publish')
endif
	docker run \
		--rm \
		-e GITHUB_TOKEN=$(GITHUB_TOKEN) \
		-e WASMVM_VERSION=$(WASMVM_VERSION) \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v `pwd`:/go/src/terpd \
		-w /go/src/terpd \
		$(GORELEASER_IMAGE) \
		release \
		--clean

release-dry-run:
	docker run \
		--rm \
		-e WASMVM_VERSION=$(WASMVM_VERSION) \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v `pwd`:/go/src/terpd \
		-w /go/src/terpd \
		$(GORELEASER_IMAGE) \
		release \
		--clean \
		--skip=publish

release-snapshot:
	docker run \
		--rm \
		-e WASMVM_VERSION=$(WASMVM_VERSION) \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v `pwd`:/go/src/terpd \
		-w /go/src/terpd \
		$(GORELEASER_IMAGE) \
		release \
		--clean \
		--snapshot \
		--skip=validate \
		--skip=publish

###############################################################################
# Binary build targets
###############################################################################

# Exact vX.Y.Z only (v6.1.0). Rejects -dev, -rc, git-describe.
define require_exact_release_tag
	@if ! echo "$(RELEASE_TAG)" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$'; then \
	  echo "ERROR: RELEASE_TAG must be vX.Y.Z (got '$(or $(RELEASE_TAG),<empty)>'). No -dev, -rc, or commit describe."; \
	  echo "ELF identity is git tag \$$RELEASE_TAG; Cosmovisor pack lives on release/\$$RELEASE_TAG after the tag."; \
	  exit 1; \
	fi
endef

create-binaries:
	$(MAKE) build-reproducible

release-control:
	@RELEASE_TAG=$(RELEASE_TAG) BINARY_COMMIT=$(or $(BINARY_COMMIT),) \
		bash scripts/release/ensure_release_control.sh

create-checksums:
	@mkdir -p $(BUILDDIR)
	@cd $(BUILDDIR) && \
	sha256sum terpd-linux-amd64 terpd-linux-arm64 terpd-debian-arm64 > sha256sum.txt 2>/dev/null || \
	{ echo "Error: binaries not found in $(BUILDDIR)/. Run 'make create-binaries' first."; exit 1; }
	@echo "Checksums written to $(BUILDDIR)/sha256sum.txt"

release-prep:
	$(require_exact_release_tag)
	@ALLOW_PARTIAL=$(or $(ALLOW_PARTIAL),0) PLAN=$(PLAN) TAG=$(RELEASE_TAG) \
		./scripts/release/prep.sh $(patsubst v%,%,$(RELEASE_TAG))

###############################################################################
# Binaries JSON (cosmovisor-compatible)
###############################################################################

verify-artifacts:
	@RELEASE_TAG=$(or $(RELEASE_TAG),v6.0.0) LOCAL=$(or $(LOCAL),0) PLAN=$(or $(PLAN),v6.1) \
		bash scripts/release/verify_artifacts.sh

create-binaries-json:
ifndef RELEASE_TAG
	$(error RELEASE_TAG is not set. Usage: make create-binaries-json RELEASE_TAG=v4.2.0)
endif
	python3 scripts/release/create_binaries_json/create_binaries_json.py --tag $(RELEASE_TAG)

###############################################################################
# Upgrade guide generation
###############################################################################

create-upgrade-guide:
	@echo ""; \
	echo "=== Upgrade Guide Generator ==="; \
	echo ""; \
	echo "Select guide type:"; \
	echo "  1) coordinated  - Governance proposal + specific block height (default)"; \
	echo "  2) rolling       - Non-breaking rolling upgrade (no proposal needed)"; \
	echo ""; \
	read -p "Guide type [1]: " guide_choice; \
	guide_type="coordinated"; \
	if [ "$$guide_choice" = "2" ]; then \
		guide_type="rolling"; \
	fi; \
	echo ""; \
	read -p "Current version (e.g. v18): " current_ver; \
	read -p "Upgrade version (e.g. v19): " upgrade_ver; \
	read -p "Upgrade tag (e.g. v19.0.0): " upgrade_tag; \
	if [ "$$guide_type" = "coordinated" ]; then \
		read -p "Proposal ID: " proposal_id; \
		read -p "Upgrade block height: " upgrade_block; \
		python3 scripts/release/create_upgrade_guide/create_upgrade_guide.py \
			--type coordinated \
			-c $$current_ver \
			-u $$upgrade_ver \
			-t $$upgrade_tag \
			-p $$proposal_id \
			-b $$upgrade_block; \
	else \
		python3 scripts/release/create_upgrade_guide/create_upgrade_guide.py \
			--type rolling \
			-c $$current_ver \
			-u $$upgrade_ver \
			-t $$upgrade_tag; \
	fi

create-upgrade-guide-v6:
	python3 scripts/release/create_upgrade_guide/create_upgrade_guide.py \
		--type coordinated -c v5.2 -u v6 -t v6.0.0 -p $(or $(PROPOSAL_ID),TBD) -b $(or $(UPGRADE_BLOCK),TBD) \
		--out scripts/release/create_upgrade_guide/v5.2-to-v6.md

###############################################################################
# Governance proposal (cw-orch; mnemonic in scripts/release/.env)
###############################################################################

release-proposal: upgrade-proposal

upgrade-proposal:
	@test -f scripts/release/.env || { \
		echo "copy scripts/release/.env.example -> scripts/release/.env and set MAIN_MNEMONIC"; \
		exit 1; \
	}
	@cd scripts/release/upgrade-proposal && cargo run --release -- \
		--proposal "$(or $(PROPOSAL),$(CURDIR)/networks/upgrades/v6.1/draft_proposal.json)" \
		--env-file "$(CURDIR)/scripts/release/.env" \
		$(if $(filter 1,$(BROADCAST)),--broadcast,)

###############################################################################
# cosmos/chain-registry publish (SoT is networks/chain-registry/terpnetwork)
###############################################################################

sync-chain-registry:
	@DEST=$(or $(DEST),$(CURDIR)/crates/chain-registry) bash scripts/release/sync_chain_registry.sh

###############################################################################
# Deterministic source bundle + MinIO/S3 publish (testnet ZK lineage)
# Docs: scripts/release/README.md
###############################################################################

release-bundle:
	@RELEASE_TAG=$(RELEASE_TAG) NETWORK=$(NETWORK) CHAIN_ID=$(CHAIN_ID) \
		IMAGE_REPO=$(or $(IMAGE_REPO),containers.terp.network/terp-core) \
		./scripts/release/make_release_bundle.sh

release-s3:
	@RELEASE_TAG=$(RELEASE_TAG) PROJECT=$(PROJECT) NETWORK=$(NETWORK) CHAIN_ID=$(CHAIN_ID) \
		MINIO_ALIAS=$(MINIO_ALIAS) DRY_RUN=$(DRY_RUN) \
		S3_BUCKET=$(S3_BUCKET) SYNC_ENTRYPOINT=$(or $(SYNC_ENTRYPOINT),0) \
		ENTRYPOINT_SRC=$(ENTRYPOINT_SRC) CONFIG_ENDPOINTS_SRC=$(CONFIG_ENDPOINTS_SRC) \
		PUBLISH_LATEST=$(PUBLISH_LATEST) \
		./scripts/release/publish_s3_release.sh

# Convenience: bundle then upload (does not build/push docker)
release-dev: release-bundle release-s3


###############################################################################
# ZK libwasmvm artifact pack (checksums + version pairing)
###############################################################################

.PHONY: wasmvm-curate curate-v61 preflight-upgrade \
	sync-upgrade-pack verify-upgrade-pack test-upgrade-pack recurate-upgrade-binaries
wasmvm-curate:
	@./scripts/release/curate_wasmvm_artifacts.sh

# Pins + patched store/v2 + wasm checksums for 120u-1 v6.1 soak (no upload).
# SOURCE_DEPS comes from gitlinks at ARTIFACT_LOCK binary_commit (sync_upgrade_pack).
curate-v61:
	@./scripts/release/curate_v61.sh

# Local Cosmovisor / static-asset gate. WRITE=1 rewrites the whole pack
# (lock, binaries.json, cosmovisor.json, proposal.info, SOURCE_DEPS). Does not upload.
preflight-upgrade:
	$(require_exact_release_tag)
	@PLAN=$(or $(PLAN),v6.1) TAG=$(RELEASE_TAG) WRITE=$(or $(WRITE),0) \
		ALLOW_PARTIAL=$(or $(ALLOW_PARTIAL),1) \
		bash scripts/release/preflight_upgrade.sh

# ARTIFACT_LOCK is source of truth unless WRITE=1 (then local linux tarballs are).
# Do not pass makefile default RELEASE_TAG=v6.0.0-dev into verify/sync.
sync-upgrade-pack:
	@if [ "$(or $(WRITE),0)" = "1" ]; then \
	  if ! echo "$(RELEASE_TAG)" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$'; then \
	    echo "ERROR: WRITE=1 requires RELEASE_TAG=vX.Y.Z (got '$(RELEASE_TAG)')"; \
	    exit 1; \
	  fi; \
	  PLAN=$(or $(PLAN),v6.1) TAG=$(RELEASE_TAG) WRITE=1 bash scripts/release/sync_upgrade_pack.sh; \
	else \
	  PLAN=$(or $(PLAN),v6.1) bash scripts/release/sync_upgrade_pack.sh; \
	fi

verify-upgrade-pack:
	@PLAN=$(or $(PLAN),v6.1) CHECK_S3=$(or $(CHECK_S3),0) \
		bash scripts/release/verify_upgrade_pack.sh

test-upgrade-pack:
	@bash scripts/release/test_upgrade_pack.sh

# Rebuild tagged ELF and compare to ARTIFACT_LOCK. Does not upload.
recurate-upgrade-binaries:
	@PLAN=$(or $(PLAN),v6.1) bash scripts/release/recurate_upgrade_binaries.sh
