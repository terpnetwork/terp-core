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
