package iavl

import (
	"bytes"
	"testing"

	"github.com/cosmos/iavl/hash"
	"github.com/stretchr/testify/require"

	dbm "github.com/cosmos/iavl/db"
)

func TestCopyRehashSHA256ToBLAKE3(t *testing.T) {
	src := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), SHA256Option())
	pairs := [][2][]byte{
		{[]byte("a"), []byte("1")},
		{[]byte("b"), []byte("2")},
		{[]byte("c"), []byte("3")},
	}
	for _, kv := range pairs {
		_, err := src.Set(kv[0], kv[1])
		require.NoError(t, err)
	}
	_, _, err := src.SaveVersion()
	require.NoError(t, err)

	dst := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), HasherOption(hash.NewBLAKE3Hasher()))
	require.NoError(t, CopyRehash(src, dst))

	require.Equal(t, src.Size(), dst.Size())
	require.NotEqual(t, src.Hash(), dst.Hash(), "rehash must change the merkle root")

	_, err = src.Iterate(func(k, v []byte) bool {
		got, err := dst.Get(k)
		require.NoError(t, err)
		require.True(t, bytes.Equal(v, got), "key %s", k)
		return false
	})
	require.NoError(t, err)
}

func TestCopyRehashRejectsNonEmptyDst(t *testing.T) {
	src := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), SHA256Option())
	_, err := src.Set([]byte("k"), []byte("v"))
	require.NoError(t, err)
	_, _, err = src.SaveVersion()
	require.NoError(t, err)

	dst := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), HasherOption(hash.NewBLAKE3Hasher()))
	_, err = dst.Set([]byte("x"), []byte("y"))
	require.NoError(t, err)

	require.Error(t, CopyRehash(src, dst))
}
