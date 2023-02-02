package keeper

import (
	"encoding/binary"

	"github.com/terpnetwork/terp-core/x/terp/types"
	"github.com/cosmos/cosmos-sdk/store/prefix"
	sdk "github.com/cosmos/cosmos-sdk/types"
)

// GetTerpidCount get the total number of terpid
func (k Keeper) GetTerpidCount(ctx sdk.Context) uint64 {
	store := prefix.NewStore(ctx.KVStore(k.storeKey), []byte{})
	byteKey := types.KeyPrefix(types.TerpidCountKey)
	bz := store.Get(byteKey)

	// Count doesn't exist: no element
	if bz == nil {
		return 0
	}

	// Parse bytes
	return binary.BigEndian.Uint64(bz)
}

// SetTerpidCount set the total number of terpid
func (k Keeper) SetTerpidCount(ctx sdk.Context, count uint64) {
	store := prefix.NewStore(ctx.KVStore(k.storeKey), []byte{})
	byteKey := types.KeyPrefix(types.TerpidCountKey)
	bz := make([]byte, 8)
	binary.BigEndian.PutUint64(bz, count)
	store.Set(byteKey, bz)
}

// AppendTerpid appends a terpid in the store with a new id and update the count
func (k Keeper) AppendTerpid(
	ctx sdk.Context,
	terpid types.Terpid,
) uint64 {
	// Create the terpid
	count := k.GetTerpidCount(ctx)

	// Set the ID of the appended value
	terpid.Id = count

	store := prefix.NewStore(ctx.KVStore(k.storeKey), types.KeyPrefix(types.TerpidKey))
	appendedValue := k.cdc.MustMarshal(&terpid)
	store.Set(GetTerpidIDBytes(terpid.Id), appendedValue)

	// Update terpid count
	k.SetTerpidCount(ctx, count+1)

	return count
}

// SetTerpid set a specific terpid in the store
func (k Keeper) SetTerpid(ctx sdk.Context, terpid types.Terpid) {
	store := prefix.NewStore(ctx.KVStore(k.storeKey), types.KeyPrefix(types.TerpidKey))
	b := k.cdc.MustMarshal(&terpid)
	store.Set(GetTerpidIDBytes(terpid.Id), b)
}

// GetTerpid returns a terpid from its id
func (k Keeper) GetTerpid(ctx sdk.Context, id uint64) (val types.Terpid, found bool) {
	store := prefix.NewStore(ctx.KVStore(k.storeKey), types.KeyPrefix(types.TerpidKey))
	b := store.Get(GetTerpidIDBytes(id))
	if b == nil {
		return val, false
	}
	k.cdc.MustUnmarshal(b, &val)
	return val, true
}

// RemoveTerpid removes a terpid from the store
func (k Keeper) RemoveTerpid(ctx sdk.Context, id uint64) {
	store := prefix.NewStore(ctx.KVStore(k.storeKey), types.KeyPrefix(types.TerpidKey))
	store.Delete(GetTerpidIDBytes(id))
}

// GetAllTerpid returns all terpid
func (k Keeper) GetAllTerpid(ctx sdk.Context) (list []types.Terpid) {
	store := prefix.NewStore(ctx.KVStore(k.storeKey), types.KeyPrefix(types.TerpidKey))
	iterator := sdk.KVStorePrefixIterator(store, []byte{})

	defer iterator.Close()

	for ; iterator.Valid(); iterator.Next() {
		var val types.Terpid
		k.cdc.MustUnmarshal(iterator.Value(), &val)
		list = append(list, val)
	}

	return
}

// GetTerpidIDBytes returns the byte representation of the ID
func GetTerpidIDBytes(id uint64) []byte {
	bz := make([]byte, 8)
	binary.BigEndian.PutUint64(bz, id)
	return bz
}

// GetTerpidIDFromBytes returns ID in uint64 format from a byte array
func GetTerpidIDFromBytes(bz []byte) uint64 {
	return binary.BigEndian.Uint64(bz)
}
