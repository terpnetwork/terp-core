package interchaintest

import (
	"fmt"
	"strconv"
	"testing"

	"github.com/strangelove-ventures/interchaintest/v7"
	"github.com/strangelove-ventures/interchaintest/v7/chain/cosmos"
	"github.com/stretchr/testify/assert"

	helpers "github.com/terpnetwork/terp-core/tests/interchaintest/helpers"
)

// TestTerpBurnModule ensures the terpburn module register and execute sharing functions work properly on smart contracts.
// It is purely for developers ::BurnTokens to function as expected.
func TestTerpBurnModule(t *testing.T) {
	t.Parallel()

	// Base setup
	chains := CreateThisBranchChain(t, 1, 0)
	ic, ctx, _, _ := BuildInitialChain(t, chains)

	// Chains
	terp := chains[0].(*cosmos.CosmosChain)

	nativeDenom := terp.Config().Denom

	// Users
	users := interchaintest.GetAndFundTestUsers(t, ctx, "default", int64(10_000_000), terp, terp)
	user := users[0]

	// Upload & init contract
	_, contractAddr := helpers.SetupContract(t, ctx, terp, user.KeyName(), "contracts/cw_testburn.wasm", `{}`)

	// get balance before execute
	balance, err := terp.GetBalance(ctx, user.FormattedAddress(), nativeDenom)
	if err != nil {
		t.Fatal(err)
	}

	// execute burn of tokens
	burnAmt := int64(1_000_000)
	helpers.ExecuteMsgWithAmount(t, ctx, terp, user, contractAddr, strconv.Itoa(int(burnAmt))+nativeDenom, `{"burn_token":{}}`)

	// verify it is down 1_000_000 tokens since the burn
	updatedBal, err := terp.GetBalance(ctx, user.FormattedAddress(), nativeDenom)
	if err != nil {
		t.Fatal(err)
	}

	// Verify the funds were sent, and burned.
	fmt.Println(balance, updatedBal)
	assert.Equal(t, burnAmt, balance-updatedBal, fmt.Sprintf("balance should be %d less than updated balance", burnAmt))

	t.Cleanup(func() {
		_ = ic.Close()
	})
}
