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
	@echo "  tsh-upgrade-v61          morocco-1 snapshot/statesync in-place-testnet → v6.1 IAVL dual-store + IAVL v2 ingest"
	@echo "  tsh-upgrade-120u-1       120u-1: stage v6.1 binary + fill proposal (no broadcast)"
	@echo "  tsh-upgrade-zero-cv      120u-1 export --for-zero-height, 2m gov, Cosmovisor + pre-placed v6.1"
	@echo "  tsh-upgrade-wasm 	     Run sh test: existing wasm guests survive v6 bulk_memory VM"
	@echo "  tsh-upgrade-cv 	     Run sh test: Cosmovisor auto-swap at v6 halt"
	@echo "  tsh-zk 			 	 Run sh test for zk-wasmvm module (rick)"
	@echo "  tsh-hashmerchant 		 Run sh test for hashmerchant vote extensions"

tsh: tsh-help
tsh-all: tsh-upgrade tsh-upgrade-wasm tsh-upgrade-cv tsh-staking-hooks tsh-polytone tsh-aa tsh-pfm tsh-ibchook tsh-nfts tsh-zk tsh-hashmerchant
tsh-aa: 
	cd tests/tsh/aa && sh a.sh
tsh-ibchook: 
	cd tests/tsh/ibchook && sh a.sh
tsh-upgrade: 
	cd tests/tsh/upgrade && sh a.sh
tsh-upgrade-v61:
	cd tests/tsh/upgrade && sh v61.sh
tsh-upgrade-blake3-iavl: tsh-upgrade-v61
tsh-upgrade-120u-1:
	cd tests/tsh/upgrade && sh 120u-1.sh
tsh-upgrade-zero-cv:
	cd tests/tsh/upgrade && sh zero-cv-v61.sh
tsh-upgrade-wasm:
	cd tests/tsh/upgrade && sh d.sh
tsh-upgrade-cv:
	cd tests/tsh/upgrade && sh e.sh
tsh-staking-hooks: 
	cd tests/tsh/staking-hooks && sh a.sh
tsh-polytone: 
	cd tests/tsh/polytone && sh a.sh
tsh-pfm: 
	cd tests/tsh/pfm && sh a.sh
tsh-nfts: 
	cd tests/tsh/nft && sh a.sh
tsh-zk:
	cd tests/tsh/zk && sh a.rick.sh
tsh-hashmerchant:
	cd tests/tsh/hashmerchant && sh a.sh


# include simulations
# include sims.mk