package keeper

import (
	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"

	storetypes "cosmossdk.io/store/types"
	"github.com/cosmos/cosmos-sdk/codec"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v4/x/clock/types"
)

// Keeper of the clock store
type Keeper struct {
	storeKey storetypes.StoreKey
	cdc      codec.BinaryCodec

	contractKeeper wasmkeeper.PermissionedKeeper

	authority string
}

func NewKeeper(
	key storetypes.StoreKey,
	cdc codec.BinaryCodec,
	contractKeeper wasmkeeper.PermissionedKeeper,
	authority string,
) Keeper {
	return Keeper{
		cdc:            cdc,
		storeKey:       key,
		contractKeeper: contractKeeper,
		authority:      authority,
	}
}

// GetAuthority returns the x/clock module's authority.
func (k Keeper) GetAuthority() string {
	return k.authority
}

// SetParams sets the x/clock module parameters.
func (k Keeper) SetParams(ctx sdk.Context, p types.Params) error {
	if err := p.Validate(); err != nil {
		return err
	}

	store := ctx.KVStore(k.storeKey)
	bz := k.cdc.MustMarshal(&p)
	store.Set(types.ParamsKey, bz)

	return nil
}

// GetParams returns the current x/clock module parameters.
func (k Keeper) GetParams(ctx sdk.Context) (p types.Params) {
	store := ctx.KVStore(k.storeKey)
	bz := store.Get(types.ParamsKey)
	if bz == nil {
		return p
	}

	k.cdc.MustUnmarshal(bz, &p)
	return p
}

// GetContractKeeper returns the x/wasm module's contract keeper.
func (k Keeper) GetContractKeeper() wasmkeeper.PermissionedKeeper {
	return k.contractKeeper
}
