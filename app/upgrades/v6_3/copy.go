package v6_3

import (
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
)

func copyKVStore(ctx sdk.Context, srcKey, dstKey storetypes.StoreKey) (int, error) {
	n, _, err := syncKVStore(ctx, srcKey, dstKey)
	return n, err
}

// syncKVStore copies every src key into dest and deletes dest-only keys so the
// dest tree matches the last live commit (needed after EndBlock writes on the
// v6.3 apply height and the gap block before v6.4).
func syncKVStore(ctx sdk.Context, srcKey, dstKey storetypes.StoreKey) (set, deleted int, err error) {
	src := ctx.KVStore(srcKey)
	dst := ctx.KVStore(dstKey)
	live := map[string]struct{}{}
	it := src.Iterator(nil, nil)
	defer it.Close()
	for ; it.Valid(); it.Next() {
		dst.Set(it.Key(), it.Value())
		live[string(it.Key())] = struct{}{}
		set++
	}
	dit := dst.Iterator(nil, nil)
	var extra [][]byte
	for ; dit.Valid(); dit.Next() {
		if _, ok := live[string(dit.Key())]; !ok {
			extra = append(extra, append([]byte(nil), dit.Key()...))
		}
	}
	if err := dit.Close(); err != nil {
		return set, deleted, err
	}
	for _, k := range extra {
		dst.Delete(k)
		deleted++
	}
	return set, deleted, nil
}
