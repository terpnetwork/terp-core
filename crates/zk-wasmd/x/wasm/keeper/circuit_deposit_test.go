package keeper

import (
	"bytes"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	sdk "github.com/cosmos/cosmos-sdk/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"

	"github.com/CosmWasm/wasmd/x/wasm/types"
)

func TestPayCircuitDepositSplitsPools(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)

	valPool := authtypes.NewModuleAddress(types.CircuitValPoolName)
	devPool := authtypes.NewModuleAddress(types.CircuitDevPoolName)
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(ctx, valPool, "stake").Amount.Int64())
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(ctx, devPool, "stake").Amount.Int64())
}

func TestPayCircuitDepositDevDestinationAccount(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	dao := RandomAccountAddress(t)
	params := k.GetParams(ctx)
	params.CircuitDevDestination = dao.String()
	require.NoError(t, k.SetParams(ctx, params))

	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)

	valPool := authtypes.NewModuleAddress(types.CircuitValPoolName)
	devPool := authtypes.NewModuleAddress(types.CircuitDevPoolName)
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(ctx, valPool, "stake").Amount.Int64())
	require.Equal(t, int64(0), keepers.BankKeeper.GetBalance(ctx, devPool, "stake").Amount.Int64())
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(ctx, dao, "stake").Amount.Int64())
}

func TestQueryCircuitDeposit(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	payer := RandomAccountAddress(t)
	res, err := k.Deposit(ctx, &types.QueryCircuitDepositRequest{Address: payer.String()})
	require.NoError(t, err)
	require.False(t, res.Covered)

	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err = k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	res, err = k.Deposit(ctx, &types.QueryCircuitDepositRequest{Address: payer.String()})
	require.NoError(t, err)
	require.True(t, res.Covered)
	require.Greater(t, res.PaidUntilUnix, ctx.BlockTime().Unix())
}

func TestCircuitDepositGatesUploadWhenNobody(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	params := k.GetParams(ctx)
	params.CircuitUploadAccess = types.AllowNobody
	require.NoError(t, k.SetParams(ctx, params))

	payer := RandomAccountAddress(t)
	inst := types.AllowEverybody
	err := k.authorizeCircuitUpload(ctx, payer, &inst, DefaultAuthorizationPolicy{})
	require.ErrorIs(t, err, types.ErrCircuitDepositRequired)

	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	until, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	require.True(t, k.HasCircuitDeposit(ctx, payer))
	require.Equal(t, ctx.BlockTime().Unix()+types.CircuitDepositSecondsPerYear, until)

	require.NoError(t, k.authorizeCircuitUpload(ctx, payer, &inst, DefaultAuthorizationPolicy{}))

	expired := ctx.WithBlockTime(ctx.BlockTime().Add(366 * 24 * time.Hour))
	require.False(t, k.HasCircuitDeposit(expired, payer))
	err = k.authorizeCircuitUpload(expired, payer, &inst, DefaultAuthorizationPolicy{})
	require.ErrorIs(t, err, types.ErrCircuitDepositRequired)
}

func TestCircuitUploadAllowlistSkipsDeposit(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	admin := RandomAccountAddress(t)
	params := k.GetParams(ctx)
	params.CircuitUploadAccess = types.AccessTypeAnyOfAddresses.With(admin)
	require.NoError(t, k.SetParams(ctx, params))

	inst := types.AllowEverybody
	require.NoError(t, k.authorizeCircuitUpload(ctx, admin, &inst, DefaultAuthorizationPolicy{}))

	other := RandomAccountAddress(t)
	err := k.authorizeCircuitUpload(ctx, other, &inst, DefaultAuthorizationPolicy{})
	require.ErrorIs(t, err, types.ErrCircuitDepositRequired)
}

func TestCircuitUploadEverybodySkipsDeposit(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	params := k.GetParams(ctx)
	params.CircuitUploadAccess = types.AllowEverybody
	require.NoError(t, k.SetParams(ctx, params))

	actor := RandomAccountAddress(t)
	inst := types.AllowEverybody
	require.NoError(t, k.authorizeCircuitUpload(ctx, actor, &inst, DefaultAuthorizationPolicy{}))
	require.False(t, k.HasCircuitDeposit(ctx, actor))
}

func TestGovPolicySkipsCircuitDeposit(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	params := k.GetParams(ctx)
	params.CircuitUploadAccess = types.AllowNobody
	require.NoError(t, k.SetParams(ctx, params))

	govActor := RandomAccountAddress(t)
	inst := types.AllowEverybody
	require.NoError(t, k.authorizeCircuitUpload(ctx, govActor, &inst, GovAuthorizationPolicy{}))
}

func seedCircuitForGC(t *testing.T, k *Keeper, ctx sdk.Context, creator sdk.AccAddress, zkID uint64) {
	t.Helper()
	hash := bytes.Repeat([]byte{1}, 72)
	k.mustStoreCircuitInfo(ctx, zkID, types.NewCircuitInfo(hash, creator, types.AllowEverybody))
	require.NoError(t, k.mustStoreCircuitBytes(ctx, zkID, []byte{1}))
	require.NoError(t, k.setCircuitCreatorIndex(ctx, creator, zkID))
}

func TestCircuitDepositExpiryIndexMovesOnRenew(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 3_000_000))
	first, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	require.True(t, k.hasExpiryIndex(ctx, uint64(first), payer))
	second, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	require.False(t, k.hasExpiryIndex(ctx, uint64(first), payer))
	require.True(t, k.hasExpiryIndex(ctx, uint64(second), payer))
}

func TestPruneExpiredDropsDepositeeAndCircuits(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	params := k.GetParams(ctx)
	params.CircuitUploadAccess = types.AllowNobody
	require.NoError(t, k.SetParams(ctx, params))

	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	seedCircuitForGC(t, k, ctx, payer, 11)
	seedCircuitForGC(t, k, ctx, payer, 12)

	expired := ctx.WithBlockTime(ctx.BlockTime().Add(366 * 24 * time.Hour))
	require.False(t, k.HasCircuitDeposit(expired, payer))
	k.PruneExpiredCircuitDeposits(expired)
	_, ok := k.CircuitDepositPaidUntil(expired, payer)
	require.False(t, ok)
	require.Nil(t, k.GetCircuitInfo(expired, 11))
	require.Nil(t, k.GetCircuitInfo(expired, 12))
}

func TestPruneExpiredBoundsCircuitWork(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	params := k.GetParams(ctx)
	params.CircuitUploadAccess = types.AllowNobody
	require.NoError(t, k.SetParams(ctx, params))

	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	for id := uint64(1); id <= 3; id++ {
		seedCircuitForGC(t, k, ctx, payer, id)
	}
	expired := ctx.WithBlockTime(ctx.BlockTime().Add(366 * 24 * time.Hour))
	k.PruneExpiredCircuitDeposits(expired)
	gone := 0
	for id := uint64(1); id <= 3; id++ {
		if k.GetCircuitInfo(expired, id) == nil {
			gone++
		}
	}
	require.Equal(t, types.MaxCircuitDepositGCCircuits, gone)
	k.PruneExpiredCircuitDeposits(expired)
	for id := uint64(1); id <= 3; id++ {
		require.Nil(t, k.GetCircuitInfo(expired, id))
	}
}

func TestPruneSkipsAllowlistedCircuits(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	admin := RandomAccountAddress(t)
	params := k.GetParams(ctx)
	params.CircuitUploadAccess = types.AccessTypeAnyOfAddresses.With(admin)
	require.NoError(t, k.SetParams(ctx, params))

	keepers.Faucet.Fund(ctx, admin, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, admin, 1)
	require.NoError(t, err)
	seedCircuitForGC(t, k, ctx, admin, 99)

	expired := ctx.WithBlockTime(ctx.BlockTime().Add(366 * 24 * time.Hour))
	k.PruneExpiredCircuitDeposits(expired)
	_, ok := k.CircuitDepositPaidUntil(expired, admin)
	require.False(t, ok)
	require.NotNil(t, k.GetCircuitInfo(expired, 99))
}

func TestPayCancelsPendingCircuitGC(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	params := k.GetParams(ctx)
	params.CircuitUploadAccess = types.AllowNobody
	require.NoError(t, k.SetParams(ctx, params))

	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 4_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	for id := uint64(1); id <= 3; id++ {
		seedCircuitForGC(t, k, ctx, payer, id)
	}
	expired := ctx.WithBlockTime(ctx.BlockTime().Add(366 * 24 * time.Hour))
	k.PruneExpiredCircuitDeposits(expired)
	require.True(t, k.hasCircuitCreatorIndex(expired, payer))

	_, err = k.PayCircuitDeposit(expired, payer, 1)
	require.NoError(t, err)
	k.PruneExpiredCircuitDeposits(expired)
	remain := 0
	for id := uint64(1); id <= 3; id++ {
		if k.GetCircuitInfo(expired, id) != nil {
			remain++
		}
	}
	require.Equal(t, 3-types.MaxCircuitDepositGCCircuits, remain)
}

func TestCircuitDepositStacksYears(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 3_000_000))
	first, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	second, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	require.Equal(t, first+types.CircuitDepositSecondsPerYear, second)
}
