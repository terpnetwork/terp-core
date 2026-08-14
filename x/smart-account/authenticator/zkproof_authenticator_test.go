package authenticator_test

import (
	"encoding/json"
	"errors"
	"testing"

	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/v6/x/smart-account/authenticator"
)

func TestParseZkProofConfig(t *testing.T) {
	_, err := authenticator.ParseZkProofAuthenticatorConfig(nil)
	require.Error(t, err)

	_, err = authenticator.ParseZkProofAuthenticatorConfig([]byte(`{"zk_id":0}`))
	require.Error(t, err)

	cfg, err := authenticator.ParseZkProofAuthenticatorConfig([]byte(`{"zk_id":1,"pi_layout":"vote.delegation.v1","require_pin":true}`))
	require.NoError(t, err)
	require.Equal(t, uint64(1), cfg.ZkID)
	require.Equal(t, "vote.delegation.v1", cfg.PILayout)
	require.True(t, cfg.RequirePin)
	require.Equal(t, uint64(65536), cfg.MaxProofBytes)
}

func TestParseZkProofAuthPayload(t *testing.T) {
	_, err := authenticator.ParseZkProofAuthPayload(nil)
	require.Error(t, err)

	raw, _ := json.Marshal(map[string][]byte{
		"proof":     []byte{1, 2, 3},
		"instances": []byte{4, 5},
	})
	p, err := authenticator.ParseZkProofAuthPayload(raw)
	require.NoError(t, err)
	require.Equal(t, []byte{1, 2, 3}, p.Proof)
}

func TestZkProofAuthenticateFailClosedWithoutVerifier(t *testing.T) {
	// Isolate global
	prev := authenticator.GlobalPathAVerifier
	authenticator.GlobalPathAVerifier = nil
	t.Cleanup(func() { authenticator.GlobalPathAVerifier = prev })

	z := authenticator.NewZkProofAuthenticatorV1()
	ath, err := z.Initialize([]byte(`{"zk_id":1,"static_gas":1000}`))
	require.NoError(t, err)

	ctx := sdk.Context{}.WithGasMeter(storetypes.NewGasMeter(1_000_000))
	payload, _ := json.Marshal(map[string][]byte{
		"proof":     []byte("proof-bytes"),
		"instances": []byte("pi-bytes"),
	})
	req := authenticator.AuthenticationRequest{
		Signature: payload,
		Simulate:  false,
	}
	err = ath.Authenticate(ctx, req)
	require.Error(t, err)
	require.Contains(t, err.Error(), "Path A not wired")
}

func TestZkProofAuthenticateSkipOnSimulate(t *testing.T) {
	z := authenticator.NewZkProofAuthenticatorV1()
	ath, err := z.Initialize([]byte(`{"zk_id":2,"static_gas":500}`))
	require.NoError(t, err)

	ctx := sdk.Context{}.WithGasMeter(storetypes.NewGasMeter(1_000_000))
	req := authenticator.AuthenticationRequest{Simulate: true}
	require.NoError(t, ath.Authenticate(ctx, req))
}

func TestZkProofAuthenticateWithInjectedVerifier(t *testing.T) {
	called := false
	v := func(ctx sdk.Context, zkID uint64, proof, instances []byte) error {
		called = true
		require.Equal(t, uint64(9), zkID)
		require.Equal(t, []byte("p"), proof)
		return nil
	}
	z := authenticator.NewZkProofAuthenticatorV1WithVerifier(v)
	ath, err := z.Initialize([]byte(`{"zk_id":9,"static_gas":10}`))
	require.NoError(t, err)

	ctx := sdk.Context{}.WithGasMeter(storetypes.NewGasMeter(1_000_000))
	payload, _ := json.Marshal(map[string][]byte{
		"proof":     []byte("p"),
		"instances": []byte("i"),
	})
	require.NoError(t, ath.Authenticate(ctx, authenticator.AuthenticationRequest{Signature: payload}))
	require.True(t, called)

	// verifier error → fail closed
	z2 := authenticator.NewZkProofAuthenticatorV1WithVerifier(func(sdk.Context, uint64, []byte, []byte) error {
		return errors.New("crypto false")
	})
	ath2, err := z2.Initialize([]byte(`{"zk_id":9}`))
	require.NoError(t, err)
	err = ath2.Authenticate(ctx, authenticator.AuthenticationRequest{Signature: payload})
	require.Error(t, err)
	require.Contains(t, err.Error(), "verify failed")
}

func TestZkProofTrackConfirmNoop(t *testing.T) {
	z := authenticator.NewZkProofAuthenticatorV1()
	ath, _ := z.Initialize([]byte(`{"zk_id":1}`))
	ctx := sdk.Context{}
	require.NoError(t, ath.Track(ctx, authenticator.AuthenticationRequest{}))
	require.NoError(t, ath.ConfirmExecution(ctx, authenticator.AuthenticationRequest{}))
}

func TestZkProofStaticGasDefault(t *testing.T) {
	z := authenticator.NewZkProofAuthenticatorV1()
	ath, err := z.Initialize([]byte(`{"zk_id":1}`))
	require.NoError(t, err)
	require.Equal(t, authenticator.DefaultZkProofStaticGas, ath.StaticGas())
}
