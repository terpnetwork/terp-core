package v6_1

import (
	"bytes"
	"testing"

	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	"github.com/cosmos/cosmos-sdk/testutil"
	"github.com/stretchr/testify/require"

	"github.com/terpnetwork/terp-core/v6/app/iavlhash"
)

func commitKV(t *testing.T, ms storetypes.MultiStore, key storetypes.StoreKey) storetypes.CommitKVStore {
	t.Helper()
	st := ms.GetStore(key)
	require.NotNil(t, st, key.Name())
	ckv, ok := st.(storetypes.CommitKVStore)
	require.True(t, ok, "%s is not CommitKVStore", key.Name())
	return ckv
}

func TestCopyKVStoreCommitHashesSoundAndUnsound(t *testing.T) {
	srcKey := storetypes.NewKVStoreKey("bank")
	dstKey := storetypes.NewKVStoreKey(iavlhash.BankB3)
	ibcKey := storetypes.NewKVStoreKey("ibc")
	ctx := testutil.DefaultContextWithKeys(
		map[string]*storetypes.KVStoreKey{
			"bank":          srcKey,
			iavlhash.BankB3: dstKey,
			"ibc":           ibcKey,
		},
		nil,
		nil,
	)

	ctx.KVStore(srcKey).Set([]byte("a"), []byte("1"))
	ctx.KVStore(srcKey).Set([]byte("b"), []byte("2"))
	ctx.KVStore(ibcKey).Set([]byte("client"), []byte("07-tendermint"))

	ms := ctx.MultiStore()
	srcC := commitKV(t, ms, srcKey)
	dstC := commitKV(t, ms, dstKey)
	ibcC := commitKV(t, ms, ibcKey)

	srcWorking := append([]byte(nil), srcC.WorkingHash()...)
	dstWorkingBefore := append([]byte(nil), dstC.WorkingHash()...)
	ibcWorkingBefore := append([]byte(nil), ibcC.WorkingHash()...)
	dstLastBefore := dstC.LastCommitID()

	n, err := copyKVStore(ctx, srcKey, dstKey)
	require.NoError(t, err)
	require.Equal(t, 2, n)
	require.Equal(t, []byte("1"), ctx.KVStore(dstKey).Get([]byte("a")))
	require.Equal(t, []byte("2"), ctx.KVStore(dstKey).Get([]byte("b")))

	dstWorking := dstC.WorkingHash()
	require.NotEmpty(t, dstWorking)
	require.False(t, bytes.Equal(dstWorking, dstWorkingBefore),
		"sound: dest working hash changes after copy")

	require.Equal(t, srcWorking, dstWorking,
		"sound: dest working hash matches src when both empty trees use SHA-256 and the same KV/versions")

	require.False(t, bytes.Equal(dstLastBefore.Hash, dstWorking),
		"unsound if dest LastCommitID (pre-copy) is used as the post-copy root")
	require.False(t, bytes.Equal(dstC.LastCommitID().Hash, dstWorking),
		"unsound if dest LastCommitID is used before Commit of the copied keys")

	require.Equal(t, ibcWorkingBefore, ibcC.WorkingHash(), "sound: IBC store hash untouched")

	committed := dstC.Commit()
	require.Equal(t, dstWorking, committed.Hash,
		"sound: after Commit, LastCommitID hash is the working hash we copied")
	require.Equal(t, committed.Hash, dstC.LastCommitID().Hash)
}

func TestRefuseIBCRehashPolicy(t *testing.T) {
	for _, name := range []string{"ibc", "transfer", "icahost", "icacontroller"} {
		require.Equal(t, "sha256", iavlhash.AlgorithmName(name), name)
	}
	for _, p := range iavlhash.DualStorePairs() {
		require.NotEqual(t, "sha256", iavlhash.AlgorithmName(p[0]), p[0])
	}
}
