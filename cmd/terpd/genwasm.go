package main

import (
	"github.com/cosmos/cosmos-sdk/client"
	"github.com/spf13/cobra"

	wasmCli "github.com/terpnetwork/terp-core/x/wasm/client/cli"
)

func AddGenesisWasmMsgCmd(defaultNodeHome string) *cobra.Command {
	txCmd := &cobra.Command{
		Use:                        "add-wasm-genesis-message",
		Short:                      "Terp Net genesis subcommands",
		DisableFlagParsing:         true,
		SuggestionsMinimumDistance: 2,
		RunE:                       client.ValidateCmd,
	}
	genesisIO := wasmCli.NewDefaultGenesisIO()
	txCmd.AddCommand(
		wasmCli.GenesisStoreCodeCmd(defaultNodeHome, genesisIO),
		wasmCli.GenesisInstantiateContractCmd(defaultNodeHome, genesisIO),
		wasmCli.GenesisExecuteContractCmd(defaultNodeHome, genesisIO),
		wasmCli.GenesisListContractsCmd(defaultNodeHome, genesisIO),
		wasmCli.GenesisListCodesCmd(defaultNodeHome, genesisIO),
	)
	return txCmd
}
