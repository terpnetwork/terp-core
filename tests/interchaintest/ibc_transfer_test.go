package interchaintest

import (
	"context"
	"testing"

	sdkmath "cosmossdk.io/math"
	transfertypes "github.com/cosmos/ibc-go/v10/modules/apps/transfer/types"
	"github.com/strangelove-ventures/interchaintest/v10"
	"github.com/strangelove-ventures/interchaintest/v10/chain/cosmos"
	"github.com/strangelove-ventures/interchaintest/v10/ibc"
	interchaintestrelayer "github.com/strangelove-ventures/interchaintest/v10/relayer"
	"github.com/strangelove-ventures/interchaintest/v10/testreporter"
	"github.com/strangelove-ventures/interchaintest/v10/testutil"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zaptest"
)

// TestTerpGaiaIBCTransfer spins up a Terp and Gaia network, initializes an IBC connection between them,
// and sends an ICS20 token transfer from Terp->Gaia and then back from Gaia->Terp.
func TestTerpGaiaIBCTransfer(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	t.Parallel()

	// Create chain factory with Terp and Gaia
	numVals := 1
	numFullNodes := 1

	cf := interchaintest.NewBuiltinChainFactory(zaptest.NewLogger(t), []*interchaintest.ChainSpec{
		{
			Name:          "terp",
			ChainConfig:   terpCfg,
			NumValidators: &numVals,
			NumFullNodes:  &numFullNodes,
		},
		{
			Name:          "gaia",
			Version:       "v9.1.0",
			NumValidators: &numVals,
			NumFullNodes:  &numFullNodes,
		},
	})

	const (
		path = "ibc-path"
	)

	// Get chains from the chain factory
	chains, err := cf.Chains(t.Name())
	require.NoError(t, err)

	client, network := interchaintest.DockerSetup(t)

	terp, gaia := chains[0].(*cosmos.CosmosChain), chains[1].(*cosmos.CosmosChain)

	relayerType, relayerName := ibc.CosmosRly, "relay"

	// Get a relayer instance
	rf := interchaintest.NewBuiltinRelayerFactory(
		relayerType,
		zaptest.NewLogger(t),
		interchaintestrelayer.CustomDockerImage(IBCRelayerImage, IBCRelayerVersion, "100:1000"),
		interchaintestrelayer.StartupFlags("--processor", "events", "--block-history", "100"),
	)

	r := rf.Build(t, client, network)

	ic := interchaintest.NewInterchain().
		AddChain(terp).
		AddChain(gaia).
		AddRelayer(r, relayerName).
		AddLink(interchaintest.InterchainLink{
			Chain1:  terp,
			Chain2:  gaia,
			Relayer: r,
			Path:    path,
		})

	ctx := context.Background()

	rep := testreporter.NewNopReporter()
	eRep := rep.RelayerExecReporter(t)

	require.NoError(t, ic.Build(ctx, eRep, interchaintest.InterchainBuildOptions{
		TestName:          t.Name(),
		Client:            client,
		NetworkID:         network,
		BlockDatabaseFile: interchaintest.DefaultBlockDatabaseFilepath(),
		SkipPathCreation:  false,
	}))
	t.Cleanup(func() {
		_ = ic.Close()
	})

	// Create some user accounts on both chains
	users := interchaintest.GetAndFundTestUsers(t, ctx, t.Name(), genesisAmt, terp, gaia)

	// Wait a few blocks for relayer to start and for user accounts to be created
	err = testutil.WaitForBlocks(ctx, 5, terp, gaia)
	require.NoError(t, err)

	// Get our Bech32 encoded user addresses
	terpUser, gaiaUser := users[0], users[1]

	terpUserAddr := terpUser.FormattedAddress()
	gaiaUserAddr := gaiaUser.FormattedAddress()

	// Get original account balances
	terpOrigBal, err := terp.GetBalance(ctx, terpUserAddr, terp.Config().Denom)
	require.NoError(t, err)
	require.Equal(t, genesisAmt, terpOrigBal)

	gaiaOrigBal, err := gaia.GetBalance(ctx, gaiaUserAddr, gaia.Config().Denom)
	require.NoError(t, err)
	require.Equal(t, genesisAmt, gaiaOrigBal)

	// Compose an IBC transfer and send from Terp -> Gaia
	const transferAmount = int64(1_000)
	transfer := ibc.WalletAmount{
		Address: gaiaUserAddr,
		Denom:   terp.Config().Denom,
		Amount:  sdkmath.NewInt(transferAmount),
	}

	channel, err := ibc.GetTransferChannel(ctx, r, eRep, terp.Config().ChainID, gaia.Config().ChainID)
	require.NoError(t, err)

	terpHeight, err := terp.Height(ctx)
	require.NoError(t, err)

	transferTx, err := terp.SendIBCTransfer(ctx, channel.ChannelID, terpUserAddr, transfer, ibc.TransferOptions{})
	require.NoError(t, err)

	err = r.StartRelayer(ctx, eRep, path)
	require.NoError(t, err)

	t.Cleanup(
		func() {
			err := r.StopRelayer(ctx, eRep)
			if err != nil {
				t.Logf("an error occured while stopping the relayer: %s", err)
			}
		},
	)

	// Poll for the ack to know the transfer was successful
	// TODO: Remove after auto transfer is fixed in the relayer
	r.Flush(ctx, eRep, path, channel.ChannelID)
	_, err = testutil.PollForAck(ctx, terp, terpHeight-5, terpHeight+50, transferTx.Packet)
	require.NoError(t, err)

	err = testutil.WaitForBlocks(ctx, 10, terp)
	require.NoError(t, err)

	// Get the IBC denom for uterp on Gaia
	terpTokenDenom := transfertypes.GetPrefixedDenom(channel.Counterparty.PortID, channel.Counterparty.ChannelID, terp.Config().Denom)
	terpIBCDenom := transfertypes.ParseDenomTrace(terpTokenDenom).IBCDenom()

	// Assert that the funds are no longer present in user acc on Terp and are in the user acc on Gaia
	terpUpdateBal, err := terp.GetBalance(ctx, terpUserAddr, terp.Config().Denom)
	require.NoError(t, err)
	require.Equal(t, terpOrigBal.Sub(sdkmath.NewInt(transferAmount)), terpUpdateBal)

	gaiaUpdateBal, err := gaia.GetBalance(ctx, gaiaUserAddr, terpIBCDenom)
	require.NoError(t, err)
	require.Equal(t, transferAmount, gaiaUpdateBal)

	// Compose an IBC transfer and send from Gaia -> Terp
	transfer = ibc.WalletAmount{
		Address: terpUserAddr,
		Denom:   terpIBCDenom,
		Amount:  sdkmath.NewInt(transferAmount),
	}

	gaiaHeight, err := gaia.Height(ctx)
	require.NoError(t, err)

	transferTx, err = gaia.SendIBCTransfer(ctx, channel.Counterparty.ChannelID, gaiaUserAddr, transfer, ibc.TransferOptions{})
	require.NoError(t, err)

	// Poll for the ack to know the transfer was successful
	_, err = testutil.PollForAck(ctx, gaia, gaiaHeight, gaiaHeight+25, transferTx.Packet)
	require.NoError(t, err)

	// Assert that the funds are now back on Terp and not on Gaia
	terpUpdateBal, err = terp.GetBalance(ctx, terpUserAddr, terp.Config().Denom)
	require.NoError(t, err)
	require.Equal(t, terpOrigBal, terpUpdateBal)

	gaiaUpdateBal, err = gaia.GetBalance(ctx, gaiaUserAddr, terpIBCDenom)
	require.NoError(t, err)
	require.Equal(t, int64(0), gaiaUpdateBal)
}
