package keeper

import (
	"context"
	"fmt"

	"github.com/cosmos/cosmos-sdk/store/v2/prefix"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"

	"github.com/cosmos/cosmos-sdk/runtime"
	sdk "github.com/cosmos/cosmos-sdk/types"
)

func (k Keeper) SetContract(ctx context.Context, keyPrefix []byte, contractAddr sdk.AccAddress) {
	store := runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx))
	loadedPrefix := prefix.NewStore(store, keyPrefix)
	loadedPrefix.Set(contractAddr.Bytes(), []byte{})
}

func (k Keeper) IsContractRegistered(ctx context.Context, keyPrefix []byte, contractAddr sdk.AccAddress) bool {
	store := runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx))
	loadedPrefix := prefix.NewStore(store, keyPrefix)
	return loadedPrefix.Has(contractAddr.Bytes())
}

func (k Keeper) IterateContracts(
	ctx context.Context,
	keyPrefix []byte,
	handlerFn func(contractAddr []byte) (stop bool),
) {
	store := runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx))
	iterator := storetypes.KVStorePrefixIterator(store, keyPrefix)
	defer iterator.Close() //nolint:errcheck

	for ; iterator.Valid(); iterator.Next() {
		keyAddr := iterator.Key()[len(keyPrefix):]
		addr := sdk.AccAddress(keyAddr)

		if handlerFn(addr) {
			break
		}
	}
}

func (k Keeper) GetAllContracts(ctx context.Context, keyPrefix []byte) (list []sdk.Address) {
	k.IterateContracts(ctx, keyPrefix, func(addr []byte) bool {
		list = append(list, sdk.AccAddress(addr))
		return false
	})
	return list
}

func (k Keeper) GetAllContractsBech32(ctx context.Context, keyPrefix []byte) []string {
	contracts := k.GetAllContracts(ctx, keyPrefix)

	list := make([]string, 0, len(contracts))
	for _, c := range contracts {
		list = append(list, c.String())
	}
	return list
}

func (k Keeper) DeleteContract(ctx context.Context, keyPrefix []byte, contractAddr sdk.AccAddress) {
	store := runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx))
	loadedPrefix := prefix.NewStore(store, keyPrefix)
	loadedPrefix.Delete(contractAddr)
}

// ExecuteMessageOnContracts sudoes each registered contract on an isolated cache
// and gas meter. Inner OOG and sudo errors are logged and skipped so staking/gov
// hooks cannot abort DeliverTx. Spent gas is billed to the parent meter; parent
// OOG is not recovered. Uses existing ContractGasLimit (no param change).
func (k Keeper) ExecuteMessageOnContracts(ctx context.Context, keyPrefix []byte, msgBz []byte) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	limit := k.GetParams(ctx).ContractGasLimit

	for _, c := range k.GetAllContracts(ctx, keyPrefix) {
		k.sudoContract(sdkCtx, sdk.AccAddress(c.Bytes()), msgBz, limit)
	}

	return nil
}

// sudoContract runs wasm sudo on a cache ctx with a finite SDK gas meter.
func (k Keeper) sudoContract(sdkCtx sdk.Context, addr sdk.AccAddress, msgBz []byte, limit uint64) {
	cache, write := sdkCtx.CacheContext()
	metered := cache.WithGasMeter(storetypes.NewGasMeter(limit))

	err := func() (err error) {
		defer func() {
			if r := recover(); r != nil {
				if _, ok := r.(storetypes.ErrorOutOfGas); ok {
					err = fmt.Errorf("sudo gas limit %d exceeded", limit)
					return
				}
				panic(r)
			}
		}()
		_, err = k.GetContractKeeper().Sudo(metered, addr, msgBz)
		return err
	}()

	spent := metered.GasMeter().GasConsumed()
	if spent > limit {
		spent = limit
	}
	if err != nil {
		k.Logger(sdkCtx).Error("ExecuteMessageOnContracts err", "err", err, "contract", addr.String())
	} else {
		write()
	}
	sdkCtx.GasMeter().ConsumeGas(spent, "cw-hooks sudo")
}
