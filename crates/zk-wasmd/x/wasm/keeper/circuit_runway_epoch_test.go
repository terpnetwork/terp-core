package keeper

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	sdk "github.com/cosmos/cosmos-sdk/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"

	"github.com/CosmWasm/wasmd/x/wasm/types"
)

type payoutStaking struct {
	bonded []stakingtypes.Validator
}

func (p payoutStaking) BondDenom(context.Context) (string, error) { return "stake", nil }
func (p payoutStaking) GetValidator(context.Context, sdk.ValAddress) (stakingtypes.Validator, error) {
	return stakingtypes.Validator{}, nil
}
func (p payoutStaking) GetBondedValidatorsByPower(context.Context) ([]stakingtypes.Validator, error) {
	return p.bonded, nil
}
func (p payoutStaking) GetAllDelegatorDelegations(context.Context, sdk.AccAddress) ([]stakingtypes.Delegation, error) {
	return nil, nil
}
func (p payoutStaking) GetDelegation(context.Context, sdk.AccAddress, sdk.ValAddress) (stakingtypes.Delegation, error) {
	return stakingtypes.Delegation{}, nil
}
func (p payoutStaking) HasReceivingRedelegation(context.Context, sdk.AccAddress, sdk.ValAddress) (bool, error) {
	return false, nil
}

func valOp(t *testing.T, i byte) (sdk.AccAddress, stakingtypes.Validator) {
	t.Helper()
	addr := sdk.AccAddress(bytesRepeat(20, i))
	return addr, stakingtypes.Validator{
		OperatorAddress: sdk.ValAddress(addr).String(),
		Status:          stakingtypes.Bonded,
	}
}

func bytesRepeat(n int, b byte) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}

func TestEpochSettleFairWeights(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	a, va := valOp(t, 1)
	b, vb := valOp(t, 2)
	c, vc := valOp(t, 3)
	k.stakingKeeper = payoutStaking{bonded: []stakingtypes.Validator{va, vb, vc}}
	k.circuitWeight = func(_ context.Context, v stakingtypes.Validator) int64 {
		switch v.OperatorAddress {
		case va.OperatorAddress:
			return 2
		case vb.OperatorAddress:
			return 1
		default:
			return 0
		}
	}

	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)

	k.setCircuitEpochInfo(ctx, CircuitEpochInfo{
		Identifier:            types.CircuitDistrEpochDay,
		DurationSeconds:       1,
		CurrentEpoch:          0,
		CurrentEpochStartUnix: ctx.BlockTime().Unix() - 2,
	})
	later := ctx.WithBlockTime(ctx.BlockTime().Add(2 * time.Second))
	k.TickCircuitEpoch(later)

	require.Equal(t, int64(333_333), keepers.BankKeeper.GetBalance(later, a, "stake").Amount.Int64())
	require.Equal(t, int64(166_666), keepers.BankKeeper.GetBalance(later, b, "stake").Amount.Int64())
	require.Equal(t, int64(0), keepers.BankKeeper.GetBalance(later, c, "stake").Amount.Int64())
	pool := authtypes.NewModuleAddress(types.CircuitValPoolName)
	remain := keepers.BankKeeper.GetBalance(later, pool, "stake").Amount.Int64()
	require.Equal(t, int64(500_000-333_333-166_666), remain)
}

func TestEpochJoinLeaveSet(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	a, va := valOp(t, 1)
	b, vb := valOp(t, 2)
	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)

	k.stakingKeeper = payoutStaking{bonded: []stakingtypes.Validator{va}}
	k.setCircuitEpochInfo(ctx, CircuitEpochInfo{
		Identifier:            types.CircuitDistrEpochDay,
		DurationSeconds:       1,
		CurrentEpochStartUnix: ctx.BlockTime().Unix() - 2,
	})
	t1 := ctx.WithBlockTime(ctx.BlockTime().Add(2 * time.Second))
	k.TickCircuitEpoch(t1)
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(t1, a, "stake").Amount.Int64())
	require.Equal(t, int64(0), keepers.BankKeeper.GetBalance(t1, b, "stake").Amount.Int64())

	keepers.Faucet.Fund(t1, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err = k.PayCircuitDeposit(t1, payer, 1)
	require.NoError(t, err)
	k.stakingKeeper = payoutStaking{bonded: []stakingtypes.Validator{vb}}
	info, ok := k.getCircuitEpochInfo(t1)
	require.True(t, ok)
	info.CurrentEpochStartUnix = t1.BlockTime().Unix() - 2
	k.setCircuitEpochInfo(t1, info)
	t2 := t1.WithBlockTime(t1.BlockTime().Add(2 * time.Second))
	k.TickCircuitEpoch(t2)
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(t2, a, "stake").Amount.Int64())
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(t2, b, "stake").Amount.Int64())
}

func TestEpochAllOfflineKeepsBag(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	_, va := valOp(t, 1)
	k.stakingKeeper = payoutStaking{bonded: []stakingtypes.Validator{va}}
	k.circuitWeight = func(context.Context, stakingtypes.Validator) int64 { return 0 }

	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)

	k.setCircuitEpochInfo(ctx, CircuitEpochInfo{
		Identifier:            types.CircuitDistrEpochDay,
		DurationSeconds:       1,
		CurrentEpochStartUnix: ctx.BlockTime().Unix() - 2,
	})
	later := ctx.WithBlockTime(ctx.BlockTime().Add(2 * time.Second))
	k.TickCircuitEpoch(later)
	pool := authtypes.NewModuleAddress(types.CircuitValPoolName)
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(later, pool, "stake").Amount.Int64())
}

func TestTickDoesNotSettleBeforeDuration(t *testing.T) {
	ctx, keepers := CreateDefaultTestInput(t)
	k := keepers.WasmKeeper
	a, va := valOp(t, 1)
	k.stakingKeeper = payoutStaking{bonded: []stakingtypes.Validator{va}}
	payer := RandomAccountAddress(t)
	keepers.Faucet.Fund(ctx, payer, sdk.NewInt64Coin("stake", 2_000_000))
	_, err := k.PayCircuitDeposit(ctx, payer, 1)
	require.NoError(t, err)
	k.setCircuitEpochInfo(ctx, CircuitEpochInfo{
		Identifier:            types.CircuitDistrEpochDay,
		DurationSeconds:       3600,
		CurrentEpochStartUnix: ctx.BlockTime().Unix(),
	})
	k.TickCircuitEpoch(ctx)
	pool := authtypes.NewModuleAddress(types.CircuitValPoolName)
	require.Equal(t, int64(500_000), keepers.BankKeeper.GetBalance(ctx, pool, "stake").Amount.Int64())
	require.Equal(t, int64(0), keepers.BankKeeper.GetBalance(ctx, a, "stake").Amount.Int64())
}
