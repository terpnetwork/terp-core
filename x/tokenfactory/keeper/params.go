package keeper

import (
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v6/x/tokenfactory/types"
)

// GetParams returns the total set params from the module store.
func (k Keeper) GetParams(ctx sdk.Context) (params types.Params) {
	store := ctx.KVStore(k.storeKey)
	bz := store.Get(types.ParamsKey)
	if bz == nil {
		return params
	}
	if err := params.Unmarshal(bz); err != nil {
		panic(err)
	}
	return params
}

// SetParams sets the total set of params in the module store.
func (k Keeper) SetParams(ctx sdk.Context, params types.Params) {
	if err := params.Validate(); err != nil {
		panic(err)
	}
	bz, err := params.Marshal()
	if err != nil {
		panic(err)
	}
	ctx.KVStore(k.storeKey).Set(types.ParamsKey, bz)
}
