package keeper

import (
	"context"
	"strconv"

	"github.com/cosmos/cosmos-sdk/runtime"
	"github.com/cosmos/cosmos-sdk/store/v2/prefix"
	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/CosmWasm/wasmd/x/wasm/types"
)

func (k Keeper) setCircuitDepositExpiry(ctx context.Context, until uint64, addr sdk.AccAddress) error {
	store := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CircuitDepositExpiryPrefix)
	store.Set(types.GetCircuitDepositExpiryKey(until, addr), []byte{1})
	return nil
}

func (k Keeper) deleteCircuitDepositExpiry(ctx context.Context, until uint64, addr sdk.AccAddress) {
	store := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CircuitDepositExpiryPrefix)
	store.Delete(types.GetCircuitDepositExpiryKey(until, addr))
}

func (k Keeper) setCircuitDepositGC(ctx context.Context, addr sdk.AccAddress) error {
	store := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CircuitDepositGCPrefix)
	store.Set(types.GetCircuitDepositGCKey(addr), []byte{1})
	return nil
}

func (k Keeper) deleteCircuitDepositGC(ctx context.Context, addr sdk.AccAddress) {
	store := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CircuitDepositGCPrefix)
	store.Delete(types.GetCircuitDepositGCKey(addr))
}

func (k Keeper) setCircuitCreatorIndex(ctx context.Context, creator sdk.AccAddress, zkID uint64) error {
	store := k.storeService.OpenKVStore(ctx)
	return store.Set(types.GetCircuitByCreatorIDKey(creator, zkID), []byte{1})
}

func (k Keeper) deleteCircuitCreatorIndex(ctx context.Context, creator sdk.AccAddress, zkID uint64) {
	store := k.storeService.OpenKVStore(ctx)
	_ = store.Delete(types.GetCircuitByCreatorIDKey(creator, zkID))
}

func (k Keeper) nowUnix(ctx context.Context) uint64 {
	now := sdk.UnwrapSDKContext(ctx).BlockTime().Unix()
	if now < 0 {
		return 0
	}
	return uint64(now)
}

// PruneExpiredCircuitDeposits drops expired depositee rows (timestamp index) and
// bounded-GCs their circuit blobs. Access checks stay lazy via HasCircuitDeposit.
func (k Keeper) PruneExpiredCircuitDeposits(ctx context.Context) {
	sdkCtx := sdk.UnwrapSDKContext(ctx)
	now := k.nowUnix(ctx)
	circuitsLeft := types.MaxCircuitDepositGCCircuits
	depositeesLeft := types.MaxCircuitDepositGCDepositees

	gcStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CircuitDepositGCPrefix)
	gcIter := gcStore.Iterator(nil, nil)
	var pending []sdk.AccAddress
	for ; gcIter.Valid() && depositeesLeft > 0 && circuitsLeft > 0; gcIter.Next() {
		addr, ok := types.ParseCircuitDepositGCKey(gcIter.Key())
		if !ok {
			continue
		}
		pending = append(pending, addr)
	}
	gcIter.Close()

	for _, addr := range pending {
		if depositeesLeft == 0 || circuitsLeft == 0 {
			return
		}
		n, more := k.pruneCreatorCircuits(ctx, addr, circuitsLeft)
		circuitsLeft -= n
		depositeesLeft--
		if more {
			_ = k.setCircuitDepositGC(ctx, addr)
		} else {
			k.deleteCircuitDepositGC(ctx, addr)
		}
		sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
			"prune_circuit_deposit",
			sdk.NewAttribute("payer", addr.String()),
			sdk.NewAttribute("circuits", strconv.FormatUint(uint64(n), 10)),
			sdk.NewAttribute("more", strconv.FormatBool(more)),
		))
	}

	expStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CircuitDepositExpiryPrefix)
	end := sdk.Uint64ToBigEndian(now + 1)
	expIter := expStore.Iterator(nil, end)
	type expHit struct {
		until uint64
		addr  sdk.AccAddress
	}
	var hits []expHit
	for ; expIter.Valid() && len(hits) < depositeesLeft; expIter.Next() {
		until, addr, ok := types.ParseCircuitDepositExpiryKey(expIter.Key())
		if !ok {
			continue
		}
		hits = append(hits, expHit{until: until, addr: addr})
	}
	expIter.Close()

	for _, h := range hits {
		if depositeesLeft == 0 || circuitsLeft == 0 {
			return
		}
		cur, err := k.circuitDepositees.Get(ctx, h.addr)
		if err != nil || cur != h.until {
			k.deleteCircuitDepositExpiry(ctx, h.until, h.addr)
			continue
		}
		if int64(cur) > int64(now) {
			k.deleteCircuitDepositExpiry(ctx, h.until, h.addr)
			continue
		}
		_ = k.circuitDepositees.Remove(ctx, h.addr)
		k.deleteCircuitDepositExpiry(ctx, h.until, h.addr)
		depositeesLeft--

		if k.getCircuitUploadAccessConfig(ctx).Allowed(h.addr) {
			k.deleteCircuitDepositGC(ctx, h.addr)
			continue
		}
		n, more := k.pruneCreatorCircuits(ctx, h.addr, circuitsLeft)
		circuitsLeft -= n
		if more {
			_ = k.setCircuitDepositGC(ctx, h.addr)
		} else {
			k.deleteCircuitDepositGC(ctx, h.addr)
		}
		sdkCtx.EventManager().EmitEvent(sdk.NewEvent(
			"prune_circuit_deposit",
			sdk.NewAttribute("payer", h.addr.String()),
			sdk.NewAttribute("circuits", strconv.FormatUint(uint64(n), 10)),
			sdk.NewAttribute("more", strconv.FormatBool(more)),
		))
	}
}

func (k Keeper) pruneCreatorCircuits(ctx context.Context, creator sdk.AccAddress, max int) (pruned int, more bool) {
	if max <= 0 {
		return 0, k.hasCircuitCreatorIndex(ctx, creator)
	}
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.GetCircuitByCreatorIDPrefix(creator))
	iter := prefixStore.Iterator(nil, nil)
	var ids []uint64
	for ; iter.Valid(); iter.Next() {
		key := iter.Key()
		if len(key) != 8 {
			continue
		}
		ids = append(ids, sdk.BigEndianToUint64(key))
		if len(ids) > max {
			more = true
			ids = ids[:max]
			break
		}
	}
	iter.Close()

	for _, zkID := range ids {
		if err := k.removeCircuit(ctx, zkID); err != nil {
			sdk.UnwrapSDKContext(ctx).Logger().Debug("prune circuit", "zk_id", zkID, "err", err)
			k.deleteCircuitCreatorIndex(ctx, creator, zkID)
		}
		pruned++
	}
	if !more {
		more = k.hasCircuitCreatorIndex(ctx, creator)
	}
	return pruned, more
}

func (k Keeper) hasExpiryIndex(ctx context.Context, until uint64, addr sdk.AccAddress) bool {
	store := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.CircuitDepositExpiryPrefix)
	return store.Has(types.GetCircuitDepositExpiryKey(until, addr))
}

func (k Keeper) hasCircuitCreatorIndex(ctx context.Context, creator sdk.AccAddress) bool {
	prefixStore := prefix.NewStore(runtime.KVStoreAdapter(k.storeService.OpenKVStore(ctx)), types.GetCircuitByCreatorIDPrefix(creator))
	iter := prefixStore.Iterator(nil, nil)
	defer iter.Close()
	return iter.Valid()
}
