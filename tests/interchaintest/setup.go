package interchaintest

import (
	"context"
	"testing"

	sdkmath "cosmossdk.io/math"
	"github.com/docker/docker/client"
	interchaintest "github.com/strangelove-ventures/interchaintest/v10"
	"github.com/strangelove-ventures/interchaintest/v10/chain/cosmos"
	"github.com/strangelove-ventures/interchaintest/v10/ibc"
	"github.com/strangelove-ventures/interchaintest/v10/testreporter"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zaptest"

	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	testutil "github.com/cosmos/cosmos-sdk/types/module/testutil"
	feesharetypes "github.com/terpnetwork/terp-core/v4/x/feeshare/types"
	tokenfactorytypes "github.com/terpnetwork/terp-core/v4/x/tokenfactory/types"

	sdk "github.com/cosmos/cosmos-sdk/types"
)

var (
	VotingPeriod     = "15s"
	ExpeditedVoting  = "15s"
	MaxDepositPeriod = "10s"
	Denom            = "uterp"

	TerpE2ERepo  = "ghcr.io/terpnetwork/terp-core-e2e"
	TerpMainRepo = "ghcr.io/terpnetwork/terp-core"

	IBCRelayerImage   = "ghcr.io/cosmos/relayer"
	IBCRelayerVersion = "main"

	terpRepo, terpVersion = GetDockerImageInfo()

	genesisAmt = sdkmath.NewInt(10_000_000_000)

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

	terpCfg = ibc.ChainConfig{
		Type:                "cosmos",
		Name:                "terp",
		ChainID:             "120u-1",
		Images:              []ibc.DockerImage{TerpImage},
		Bin:                 "terpd",
		Bech32Prefix:        "terp",
		Denom:               "uterp",
		CoinType:            "118",
		GasPrices:           "0uterp",
		GasAdjustment:       2.0,
		TrustingPeriod:      "112h",
		NoHostMount:         false,
		ConfigFileOverrides: nil, // TODO: use faster blocks
		EncodingConfig:      terpEncoding(),
		ModifyGenesis:       cosmos.ModifyGenesis(defaultGenesisKV),
	}
)

func init() {
	sdk.GetConfig().SetBech32PrefixForAccount("terp", "terp")
	sdk.GetConfig().SetBech32PrefixForValidator("terpvaloper", "terp")
	sdk.GetConfig().SetBech32PrefixForConsensusNode("terpvalcons", "terp")
	sdk.GetConfig().SetCoinType(118)
}

// terpEncoding registers the Terp specific module codecs so that the associated types and msgs
// will be supported when writing to the blocksdb sqlite database.
func terpEncoding() *testutil.TestEncodingConfig {
	cfg := cosmos.DefaultEncoding()

	// register custom types
	// ibclocalhost.RegisterInterfaces(cfg.InterfaceRegistry)
	wasmtypes.RegisterInterfaces(cfg.InterfaceRegistry)
	feesharetypes.RegisterInterfaces(cfg.InterfaceRegistry)
	tokenfactorytypes.RegisterInterfaces(cfg.InterfaceRegistry)

	return &cfg
}

// CreateChain generates a new chain with a custom image (useful for upgrades)
func CreateChain(t *testing.T, numVals, numFull int, img ibc.DockerImage) []ibc.Chain {
	cfg := terpCfg
	cfg.Images = []ibc.DockerImage{img}
	return CreateICTestTerpChainCustomConfig(t, numVals, numFull, cfg)
}

// CreateICTestTerpChain creates a Terp chain for interchain testing with the specified number of validators and full nodes.
func CreateICTestTerpChain(t *testing.T, numVals, numFull int) []ibc.Chain {
	return CreateChain(t, numVals, numFull, TerpImage)
}

func CreateICTestTerpChainCustomConfig(t *testing.T, numVals, numFull int, config ibc.ChainConfig) []ibc.Chain {
	cf := interchaintest.NewBuiltinChainFactory(zaptest.NewLogger(t), []*interchaintest.ChainSpec{
		{
			Name:          "terp",
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
