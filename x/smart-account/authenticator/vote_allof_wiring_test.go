package authenticator_test

import (
	"encoding/json"
	"testing"

	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/v6/x/smart-account/authenticator"
)

// V3 unit-level: ZkProof slot under AllOf product composition.
// Full CosmWasm gate multi-test is residual (needs wasmkeeper); this locks
// fail-closed / skip-on-simulate / nullifier-not-owned policy for the ZKP slot.
func TestVoteAllOfZkProofSlotFailClosed(t *testing.T) {
	prev := authenticator.GlobalPathAVerifier
	authenticator.GlobalPathAVerifier = nil
	t.Cleanup(func() { authenticator.GlobalPathAVerifier = prev })

	zk := authenticator.NewZkProofAuthenticatorV1()
	zkAth, err := zk.Initialize([]byte(`{"zk_id":1,"static_gas":1000,"pi_layout":"vote.delegation.v1"}`))
	require.NoError(t, err)
	require.Equal(t, "ZkProofAuthenticatorV1", zkAth.Type())

	ctx := sdk.Context{}.WithGasMeter(storetypes.NewGasMeter(2_000_000))
	payload, _ := json.Marshal(map[string][]byte{
		"proof":     []byte("p"),
		"instances": []byte("i"),
	})
	req := authenticator.AuthenticationRequest{
		Signature: payload,
		Simulate:  false,
	}

	// ZkProof slot fail-closed without Path A verifier (cannot soft-accept in AllOf)
	err = zkAth.Authenticate(ctx, req)
	require.Error(t, err)
	require.Contains(t, err.Error(), "Path A not wired")

	// Simulate skips expensive ZKP (RecheckTx same shape); nullifier sibling still checks separately
	req.Simulate = true
	require.NoError(t, zkAth.Authenticate(ctx, req))

	// With injected verifier, ZKP passes; Track/Confirm no-op (ceremony owns spend)
	v := authenticator.NewZkProofAuthenticatorV1WithVerifier(func(sdk.Context, uint64, []byte, []byte) error {
		return nil
	})
	zkOk, err := v.Initialize([]byte(`{"zk_id":1}`))
	require.NoError(t, err)
	req.Simulate = false
	require.NoError(t, zkOk.Authenticate(ctx, req))
	require.NoError(t, zkOk.Track(ctx, req))
	require.NoError(t, zkOk.ConfirmExecution(ctx, req))
}

func TestVoteAllOfConfigJSONShape(t *testing.T) {
	// Config bytes match product sketch in docs/research/vote-terp-orch/V3-ALLOF-WIRING.md
	cfg, err := authenticator.ParseZkProofAuthenticatorConfig([]byte(
		`{"zk_id":1,"pi_layout":"vote.delegation.v1","static_gas":100000,"require_pin":true}`,
	))
	require.NoError(t, err)
	require.Equal(t, uint64(1), cfg.ZkID)
	require.True(t, cfg.RequirePin)
	require.Equal(t, uint64(100000), cfg.StaticGas)
}
