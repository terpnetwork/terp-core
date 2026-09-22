package keeper

import (
	"context"
	"encoding/json"
	"os"
	"strconv"

	sdk "github.com/cosmos/cosmos-sdk/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"

	"github.com/CosmWasm/wasmd/x/wasm/types"
)

// CircuitEpochInfo is the Osmosis EpochInfo subset wasm ticks until x/epochs is mounted.
type CircuitEpochInfo struct {
	Identifier                string `json:"identifier"`
	DurationSeconds           int64  `json:"duration_seconds"`
	CurrentEpoch              int64  `json:"current_epoch"`
	CurrentEpochStartUnix     int64  `json:"current_epoch_start_unix"`
	CurrentEpochStartHeight   int64  `json:"current_epoch_start_height"`
}

func (k Keeper) receiveCircuitRunwayPayment(ctx context.Context, payer sdk.AccAddress, amt sdk.Coins) error {
	valPool, devPool := types.SplitCircuitRunway(amt)
	if !valPool.Empty() {
		if err := k.bankKeeper.SendCoinsFromAccountToModule(ctx, payer, types.CircuitValPoolName, valPool); err != nil {
			return err
		}
	}
	if !devPool.Empty() {
		dest := k.GetParams(ctx).CircuitDevDestination
		if dest != "" {
			addr, err := sdk.AccAddressFromBech32(dest)
			if err != nil {
				return err
			}
			if err := k.bankKeeper.SendCoins(ctx, payer, addr, devPool); err != nil {
				return err
			}
		} else if err := k.bankKeeper.SendCoinsFromAccountToModule(ctx, payer, types.CircuitDevPoolName, devPool); err != nil {
			return err
		}
	}
	return nil
}

func (k Keeper) getCircuitEpochInfo(ctx context.Context) (CircuitEpochInfo, bool) {
	store := k.storeService.OpenKVStore(ctx)
	bz, err := store.Get(types.CircuitEpochInfoPrefix)
	if err != nil || len(bz) == 0 {
		return CircuitEpochInfo{}, false
	}
	var info CircuitEpochInfo
	if err := json.Unmarshal(bz, &info); err != nil {
		return CircuitEpochInfo{}, false
	}
	return info, true
}

func (k Keeper) setCircuitEpochInfo(ctx context.Context, info CircuitEpochInfo) {
	store := k.storeService.OpenKVStore(ctx)
	bz, err := json.Marshal(info)
	if err != nil {
		return
	}
	_ = store.Set(types.CircuitEpochInfoPrefix, bz)
}

// TickCircuitEpoch mirrors x/epochs BeginBlocker: first block whose time is past
// start+duration is the end. AfterEpochEnd settles the val pool. Empty identifier
// keeps the legacy every-block equal split.
func (k Keeper) TickCircuitEpoch(ctx context.Context) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	ident := types.CircuitDistrEpochDay
	info, ok := k.getCircuitEpochInfo(ctx)
	if !ok {
		now := sdkCtx.BlockTime().Unix()
		if now < 0 {
			now = 0
		}
		dur := types.CircuitEpochDurationDefault
		if s := os.Getenv("CIRCUIT_EPOCH_DURATION_SECONDS"); s != "" {
			if n, err := strconv.ParseInt(s, 10, 64); err == nil && n > 0 {
				dur = n
			}
		}
		k.setCircuitEpochInfo(ctx, CircuitEpochInfo{
			Identifier:              ident,
			DurationSeconds:         dur,
			CurrentEpoch:            0,
			CurrentEpochStartUnix:   now,
			CurrentEpochStartHeight: sdkCtx.BlockHeight(),
		})
		return
	}
	if info.Identifier == "" {
		k.DistributeCircuitValPool(ctx)
		return
	}
	if info.DurationSeconds <= 0 {
		info.DurationSeconds = types.CircuitEpochDurationDefault
	}
	now := sdkCtx.BlockTime().Unix()
	if now < info.CurrentEpochStartUnix+info.DurationSeconds {
		return
	}
	k.AfterEpochEnd(ctx, info.Identifier, info.CurrentEpoch)
	info.CurrentEpoch++
	info.CurrentEpochStartUnix = now
	info.CurrentEpochStartHeight = sdkCtx.BlockHeight()
	k.setCircuitEpochInfo(ctx, info)
}

// AfterEpochEnd is the Osmosis hook shape. Only the circuit day identifier settles.
func (k Keeper) AfterEpochEnd(ctx context.Context, epochIdentifier string, epochNumber int64) {
	if epochIdentifier != types.CircuitDistrEpochDay {
		return
	}
	k.settleCircuitValPool(ctx, epochIdentifier, epochNumber)
}

// DistributeCircuitValPool is the legacy every-block equal split (identifier empty).
func (k Keeper) DistributeCircuitValPool(ctx context.Context) {
	k.settleCircuitValPool(ctx, "", 0)
}

func (k Keeper) operatorWeight(ctx context.Context, v stakingtypes.Validator) int64 {
	if v.Jailed {
		return 0
	}
	if k.circuitWeight != nil {
		return k.circuitWeight(ctx, v)
	}
	return 1
}

func (k Keeper) settleCircuitValPool(ctx context.Context, epochIdentifier string, epochNumber int64) {
	if k.stakingKeeper == nil {
		return
	}
	vals, err := k.stakingKeeper.GetBondedValidatorsByPower(ctx)
	if err != nil || len(vals) == 0 {
		return
	}
	poolAddr := authtypes.NewModuleAddress(types.CircuitValPoolName)
	bal := k.bankKeeper.GetAllBalances(ctx, poolAddr)
	if bal.Empty() {
		return
	}

	weights := make([]int64, len(vals))
	var weightSum int64
	for i, v := range vals {
		w := k.operatorWeight(ctx, v)
		if w < 0 {
			w = 0
		}
		weights[i] = w
		weightSum += w
	}
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	if weightSum == 0 {
		sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
			"circuit_val_pool_payout",
			sdk.NewAttribute("epoch_identifier", epochIdentifier),
			sdk.NewAttribute("epoch_number", strconv.FormatInt(epochNumber, 10)),
			sdk.NewAttribute("eligible", "0"),
			sdk.NewAttribute("weight_sum", "0"),
			sdk.NewAttribute("paid", "0"),
		))
		return
	}

	paid := sdk.NewCoins()
	eligible := 0
	for i, v := range vals {
		if weights[i] == 0 {
			continue
		}
		eligible++
		op, err := sdk.ValAddressFromBech32(v.OperatorAddress)
		if err != nil {
			continue
		}
		share := sdk.NewCoins()
		for _, c := range bal {
			each := c.Amount.MulRaw(weights[i]).QuoRaw(weightSum)
			if each.IsPositive() {
				share = share.Add(sdk.NewCoin(c.Denom, each))
			}
		}
		if share.Empty() {
			continue
		}
		if err := k.bankKeeper.SendCoinsFromModuleToAccount(ctx, types.CircuitValPoolName, sdk.AccAddress(op), share); err != nil {
			sdkCtx.Logger().Debug("circuit val pool payout", "err", err)
			continue
		}
		paid = paid.Add(share...)
	}
	if !paid.Empty() || eligible > 0 {
		sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
			"circuit_val_pool_payout",
			sdk.NewAttribute("epoch_identifier", epochIdentifier),
			sdk.NewAttribute("epoch_number", strconv.FormatInt(epochNumber, 10)),
			sdk.NewAttribute("eligible", strconv.Itoa(eligible)),
			sdk.NewAttribute("weight_sum", strconv.FormatInt(weightSum, 10)),
			sdk.NewAttribute("paid", paid.String()),
		))
	}
}
