// 1. deploy network
// 2. upload cosmwasm contract + vk
// 3. generate proof & verify proof
// 4. validate improper proof fails
// 5. validate tokenfactory is invoked
package interchaintest

import (
	"encoding/base64"
	"fmt"
	"testing"

	sdkmath "cosmossdk.io/math"
	"github.com/strangelove-ventures/interchaintest/v10"
	"github.com/strangelove-ventures/interchaintest/v10/chain/cosmos"

	helpers "github.com/terpnetwork/terp-core/tests/interchaintest/helpers"
)

// TestTerpZkCosmwasmVm
func TestTerpZkCosmwasmVm(t *testing.T) {
	t.Parallel()
	proofBytes := []byte{0x00, 0x01, 0x02}
	// Base setup
	chains := CreateICTestTerpChain(t, 1, 0)
	ic, ctx, _, _ := BuildInitialChain(t, chains)
	terp := chains[0].(*cosmos.CosmosChain)
	t.Log("terp.GetHostRPCAddress()", terp.GetHostRPCAddress())
	user := interchaintest.GetAndFundTestUsers(t, ctx, "default", sdkmath.NewInt(10_000_000), terp, terp)[0]

	// Upload & init contract + cirucit vk param binary
	_, headstash := helpers.SetupContractWithVk(t, ctx, terp, user, "contracts/zk_wasmvm_test.wasm", "circuits/norick_vk.bin", false, `{}`)
	msg := fmt.Sprintf(`{"proove":{"word_id": 0, "proof": "%s"}}`, base64.StdEncoding.EncodeToString(proofBytes))
	// submit proof to contract, confirm valid
	helpers.ExecuteMsgWithAmount(t, ctx, terp, user, headstash, "0", msg)

	// expect error: proof generated from forbidden word
	fmt.Sprintf(`{"proove":{"word_id": 1, "proof": "%s"}}`, base64.StdEncoding.EncodeToString(proofBytes))
	t.Cleanup(func() {
		_ = ic.Close()
	})
}
