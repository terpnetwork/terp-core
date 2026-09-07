package keeper

import (
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v6/x/smart-account/types"
)

// HasModuleParams reports whether params were already written to the module store.
func (k Keeper) HasModuleParams(ctx sdk.Context) bool {
	return ctx.KVStore(k.storeKey).Get(types.ParamsKey) != nil
}

// GetParams get all parameters as types.Params
func (k Keeper) GetParams(ctx sdk.Context) (params types.Params) {
	store := ctx.KVStore(k.storeKey)
	bz := store.Get(types.ParamsKey)
	if bz == nil {
		return types.DefaultParams()
	}
	if err := k.cdc.Unmarshal(bz, &params); err != nil {
		k.Logger(ctx).Error("failed to unmarshal smart-account params", "error", err)
		return types.DefaultParams()
	}
	return params
}

// SetParams set the params
func (k Keeper) SetParams(ctx sdk.Context, params types.Params) {
	if err := params.Validate(); err != nil {
		panic(err)
	}
	bz, err := k.cdc.Marshal(&params)
	if err != nil {
		panic(err)
	}
	ctx.KVStore(k.storeKey).Set(types.ParamsKey, bz)
}

// GetIsSmartAccountActive returns the value of the isSmartAccountActive parameter.
func (k *Keeper) GetIsSmartAccountActive(ctx sdk.Context) bool {
	return k.GetParams(ctx).IsSmartAccountActive
}
