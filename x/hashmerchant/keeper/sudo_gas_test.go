package keeper

import (
	"context"
	"testing"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/v6/x/hashmerchant/types"
)

type recordingWasm struct {
	lastLimit uint64
	burn      uint64
	calls     int
}

func (r *recordingWasm) Sudo(ctx context.Context, _ sdk.AccAddress, _ []byte) ([]byte, error) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	r.lastLimit = sdkCtx.GasMeter().Limit()
	r.calls++
	if r.burn > 0 {
		sdkCtx.GasMeter().ConsumeGas(r.burn, "test-burn")
	}
	return []byte("ok"), nil
}

func TestSudoBoundedCapsMeter(t *testing.T) {
	wasm := &recordingWasm{burn: 1}
	k, ctx := setupOracleKeeper(t)
	k.wasmKeeper = wasm

	addr := sdk.AccAddress(make([]byte, 20))
	err := k.sudoBounded(ctx, addr, []byte(`{}`), 4_000)
	require.NoError(t, err)
	require.Equal(t, uint64(4_000), wasm.lastLimit)
	require.Equal(t, 1, wasm.calls)
}

func TestSudoBoundedOutOfGasDoesNotPanic(t *testing.T) {
	wasm := &recordingWasm{burn: 50_000}
	k, ctx := setupOracleKeeper(t)
	k.wasmKeeper = wasm

	addr := sdk.AccAddress(make([]byte, 20))
	err := k.sudoBounded(ctx, addr, []byte(`{}`), 1_000)
	require.Error(t, err)
	require.Contains(t, err.Error(), "gas limit")
	require.Equal(t, uint64(1_000), wasm.lastLimit)
}

func TestDispatchSudoUsesParamLimit(t *testing.T) {
	wasm := &recordingWasm{burn: 1}
	k, ctx := setupOracleKeeper(t)
	k.wasmKeeper = wasm

	p := types.DefaultParams()
	p.ContractGasLimit = 8_000
	require.NoError(t, k.SetParams(ctx, p))

	addr := sdk.AccAddress(bytes20(1))
	require.NoError(t, k.SetRegisteredContract(ctx, types.RegisteredContract{
		ContractAddr: addr.String(),
		ChainUid:     "gas-lab",
		Enabled:      true,
	}))
	require.NoError(t, k.SetEscrowRecord(ctx, types.EscrowRecord{
		ContractAddr:    addr.String(),
		PaidUntilHeight: 99_999,
	}))

	k.dispatchSudoCallbacks(ctx, types.HashRoot{
		ChainUid: "gas-lab",
		Algo:     "sha256",
		Root:     []byte{1},
	}, nil)
	require.Equal(t, 1, wasm.calls)
	require.Equal(t, uint64(8_000), wasm.lastLimit)
}

func TestEnsureSudoGasLimitFillsZero(t *testing.T) {
	k, ctx := setupOracleKeeper(t)
	p := types.DefaultParams()
	p.ContractGasLimit = 0
	require.NoError(t, k.SetParams(ctx, p))
	require.NoError(t, k.EnsureSudoGasLimit(ctx))
	got, err := k.GetParams(ctx)
	require.NoError(t, err)
	require.Equal(t, types.DefaultContractGasLimit, got.ContractGasLimit)
}

func TestDefaultContractGasLimitIs32MiBCompileCost(t *testing.T) {
	require.Equal(t, uint64(32<<20)*3, types.DefaultContractGasLimit)
}

func bytes20(b byte) []byte {
	out := make([]byte, 20)
	for i := range out {
		out[i] = b
	}
	return out
}
