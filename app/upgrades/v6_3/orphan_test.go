package v6_3

import (
	"fmt"
	"testing"

	"cosmossdk.io/log/v2"
	dbm "github.com/cosmos/cosmos-db"
	"github.com/cosmos/cosmos-sdk/store/v2/rootmulti"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	"github.com/cosmos/cosmos-sdk/store/v2/wrapper"
	gogotypes "github.com/cosmos/gogoproto/types"
	"github.com/cosmos/iavl"
	"github.com/stretchr/testify/require"

	terpiavl "github.com/terpnetwork/terp-core/v6/app/iavl"
	v64 "github.com/terpnetwork/terp-core/v6/app/upgrades/v6_4"
)

const (
	v61Height  = int64(23191300)
	haltHeight = int64(23893261)
)

// TestAddedDestRejectsV61HistoryUntilDropped reproduces the mainnet halt:
// b3-* bytes from v6.1 remain after v6.2 drops them from CommitInfo, and
// v6.3 Added sets initial version to the new halt.
func TestAddedDestRejectsV61HistoryUntilDropped(t *testing.T) {
	db := dbm.NewMemDB()
	logger := log.NewNopLogger()
	bank := storetypes.NewKVStoreKey("bank")

	rs := rootmulti.NewStore(db, logger)
	rs.MountStoreWithDB(bank, storetypes.StoreTypeIAVL, nil)
	require.NoError(t, rs.LoadLatestVersion())
	require.NoError(t, rs.SetInitialVersion(haltHeight-1))
	rs.GetKVStore(bank).Set([]byte("bal"), []byte("1"))
	got := rs.Commit()
	require.Equal(t, haltHeight-1, got.Version)

	plantOrphanDest(t, db, "b3-bank", uint64(v61Height))

	broken := rootmulti.NewStore(db, logger)
	broken.MountStoreWithDB(bank, storetypes.StoreTypeIAVL, nil)
	broken.MountStoreWithDB(storetypes.NewKVStoreKey("b3-bank"), storetypes.StoreTypeIAVL, nil)
	err := broken.LoadLatestVersionAndUpgrade(&storetypes.StoreUpgrades{Added: []string{"b3-bank"}})
	require.Error(t, err)
	require.Contains(t, err.Error(), "initial version set to 23893261, but found earlier version 23191300")

	dropped, err := DropOrphanDestStores(db)
	require.NoError(t, err)
	require.Greater(t, dropped["b3-bank"], 0)

	fixed := rootmulti.NewStore(db, logger)
	b3 := storetypes.NewKVStoreKey("b3-bank")
	fixed.MountStoreWithDB(bank, storetypes.StoreTypeIAVL, nil)
	fixed.MountStoreWithDB(b3, storetypes.StoreTypeIAVL, nil)
	require.NoError(t, fixed.LoadLatestVersionAndUpgrade(&storetypes.StoreUpgrades{
		Added: []string{"b3-bank"},
	}))
	fixed.GetKVStore(b3).Set([]byte("bal"), []byte("1"))
	got = fixed.Commit()
	require.Equal(t, haltHeight, got.Version)

	// v6.4 deletes the live SHA-256 name. It does not add b3-* again.
	next := rootmulti.NewStore(db, logger)
	next.MountStoreWithDB(bank, storetypes.StoreTypeIAVL, nil)
	next.MountStoreWithDB(b3, storetypes.StoreTypeIAVL, nil)
	require.NoError(t, next.LoadLatestVersionAndUpgrade(&storetypes.StoreUpgrades{
		Deleted: terpiavl.MigratableStores(),
	}))
	require.Equal(t, []byte("1"), next.GetKVStore(b3).Get([]byte("bal")))
	require.Nil(t, next.GetKVStore(bank).Get([]byte("bal")))

	// The committed dest tree must survive a second pass of the drop.
	again, err := DropOrphanDestStores(db)
	require.NoError(t, err)
	require.Zero(t, again["b3-bank"])
	require.Equal(t, []byte("1"), next.GetKVStore(b3).Get([]byte("bal")))
}

func TestV64StoreUpgradesLeaveDestTrees(t *testing.T) {
	require.Empty(t, v64.Upgrade.StoreUpgrades.Added)
	require.Empty(t, v64.Upgrade.StoreUpgrades.Renamed)
	require.Equal(t, terpiavl.MigratableStores(), v64.Upgrade.StoreUpgrades.Deleted)
	for _, name := range terpiavl.DestStores() {
		require.NotContains(t, v64.Upgrade.StoreUpgrades.Deleted, name)
	}
}

func plantOrphanDest(t *testing.T, db dbm.DB, name string, initial uint64) {
	t.Helper()
	tree := iavl.NewMutableTree(
		wrapper.NewDBWrapper(dbm.NewPrefixDB(db, []byte("s/k:"+name+"/"))),
		0, false, log.NewNopLogger(),
		iavl.InitialVersionOption(initial),
		iavl.HasherOptionForStore(name),
	)
	_, err := tree.Set([]byte("old"), []byte("from-v6.1"))
	require.NoError(t, err)
	_, ver, err := tree.SaveVersion()
	require.NoError(t, err)
	require.Equal(t, int64(initial), ver)
}

func TestDropSkipsDestNamedInCommitInfo(t *testing.T) {
	db := dbm.NewMemDB()
	info := &storetypes.CommitInfo{
		Version:    10,
		StoreInfos: []storetypes.StoreInfo{{Name: "b3-bank"}},
	}
	bz, err := info.Marshal()
	require.NoError(t, err)
	latest, err := gogotypes.StdInt64Marshal(10)
	require.NoError(t, err)
	require.NoError(t, db.Set([]byte(fmt.Sprintf("s/%d", 10)), bz))
	require.NoError(t, db.Set([]byte("s/latest"), latest))
	require.NoError(t, db.Set([]byte("s/k:b3-bank/keep"), []byte("x")))

	dropped, err := DropOrphanDestStores(db)
	require.NoError(t, err)
	require.Zero(t, dropped["b3-bank"])
	got, err := db.Get([]byte("s/k:b3-bank/keep"))
	require.NoError(t, err)
	require.Equal(t, []byte("x"), got)
}
