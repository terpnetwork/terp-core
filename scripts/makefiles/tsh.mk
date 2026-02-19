tsh-help:
	@echo "test subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make tsh-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  tsh                	 View terp sh tests available to run"
	@echo "  tsh-all 			 	 Run all sh tests in repo"
	@echo "  tsh-nfts 			 	 Run sh test for x/nft module"
	@echo "  tsh-ibchook 			 Run sh test for ibc hook sanity"
	@echo "  tsh-pfm 		     	 Run sh test for packet-forward-middleware sanity"
	@echo "  tsh-aa 		     	 Run sh test for sane deployment & use of Abstract Account"
	@echo "  tsh-polytone 			 Run sh test for ibc + wasm sanity"
	@echo "  tsh-staking-hooks 		 Run sh test for staking hook sanity"
	@echo "  tsh-upgrade 		     Run sh test for upgrade proposal & performance sanity"

tsh: tsh-help
tsh-all: tsh-upgrade tsh-staking-hooks tsh-polytone tsh-aa tsh-pfm tsh-ibchook tsh-nfts
tsh-aa: 
	cd tests/tsh/aa && sh a.sh
tsh-ibchook: 
	cd tests/tsh/ibchook && sh a.sh
tsh-upgrade: 
	cd tests/tsh/upgrade && sh a.sh
tsh-staking-hooks: 
	cd tests/tsh/staking-hooks && sh a.sh
tsh-polytone: 
	cd tests/tsh/polytone && sh a.sh
tsh-pfm: 
	cd tests/tsh/pfm && sh a.sh
tsh-nfts: 
	cd tests/tsh/nft && sh a.sh


# include simulations
# include sims.mk