###############################################################################
###                                Release                                  ###
###############################################################################

GORELEASER_IMAGE := ghcr.io/goreleaser/goreleaser-cross:v$(GO_VERSION)
COSMWASM_VERSION := $(shell go list -m github.com/CosmWasm/wasmvm/v3 | sed 's/.* //')

.PHONY: release release-help release-publish release-dry-run release-snapshot \
	create-binaries create-checksums release-prep create-binaries-json \
	create-upgrade-guide release-proposal

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
	@echo "  create-checksums         Generate build/sha256sum.txt"
	@echo "  release-prep             Build binaries + tarballs + checksums via prep.sh"
	@echo "  create-binaries-json     Generate cosmovisor-compatible binaries JSON"
	@echo "  create-upgrade-guide     Generate upgrade guide (rolling or coordinated)"
	@echo "  release-proposal         Submit governance upgrade proposal (stub)"

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
	echo "Step 1/6: Building reproducible binaries..."; \
	$(MAKE) create-binaries; \
	echo "Step 2/6: Generating checksums..."; \
	$(MAKE) create-checksums; \
	echo "Step 3/6: Preparing release artifacts (tarballs + per-file checksums)..."; \
	$(MAKE) release-prep RELEASE_TAG=$$tag; \
	echo "Step 4/6: Generating cosmovisor binaries JSON..."; \
	$(MAKE) create-binaries-json RELEASE_TAG=$$tag; \
	echo "Step 5/6: Generating upgrade guide..."; \
	$(MAKE) create-upgrade-guide; \
	echo "Step 6/6: Publishing release to GitHub..."; \
	$(MAKE) release-publish; \
	echo ""; \
	echo "=== Release pipeline complete for $$tag ==="
else
	@echo ""; \
	echo "=== Terp-Core Release Pipeline for $(RELEASE_TAG) ==="; \
	echo ""; \
	echo "Step 1/6: Building reproducible binaries...";
	$(MAKE) create-binaries
	@echo "Step 2/6: Generating checksums...";
	$(MAKE) create-checksums
	@echo "Step 3/6: Preparing release artifacts (tarballs + per-file checksums)...";
	$(MAKE) release-prep RELEASE_TAG=$(RELEASE_TAG)
	@echo "Step 4/6: Generating cosmovisor binaries JSON...";
	$(MAKE) create-binaries-json RELEASE_TAG=$(RELEASE_TAG)
	@echo "Step 5/6: Generating upgrade guide...";
	$(MAKE) create-upgrade-guide
	@echo "Step 6/6: Publishing release to GitHub...";
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
		-e COSMWASM_VERSION=$(COSMWASM_VERSION) \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v `pwd`:/go/src/terpd \
		-w /go/src/terpd \
		$(GORELEASER_IMAGE) \
		release \
		--clean

release-dry-run:
	docker run \
		--rm \
		-e COSMWASM_VERSION=$(COSMWASM_VERSION) \
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
		-e COSMWASM_VERSION=$(COSMWASM_VERSION) \
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

create-binaries:
	$(MAKE) build-reproducible

create-checksums:
	@mkdir -p $(BUILDDIR)
	@cd $(BUILDDIR) && \
	sha256sum terpd-linux-amd64 terpd-linux-arm64 > sha256sum.txt 2>/dev/null || \
	{ echo "Error: binaries not found in $(BUILDDIR)/. Run 'make create-binaries' first."; exit 1; }
	@echo "Checksums written to $(BUILDDIR)/sha256sum.txt"

release-prep: create-binaries
	@./scripts/release/prep.sh $(if $(RELEASE_TAG),$(patsubst v%,%,$(RELEASE_TAG)))

###############################################################################
# Binaries JSON (cosmovisor-compatible)
###############################################################################

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

###############################################################################
# Governance proposal (stub)
###############################################################################

release-proposal:
	@bash scripts/release/create_proposal/submit_proposal.sh
