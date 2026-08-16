###############################################################################
###                             ict-rs tests                               ###
###############################################################################
ICT_RS_DIR ?= $(HOME)/abstract/ict-rs

ict-help:
	@echo "ict-rs subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make ict-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  ict-state-sync          Run state sync test"
	@echo "  ict-bootstrap-mainnet   Run bootstrap mainnet test"
	@echo "  ict-all                 Run all ict-rs tests"

ict: ict-help

ict-state-sync:
	cd $(ICT_RS_DIR) && cargo run --example state_sync --features docker

ict-bootstrap-mainnet:
	cd $(ICT_RS_DIR) && cargo run --example bootstrap_mainnet --features docker

ict-all: ict-state-sync ict-bootstrap-mainnet

.PHONY: ict-help ict ict-state-sync ict-bootstrap-mainnet ict-all

ict-bulk-memory-gas:
	cd $(CURDIR)/crates/ict-rs && ICT_BULK_IMAGE=$${ICT_BULK_IMAGE:-local-alpine} ICT_BULK_BIN=$${ICT_BULK_BIN:-terpd} cargo run -p ict-rs --example bulk_memory_gas --features docker

.PHONY: ict-bulk-memory-gas
