package interchaintest

import (
	"context"
	"os"
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
	haltHeightDelta    = uint64(12)
	blocksAfterUpgrade = uint64(8)
)

func upgradeNames() (current, next, plan string) {
	current = getenv("ICT_UPGRADE_FROM", "v5.2.0")
	next = getenv("ICT_UPGRADE_TO", "")
	plan = getenv("ICT_UPGRADE_NAME", "v6")
	if next == "" {
		_, next = GetDockerImageInfo()
	}
	return current, next, plan
}

func getenv(k, def string) string {
	if v, ok := os.LookupEnv(k); ok && v != "" {
		return v
	}
	return def
}

func TestBasicTerpUpgrade(t *testing.T) {
	repo, _ := GetDockerImageInfo()
	from, to, plan := upgradeNames()
	CosmosChainUpgradeTest(t, "terp", from, to, repo, plan)
}

func CosmosChainUpgradeTest(t *testing.T, chainName, initialVersion, upgradeBranchVersion, upgradeRepo, upgradeName string) {
	if testing.Short() {
		t.Skip("skipping in short mode")
	}

	t.Parallel()
	t.Logf("upgrade %s %s -> %s (image %s:%s)", upgradeName, initialVersion, upgradeBranchVersion, upgradeRepo, upgradeBranchVersion)

	numVals, numNodes := 2, 1
	cfg := terpCfg
	cfg.ModifyGenesis = cosmos.ModifyGenesis(append(defaultGenesisKV,
		cosmos.GenesisKV{Key: "app_state.gov.params.expedited_voting_period", Value: ExpeditedVoting},
	))

	chains := interchaintest.CreateChainsWithChainSpecs(t, []*interchaintest.ChainSpec{
		{
			Name:          chainName,
			ChainName:     "terp-upgrade-a",
			Version:       initialVersion,
			ChainConfig:   cfg,
			NumValidators: &numVals,
			NumFullNodes:  &numNodes,
		},
		{
			Name:          chainName,
			ChainName:     "terp-upgrade-b",
			Version:       initialVersion,
			ChainConfig:   cfg,
			NumValidators: &numVals,
			NumFullNodes:  &numNodes,
		},
	})

	dockerd, network := interchaintest.DockerSetup(t)
	chain, counterparty := chains[0].(*cosmos.CosmosChain), chains[1].(*cosmos.CosmosChain)

	const (
		path        = "ibc-upgrade-test-path"
		relayerName = "relayer"
	)

	rf := interchaintest.NewBuiltinRelayerFactory(
		ibc.CosmosRly,
		zaptest.NewLogger(t),
		relayer.StartupFlags("-b", "100"),
	)
	r := rf.Build(t, dockerd, network)

	ic := interchaintest.NewInterchain().
		AddChain(chain).
		AddChain(counterparty).
		AddRelayer(r, relayerName).
		AddLink(interchaintest.InterchainLink{
			Chain1:  chain,
			Chain2:  counterparty,
			Relayer: r,
			Path:    path,
		})

	ctx := context.Background()
	rep := testreporter.NewNopReporter()
	t.Cleanup(func() { _ = ic.Close() })

	require.NoError(t, ic.Build(ctx, rep.RelayerExecReporter(t), interchaintest.InterchainBuildOptions{
		TestName:         t.Name(),
		Client:           dockerd,
		NetworkID:        network,
		SkipPathCreation: false,
	}))

	const userFunds = int64(10_000_000_000)
	users := interchaintest.GetAndFundTestUsers(t, ctx, t.Name(), sdkmath.NewInt(userFunds), chain)
	chainUser := users[0]

	height, err := chain.Height(ctx)
	require.NoError(t, err, "height before proposal")
	haltHeight := uint64(height) + haltHeightDelta

	propID := SubmitUpgradeProposal(t, ctx, chain, chainUser, upgradeName, haltHeight)
	require.NoError(t, chain.VoteOnProposalAllValidators(ctx, propID, cosmos.ProposalVoteYes))

	_, err = cosmos.PollForProposalStatus(ctx, chain, height, int64(haltHeight), propID, govv1beta1.StatusPassed)
	require.NoError(t, err, "proposal did not pass before halt height")

	UpgradeNodes(t, ctx, chain, dockerd, haltHeight, upgradeRepo, upgradeBranchVersion)

	assertPostUpgrade(t, ctx, chain)

	conformance.TestChainPair(t, ctx, dockerd, network, chain, counterparty, rf, rep, r, path)
}

func assertPostUpgrade(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain) {
	t.Helper()
	n := chain.GetNode()

	stdout, _, err := n.ExecQuery(ctx, "tokenfactory", "params")
	require.NoError(t, err, "tokenfactory params after v6")
	require.NotEmpty(t, stdout)

	stdout, _, err = n.ExecQuery(ctx, "wasm", "params")
	require.NoError(t, err, "wasm params after v6")
	require.NotEmpty(t, stdout)

	stdout, _, err = n.ExecQuery(ctx, "upgrade", "module_versions")
	require.NoError(t, err, "module_versions after v6")
	require.NotEmpty(t, stdout)

	height, err := chain.Height(ctx)
	require.NoError(t, err)
	require.Greater(t, height, int64(0))
}

func UpgradeNodes(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, client *client.Client, haltHeight uint64, upgradeRepo, upgradeBranchVersion string) {
	height, err := chain.Height(ctx)
	require.NoError(t, err, "height before halt wait")

	timeoutCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	_ = testutil.WaitForBlocks(timeoutCtx, int(int64(haltHeight)-height)+1, chain)

	height, err = chain.Height(ctx)
	require.NoError(t, err, "height after expected halt")
	require.Equal(t, haltHeight, uint64(height), "chain should halt at upgrade height")

	t.Log("stopping node(s)")
	require.NoError(t, chain.StopAllNodes(ctx))

	t.Logf("upgrading node(s) to %s:%s", upgradeRepo, upgradeBranchVersion)
	chain.UpgradeVersion(ctx, client, upgradeRepo, upgradeBranchVersion)

	t.Log("starting upgraded node(s)")
	require.NoError(t, chain.StartAllNodes(ctx))

	timeoutCtx, cancel = context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	require.NoError(t, testutil.WaitForBlocks(timeoutCtx, int(blocksAfterUpgrade), chain), "no blocks after upgrade")
}

func SubmitUpgradeProposal(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, user ibc.Wallet, upgradeName string, haltHeight uint64) uint64 {
	proposal := cosmos.SoftwareUpgradeProposal{
		Deposit:     "500000000" + chain.Config().Denom,
		Title:       "Chain Upgrade: " + upgradeName,
		Name:        upgradeName,
		Description: "v6: cosmos-sdk 0.54, ibc-go v11.1, 08-wasm v11.1.0",
		Height:      int64(haltHeight),
	}
	upgradeTx, err := chain.UpgradeProposal(ctx, user.KeyName(), proposal)
	require.NoError(t, err, "submit software upgrade proposal")
	propID, err := strconv.ParseUint(upgradeTx.ProposalID, 10, 64)
	require.NoError(t, err)
	return propID
}
