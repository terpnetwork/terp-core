package interchaintest

import (
	"context"
	"fmt"
	"testing"

	cosmosproto "github.com/cosmos/gogoproto/proto"
	"github.com/strangelove-ventures/interchaintest/v7"
	"github.com/strangelove-ventures/interchaintest/v7/chain/cosmos"
	"github.com/strangelove-ventures/interchaintest/v7/ibc"
	"github.com/strangelove-ventures/interchaintest/v7/testutil"
	"github.com/stretchr/testify/require"
	clocktypes "github.com/terpnetwork/terp-core/v4/x/clock/types"

	helpers "github.com/terpnetwork/terp-core/tests/interchaintest/helpers"
)

// TestTerpClock ensures the clock module auto executes allowed contracts.
func TestTerpClock(t *testing.T) {
	t.Parallel()

	cfg := terpConfig

	// Base setup
	chains := CreateChainWithCustomConfig(t, 1, 0, cfg)
	ic, ctx, _, _ := BuildInitialChain(t, chains)

	// Chains
	terp := chains[0].(*cosmos.CosmosChain)

	// Users
	users := interchaintest.GetAndFundTestUsers(t, ctx, "default", int64(10_000_000_000), terp, terp)
	user := users[0]

	// Upload & init contract payment to another address
	_, contractAddr := helpers.SetupContract(t, ctx, terp, user.KeyName(), "contracts/clock_example.wasm", false, `{}`)

	// Ensure config is 0
	res := helpers.GetClockContractValue(t, ctx, terp, contractAddr)
	fmt.Printf("- res: %v\n", res.Data.Val)
	require.Equal(t, uint32(0), res.Data.Val)

	// Submit the proposal to add it to the allowed contracts list
	SubmitParamChangeProp(t, ctx, terp, user, []string{contractAddr})

	// Wait 1 block
	_ = testutil.WaitForBlocks(ctx, 1, terp)

	// Validate the contract is now auto incrementing from the end blocker
	res = helpers.GetClockContractValue(t, ctx, terp, contractAddr)
	fmt.Printf("- res: %v\n", res.Data.Val)
	require.GreaterOrEqual(t, res.Data.Val, uint32(1))

	t.Cleanup(func() {
		_ = ic.Close()
	})
}

func SubmitParamChangeProp(t *testing.T, ctx context.Context, chain *cosmos.CosmosChain, user ibc.Wallet, contracts []string) string {
	govAcc := "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq"
	updateParams := []cosmosproto.Message{
		&clocktypes.MsgUpdateParams{
			Authority: govAcc,
			Params:    clocktypes.NewParams(contracts, 1_000_000_000),
		},
	}

	proposal, err := chain.BuildProposal(updateParams, "Params Add Contract", "params", "ipfs://CID", fmt.Sprintf(`500000000%s`, chain.Config().Denom))
	require.NoError(t, err, "error building proposal")

	txProp, err := chain.SubmitProposal(ctx, user.KeyName(), proposal)
	t.Log("txProp", txProp)
	require.NoError(t, err, "error submitting proposal")

	height, _ := chain.Height(ctx)

	err = chain.VoteOnProposalAllValidators(ctx, txProp.ProposalID, cosmos.ProposalVoteYes)
	require.NoError(t, err, "failed to submit votes")

	_, err = cosmos.PollForProposalStatus(ctx, chain, height, height+haltHeightDelta, txProp.ProposalID, cosmos.ProposalStatusPassed)
	require.NoError(t, err, "proposal status did not change to passed in expected number of blocks")

	return txProp.ProposalID
}
