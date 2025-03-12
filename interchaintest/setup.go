package interchaintest

import (
	"context"
	"fmt"
	"testing"

	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	ibclocalhost "github.com/cosmos/ibc-go/v8/modules/light-clients/09-localhost"
	"github.com/docker/docker/client"
	interchaintest "github.com/strangelove-ventures/interchaintest/v8"
	"github.com/strangelove-ventures/interchaintest/v8/chain/cosmos"
	"github.com/strangelove-ventures/interchaintest/v8/ibc"
	"github.com/strangelove-ventures/interchaintest/v8/testreporter"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zaptest"

	clocktypes "github.com/terpnetwork/terp-core/v4/x/clock/types"
	feesharetypes "github.com/terpnetwork/terp-core/v4/x/feeshare/types"
	tokenfactorytypes "github.com/terpnetwork/terp-core/v4/x/tokenfactory/types"

	sdk "github.com/cosmos/cosmos-sdk/types"
	testutil "github.com/cosmos/cosmos-sdk/types/module/testutil"
)

var (
	Mnemonic = "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry"

	VotingPeriod     = "15s"
	MaxDepositPeriod = "10s"
	Denom            = "uterp"

	TerpE2ERepo  = "ghcr.io/terpnetwork/terp-core-e2e"
	TerpMainRepo = "ghcr.io/terpnetwork/terp-core"

	IBCRelayerImage   = "ghcr.io/cosmos/relayer"
	IBCRelayerVersion = "justin-localhost-ibc"

	terpRepo, terpVersion = GetDockerImageInfo()

	TerpImage = ibc.DockerImage{
		Repository: terpRepo,
		Version:    terpVersion,
		UidGid:     "1025:1025",
	}

	// SDK v47 Genesis
	defaultGenesisKV = []cosmos.GenesisKV{
		{
			Key:   "app_state.gov.params.voting_period",
			Value: VotingPeriod,
		},
		{
			Key:   "app_state.gov.params.max_deposit_period",
			Value: MaxDepositPeriod,
		},
		{
			Key:   "app_state.gov.params.min_deposit.0.denom",
			Value: Denom,
		},
	}

	terpConfig = ibc.ChainConfig{
		Type:                "cosmos",
		Name:                "terpnetwork",
		ChainID:             "120u-1",
		Images:              []ibc.DockerImage{TerpImage},
		Bin:                 "terpd",
		Bech32Prefix:        "terp",
		Denom:               Denom,
		CoinType:            "118",
		GasPrices:           fmt.Sprintf("0%s", Denom),
		GasAdjustment:       2.0,
		TrustingPeriod:      "112h",
		NoHostMount:         false,
		ConfigFileOverrides: nil,
		EncodingConfig:      terpEncoding(),
		ModifyGenesis:       cosmos.ModifyGenesis(defaultGenesisKV),
	}

	genesisWalletAmount = int64(10_000_000)
)

func init() {
	sdk.GetConfig().SetBech32PrefixForAccount("terp", "terp")
}

// terpEncoding registers the Terp specific module codecs so that the associated types and msgs
// will be supported when writing to the blocksdb sqlite database.
func terpEncoding() *testutil.TestEncodingConfig {
	cfg := cosmos.DefaultEncoding()

	// register custom types
	ibclocalhost.RegisterInterfaces(cfg.InterfaceRegistry)
	wasmtypes.RegisterInterfaces(cfg.InterfaceRegistry)
	feesharetypes.RegisterInterfaces(cfg.InterfaceRegistry)
	tokenfactorytypes.RegisterInterfaces(cfg.InterfaceRegistry)
	clocktypes.RegisterInterfaces(cfg.InterfaceRegistry)

	// github.com/cosmos/cosmos-sdk/types/module/testutil

	return &cfg
}

// This allows for us to test
func FundSpecificUsers() {
}

// Base chain, no relaying off this branch (or terpnetwork/terp-core:local if no branch is provided.)
func CreateThisBranchChain(t *testing.T, numVals, numFull int) []ibc.Chain {
	// Create chain factory with Terp on this current branch

	cf := interchaintest.NewBuiltinChainFactory(zaptest.NewLogger(t), []*interchaintest.ChainSpec{
		{
			Name:          "terp",
			ChainName:     "terpnetwork",
			Version:       terpVersion,
			ChainConfig:   terpConfig,
			NumValidators: &numVals,
			NumFullNodes:  &numFull,
		},
	})

	// Get chains from the chain factory
	chains, err := cf.Chains(t.Name())
	require.NoError(t, err)

	// chain := chains[0].(*cosmos.CosmosChain)
	return chains
}

func CreateChainWithCustomConfig(t *testing.T, numVals, numFull int, config ibc.ChainConfig) []ibc.Chain {
	cf := interchaintest.NewBuiltinChainFactory(zaptest.NewLogger(t), []*interchaintest.ChainSpec{
		{
			Name:          "terp",
			ChainName:     "terpnetwork",
			Version:       config.Images[0].Version,
			ChainConfig:   config,
			NumValidators: &numVals,
			NumFullNodes:  &numFull,
		},
	})

	// Get chains from the chain factory
	chains, err := cf.Chains(t.Name())
	require.NoError(t, err)

	// chain := chains[0].(*cosmos.CosmosChain)
	return chains
}

func BuildInitialChain(t *testing.T, chains []ibc.Chain) (*interchaintest.Interchain, context.Context, *client.Client, string) {
	// Create a new Interchain object which describes the chains, relayers, and IBC connections we want to use
	ic := interchaintest.NewInterchain()

	for _, chain := range chains {
		ic = ic.AddChain(chain)
	}

	rep := testreporter.NewNopReporter()
	eRep := rep.RelayerExecReporter(t)

	ctx := context.Background()
	client, network := interchaintest.DockerSetup(t)

	err := ic.Build(ctx, eRep, interchaintest.InterchainBuildOptions{
		TestName:         t.Name(),
		Client:           client,
		NetworkID:        network,
		SkipPathCreation: true,
		// This can be used to write to the block database which will index all block data e.g. txs, msgs, events, etc.
		// BlockDatabaseFile: interchaintest.DefaultBlockDatabaseFilepath(),
	})
	require.NoError(t, err)

	return ic, ctx, client, network
}
