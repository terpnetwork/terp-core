module github.com/terpnework/terp-core/tests/interchaintest

go 1.20

replace (
	// interchaintest supports ICS features so we need this for now
	// github.com/cosmos/cosmos-sdk => github.com/cosmos/cosmos-sdk v0.45.13-ics
	github.com/ChainSafe/go-schnorrkel => github.com/ChainSafe/go-schnorrkel v0.0.0-20200405005733-88cbf1b4c40d
	github.com/ChainSafe/go-schnorrkel/1 => github.com/ChainSafe/go-schnorrkel v1.0.0
    // For this nested module, you always want to replace the parent reference with the current worktree.
	// github.com/terpnetwork/terp-core => ../../
	github.com/terpnetwork/terp-core/v2 => github.com/terpnetwork/terp-core/v2 v2.0.0-20230630074246-7e7c06f1a193
	github.com/btcsuite/btcd => github.com/btcsuite/btcd v0.22.2 //indirect
	github.com/gogo/protobuf => github.com/regen-network/protobuf v1.3.3-alpha.regen.1

    github.com/vedhavyas/go-subkey => github.com/strangelove-ventures/go-subkey v1.0.7
)

require (
	github.com/CosmWasm/wasmd v0.40.2
	github.com/terpnetwork/terp-core/v2 v2.0.0-00010101000000-000000000000
	github.com/strangelove-ventures/interchaintest/v7 v7.0.0-20230622193330-220ce33823c0
	go.uber.org/zap v1.24.0
)