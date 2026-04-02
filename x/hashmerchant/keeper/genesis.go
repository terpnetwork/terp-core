package keeper

import (
	storetypes "cosmossdk.io/store/types"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/terpnetwork/terp-core/v5/x/hashmerchant/types"
)

// InitGenesis sets the module state from genesis.
func (k Keeper) InitGenesis(ctx sdk.Context, gs types.GenesisState) {
	if err := k.SetParams(ctx, gs.Params); err != nil {
		panic(err)
	}
	for _, c := range gs.RegisteredChains {
		if err := k.SetRegisteredChain(ctx, c); err != nil {
			panic(err)
		}
	}
	for _, c := range gs.RegisteredContracts {
		if err := k.SetRegisteredContract(ctx, c); err != nil {
			panic(err)
		}
	}
	for _, e := range gs.EscrowRecords {
		if err := k.SetEscrowRecord(ctx, e); err != nil {
			panic(err)
		}
	}
	for _, r := range gs.HashRoots {
		if err := k.SetHashRoot(ctx, r); err != nil {
			panic(err)
		}
	}
	k.SetPruneEpoch(ctx, gs.PruneEpoch)
	k.CreateModuleAccount(ctx)
}

// ExportGenesis exports the current module state.
func (k Keeper) ExportGenesis(ctx sdk.Context) *types.GenesisState {
	params, _ := k.GetParams(ctx)
	gs := &types.GenesisState{
		Params:     params,
		PruneEpoch: k.GetPruneEpoch(ctx),
	}

	k.IterateRegisteredChains(ctx, func(c types.RegisteredChain) bool {
		gs.RegisteredChains = append(gs.RegisteredChains, c)
		return false
	})
	k.IterateRegisteredContracts(ctx, func(c types.RegisteredContract) bool {
		gs.RegisteredContracts = append(gs.RegisteredContracts, c)
		return false
	})
	k.IterateEscrowRecords(ctx, func(e types.EscrowRecord) bool {
		gs.EscrowRecords = append(gs.EscrowRecords, e)
		return false
	})
	// Export all hash roots across all chains — iterate the whole prefix.
	k.iterateAllHashRoots(ctx, func(r types.HashRoot) bool {
		gs.HashRoots = append(gs.HashRoots, r)
		return false
	})
	return gs
}

// iterateAllHashRoots walks the entire 0x04 prefix (all chains/algos).
func (k Keeper) iterateAllHashRoots(ctx sdk.Context, cb func(types.HashRoot) bool) {
	store := ctx.KVStore(k.storeKey)
	iter := storetypesIterator(store, types.KeyPrefixHashRoots)
	defer iter.Close()
	for ; iter.Valid(); iter.Next() {
		var r types.HashRoot
		if err := k.cdc.Unmarshal(iter.Value(), &r); err != nil {
			continue
		}
		if cb(r) {
			break
		}
	}
}

// storetypesIterator returns a prefix iterator.
func storetypesIterator(store storetypes.KVStore, pfx []byte) storetypes.Iterator {
	end := make([]byte, len(pfx))
	copy(end, pfx)
	end[len(end)-1]++
	return store.Iterator(pfx, end)
}
