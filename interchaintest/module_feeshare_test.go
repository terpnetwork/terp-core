package interchaintest

import (
	"testing"

	sdkmath "cosmossdk.io/math"
	"github.com/strangelove-ventures/interchaintest/v10"
	"github.com/strangelove-ventures/interchaintest/v10/chain/cosmos"

	helpers "github.com/terpnetwork/terp-core/tests/interchaintest/helpers"
)

// TestTerpFeeShare ensures the feeshare module register and execute sharing functions work properly on smart contracts.
func TestTerpFeeShare(t *testing.T) {
	t.Parallel()

	// Base setup
	chains := CreateThisBranchChain(t, 1, 0)
	ic, ctx, _, _ := BuildInitialChain(t, chains)

	// Chains
	terp := chains[0].(*cosmos.CosmosChain)
	t.Log("terp.GetHostRPCAddress()", terp.GetHostRPCAddress())

	nativeDenom := terp.Config().Denom

	// Users
	users := interchaintest.GetAndFundTestUsers(t, ctx, "default", sdkmath.NewInt(10_000_000), terp, terp)
	user := users[0]
	feeRcvAddr := "terp1v75wlkccpv7le3560zw32v2zjes5n0e7fgfzdc"

	// Upload & init contract payment to another address
	_, contractAddr := helpers.SetupContract(t, ctx, terp, user.KeyName(), "contracts/cw_template.wasm", false, `{"count":0}`)

	// register contract to a random address (since we are the creator, though not the admin)
	helpers.RegisterFeeShare(t, ctx, terp, user, contractAddr, feeRcvAddr)
	if balance, err := terp.GetBalance(ctx, feeRcvAddr, nativeDenom); err != nil {
		t.Fatal(err)
	} else if balance != sdkmath.ZeroInt() {
		t.Fatal("balance not 0")
	}

	// execute with a 10000 fee (so 5000 denom should be in the contract now with 50% feeshare default)
	helpers.ExecuteMsgWithFee(t, ctx, terp, user, contractAddr, "", "10000"+nativeDenom, `{"increment":{}}`)

	// check balance of nativeDenom now
	if balance, err := terp.GetBalance(ctx, feeRcvAddr, nativeDenom); err != nil {
		t.Fatal(err)
	} else if balance != sdkmath.NewInt(5000) {
		t.Fatal("balance not 5,000. it is ", balance, nativeDenom)
	}

	t.Cleanup(func() {
		_ = ic.Close()
	})
}
