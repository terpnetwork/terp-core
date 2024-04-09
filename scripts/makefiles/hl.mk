###############################################################################
###                                  heighliner                             ###
###############################################################################
.PHONY: get-heighliner local-image

heighliner-help:
	@echo "heighliner subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make heighliner-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  get        	 Install Heighliner"
	@echo "  local-image    Create a local image"
	@echo ""
	@echo ""


heighliner: heighliner-help

heighliner-get:
	git clone https://github.com/strangelove-ventures/heighliner.git
	cd heighliner && go install

heighliner-local-image:
ifeq (,$(shell which heighliner))
	echo 'heighliner' binary not found. Consider running `make get-heighliner`
else 
	heighliner build -c terpnetwork --local -f ./chains.yaml
endif