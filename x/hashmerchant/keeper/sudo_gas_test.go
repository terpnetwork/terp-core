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

func TestDefaultContractGasLimitIs32MiBCompileCost(t *testing.T) {
	require.Equal(t, uint64(32<<20)*3, types.DefaultContractGasLimit)
}
