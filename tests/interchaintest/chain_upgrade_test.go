package interchaintest

// notice: upgrade v4 will return error, as headstash accounts in v3 upgrade do not have balance during ictests.

import (
	"context"
	"strconv"
	"testing"
	"time"

	sdkmath "cosmossdk.io/math"
	govv1beta1 "github.com/cosmos/cosmos-sdk/x/gov/types/v1beta1"
	"github.com/docker/docker/client"
	"github.com/strangelove-ventures/interchaintest/v10"
	"github.com/strangelove-ventures/interchaintest/v10/chain/cosmos"
	"github.com/strangelove-ventures/interchaintest/v10/conformance"
	"github.com/strangelove-ventures/interchaintest/v10/ibc"
	"github.com/strangelove-ventures/interchaintest/v10/relayer"
	"github.com/strangelove-ventures/interchaintest/v10/testreporter"
	"github.com/strangelove-ventures/interchaintest/v10/testutil"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zaptest"
)

const (
	haltHeightDelta    = uint64(9) // will propose upgrade this many blocks in the future
	blocksAfterUpgrade = uint64(7)
)

func TestBasicTerpUpgrade(t *testing.T) {
	repo, version := GetDockerImageInfo()
	startVersion := "v4.2.2"
	upgradeName := "v5"
	CosmosChainUpgradeTest(t, "terp", startVersion, version, repo, upgradeName)
}

func CosmosChainUpgradeTest(t *testing.T, chainName, initialVersion, upgradeBranchVersion, upgradeRepo, upgradeName string) {
	if testing.Short() {
		t.Skip("skipping in short mode")
	}

	t.Parallel()

	t.Log(chainName, initialVersion, upgradeBranchVersion, upgradeRepo, upgradeName)

	numVals, numNodes := 2, 2
	chains := interchaintest.CreateChainsWithChainSpecs(t, []*interchaintest.ChainSpec{
		{
			Name:          chainName,
			ChainName:     chainName,
			Version:       initialVersion,
			ChainConfig:   terpCfg,
			NumValidators: &numVals,
			NumFullNodes:  &numNodes,
		},
		{
			Name:          "terp",
			ChainName:     "terpnetwork",
			Version:       "v4.2.2",
			NumValidators: &numVals,
			NumFullNodes:  &numNodes,
		},
	})

	client, network := interchaintest.DockerSetup(t)
	// chains := CreateThisBranchChain(t, numVals, numNodes)
	chain, counterpartyChain := chains[0].(*cosmos.CosmosChain), chains[1].(*cosmos.CosmosChain)

	const (
		path        = "ibc-upgrade-test-path"
		relayerName = "relayer"
	)

	// Get a relayer instance
	rf := interchaintest.NewBuiltinRelayerFactory(
		ibc.CosmosRly,
		zaptest.NewLogger(t),
		relayer.StartupFlags("-b", "100"),
	)

	r := rf.Build(t, client, network)

	ic := interchaintest.NewInterchain().
		AddChain(chain).
		AddChain(counterpartyChain).
		AddRelayer(r, relayerName).
		AddLink(interchaintest.InterchainLink{
			Chain1:  chain,
			Chain2:  counterpartyChain,
			Relayer: r,
			Path:    path,
		})

	ctx := context.Background()
	rep := testreporter.NewNopReporter()

	t.Cleanup(func() {
		_ = ic.Close()
	})

	const userFunds = int64(10_000_000_000)
	users := interchaintest.GetAndFundTestUsers(t, ctx, t.Name(), sdkmath.NewInt(userFunds), chain)
	chainUser := users[0]

	// upgrade
	height, err := chain.Height(ctx)
	require.NoError(t, err, "error fetching height before submit upgrade proposal")

	haltHeight := uint64(height) + haltHeightDelta
	propId := SubmitUpgradeProposal(t, ctx, chain, chainUser, upgradeName, haltHeight)

	chain.VoteOnProposalAllValidators(ctx, propId, "yes")
	require.NoError(t, err, "failed to submit votes")

	_, err = cosmos.PollForProposalStatus(ctx, chain, height, int64(haltHeight), propId, govv1beta1.StatusPassed)
	require.NoError(t, err, "proposal status did not change to passed in expected number of blocks")

	UpgradeNodes(t, ctx, chain, client, haltHeight, upgradeRepo, upgradeBranchVersion)

	// test IBC conformance after chain upgrade on same path
	conformance.TestChainPair(t, ctx, client, network, chain, counterpartyChain, rf, rep, r, path)
}

func UpgradeNodes(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, client *client.Client, haltHeight uint64, upgradeRepo, upgradeBranchVersion string) {

	height, err := chain.Height(ctx)
	require.NoError(t, err, "error fetching height before upgrade")

	timeoutCtx, timeoutCtxCancel := context.WithTimeout(ctx, time.Second*45)
	defer timeoutCtxCancel()

	// this should timeout due to chain halt at upgrade height.
	_ = testutil.WaitForBlocks(timeoutCtx, int(int64(haltHeight)-height)+1, chain)

	height, err = chain.Height(ctx)
	require.NoError(t, err, "error fetching height after chain should have halted")

	// make sure that chain is halted
	require.Equal(t, haltHeight, height, "height is not equal to halt height")

	// bring down nodes to prepare for upgrade
	t.Log("stopping node(s)")
	err = chain.StopAllNodes(ctx)
	require.NoError(t, err, "error stopping node(s)")

	// upgrade version on all nodes
	t.Log("upgrading node(s)")
	chain.UpgradeVersion(ctx, client, upgradeRepo, upgradeBranchVersion)

	// start all nodes back up.
	// validators reach consensus on first block after upgrade height
	// and chain block production resumes.
	t.Log("starting node(s)")
	err = chain.StartAllNodes(ctx)
	require.NoError(t, err, "error starting upgraded node(s)")

	timeoutCtx, timeoutCtxCancel = context.WithTimeout(ctx, time.Second*45)
	defer timeoutCtxCancel()

	err = testutil.WaitForBlocks(timeoutCtx, int(blocksAfterUpgrade), chain)
	require.NoError(t, err, "chain did not produce blocks after upgrade")

}

func SubmitUpgradeProposal(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, user ibc.Wallet, upgradeName string, haltHeight uint64) uint64 {
	proposal := cosmos.SoftwareUpgradeProposal{
		Deposit:     "500000000" + chain.Config().Denom, // greater than min deposit
		Title:       "Chain Upgrade 1",
		Name:        upgradeName,
		Description: "First chain software upgrade",
		Height:      int64(haltHeight),
	}

	upgradeTx, err := chain.UpgradeProposal(ctx, user.KeyName(), proposal)
	require.NoError(t, err, "error submitting software upgrade proposal tx")
	propId, err := strconv.ParseUint(upgradeTx.ProposalID, 10, 64)
	return propId
}
