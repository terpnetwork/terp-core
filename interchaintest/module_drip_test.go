package interchaintest

import (
	"fmt"
	"testing"

	sdkmath "cosmossdk.io/math"

	"github.com/strangelove-ventures/interchaintest/v10"
	"github.com/strangelove-ventures/interchaintest/v10/chain/cosmos"

	helpers "github.com/terpnetwork/terp-core/tests/interchaintest/helpers"
)

// TestJunoDrip ensures the drip module properly distributes tokens from whitelisted accounts.
func TestTerpDrip(t *testing.T) {
	t.Parallel()

	// Setup new pre determined user (from test_node.sh)
	mnemonic := "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry"
	addr := "terp1hj5fveer5cjtn4wd6wstzugjfdxzl0xppxm7xs"

	// Base setup
	newCfg := terpConfig
	newCfg.ModifyGenesis = cosmos.ModifyGenesis(append(defaultGenesisKV, []cosmos.GenesisKV{
		{
			Key:   "app_state.drip.params.allowed_addresses",
			Value: []string{addr},
		},
	}...))

	chains := CreateChainWithCustomConfig(t, 1, 0, newCfg)
	ic, ctx, _, _ := BuildInitialChain(t, chains)

	// Chains
	terp := chains[0].(*cosmos.CosmosChain)
	nativeDenom := terp.Config().Denom

	// User
	user, err := interchaintest.GetAndFundTestUserWithMnemonic(ctx, "default", mnemonic, sdkmath.NewInt(1000000_000_000), terp)
	if err != nil {
		t.Fatal(err)
	}

	// New TF token to distributes
	tfDenom := helpers.CreateTokenFactoryDenom(t, ctx, terp, user, "dripme", fmt.Sprintf("0%s", Denom))
	distributeAmt := sdkmath.NewInt(1_000_000)
	helpers.MintTokenFactoryDenom(t, ctx, terp, user, distributeAmt.Uint64(), tfDenom)
	if balance, err := terp.GetBalance(ctx, user.FormattedAddress(), tfDenom); err != nil {
		t.Fatal(err)
	} else if balance != distributeAmt {
		t.Fatalf("balance not %d, got %d", distributeAmt, balance)
	}

	// Stake some tokens
	vals := helpers.GetValidators(t, ctx, terp)
	valoper := vals.Validators[0].OperatorAddress

	stakeAmt := 100000_000_000
	helpers.StakeTokens(t, ctx, terp, user, valoper, fmt.Sprintf("%d%s", stakeAmt, nativeDenom))

	// Drip the TF Tokens to all stakers
	distribute := int64(1_000_000)
	helpers.DripTokens(t, ctx, terp, user, fmt.Sprintf("%d%s", distribute, tfDenom))

	// Claim staking rewards to capture the drip
	helpers.ClaimStakingRewards(t, ctx, terp, user, valoper)

	// Check balances has the TF Denom from the claim
	bals, _ := terp.BankQueryAllBalances(ctx, user.FormattedAddress())
	fmt.Println("balances", bals)

	found := false
	for _, bal := range bals {
		if bal.Denom == tfDenom {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("did not find drip token")
	}

	t.Cleanup(func() {
		_ = ic.Close()
	})
}
