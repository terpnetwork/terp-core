package v6_3

import (
	"testing"

	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	"github.com/cosmos/cosmos-sdk/testutil"
	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
	"github.com/terpnetwork/terp-core/v6/app/keepers"
)

func TestCopyKVStoreMatchesAndLeavesIBC(t *testing.T) {
	srcKey := storetypes.NewKVStoreKey("bank")
	dstKey := storetypes.NewKVStoreKey(iavl.BankB3)
	ibcKey := storetypes.NewKVStoreKey("ibc")
	ctx := testutil.DefaultContextWithKeys(
		map[string]*storetypes.KVStoreKey{
			"bank":      srcKey,
			iavl.BankB3: dstKey,
			"ibc":       ibcKey,
		},
		nil,
		nil,
	)
	ctx.KVStore(srcKey).Set([]byte("a"), []byte("1"))
	ctx.KVStore(srcKey).Set([]byte("b"), []byte("2"))
	ctx.KVStore(ibcKey).Set([]byte("client"), []byte("07-tendermint"))

	n, err := copyKVStore(ctx, srcKey, dstKey)
	require.NoError(t, err)
	require.Equal(t, 2, n)
	require.Equal(t, []byte("1"), ctx.KVStore(dstKey).Get([]byte("a")))
	require.Equal(t, []byte("2"), ctx.KVStore(dstKey).Get([]byte("b")))
	require.Equal(t, []byte("07-tendermint"), ctx.KVStore(ibcKey).Get([]byte("client")))
	require.Nil(t, ctx.KVStore(dstKey).Get([]byte("client")))
}

func TestSyncKVStoreDeletesDestOnly(t *testing.T) {
	srcKey := storetypes.NewKVStoreKey("bank")
	dstKey := storetypes.NewKVStoreKey(iavl.BankB3)
	ctx := testutil.DefaultContextWithKeys(
		map[string]*storetypes.KVStoreKey{
			"bank":      srcKey,
			iavl.BankB3: dstKey,
		},
		nil,
		nil,
	)
	ctx.KVStore(srcKey).Set([]byte("keep"), []byte("1"))
	ctx.KVStore(dstKey).Set([]byte("keep"), []byte("old"))
	ctx.KVStore(dstKey).Set([]byte("orphan"), []byte("stale"))

	set, del, err := syncKVStore(ctx, srcKey, dstKey)
	require.NoError(t, err)
	require.Equal(t, 1, set)
	require.Equal(t, 1, del)
	require.Equal(t, []byte("1"), ctx.KVStore(dstKey).Get([]byte("keep")))
	require.Nil(t, ctx.KVStore(dstKey).Get([]byte("orphan")))
}

func TestRefuseIBCRehashPolicy(t *testing.T) {
	require.Empty(t, Upgrade.StoreUpgrades.Renamed)
	require.Empty(t, Upgrade.StoreUpgrades.Deleted)
	require.Equal(t, iavl.DestStores(), Upgrade.StoreUpgrades.Added)
	require.Equal(t, "v6.3", UpgradeName)
	require.Equal(t, "v6.4", NextUpgradeName)
	require.Equal(t, int64(2), NextUpgradeGap)

	for _, name := range []string{"ibc", "transfer", "icahost", "icacontroller", "08-wasm", "hooks-for-ibc"} {
		require.True(t, iavl.IsIBCStore(name), name)
	}
	for _, p := range iavl.DualStorePairs() {
		require.False(t, iavl.IsIBCStore(p[0]), p[0])
		require.NotEqual(t, "08-wasm", p[0])
		require.NotEqual(t, "params", p[0])
	}
}

func TestDestMountedOnV63Layout(t *testing.T) {
	if !keepers.MountDestStores || keepers.KeepersOnDest {
		t.Skip("v6.3 ELF mounts dest and keeps live names")
	}
	var k keepers.AppKeepers
	k.GenerateKeys()
	require.NotNil(t, k.GetKey("bank"))
	require.NotNil(t, k.GetKey(iavl.BankB3))
	require.NotNil(t, k.GetKey("ibc"))
	require.Nil(t, k.GetKey("b3-ibc"))
}
