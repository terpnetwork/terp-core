package iavlv2

import (
	"testing"

	iavl "github.com/cosmos/iavl/v2"
	"github.com/stretchr/testify/require"
)

func TestOpenTreeSetSaveVersion(t *testing.T) {
	dir := t.TempDir()
	tree, err := OpenTree(dir)
	require.NoError(t, err)
	t.Cleanup(func() {
		require.NoError(t, tree.Close())
	})

	updated, err := tree.Set([]byte("a"), []byte("b"))
	require.NoError(t, err)
	require.False(t, updated)

	hash, version, err := tree.SaveVersion()
	require.NoError(t, err)
	require.Equal(t, int64(1), version)
	require.NotEmpty(t, hash)
	require.Equal(t, hash, tree.Hash())
	require.Equal(t, int64(1), tree.Version())

	got, err := tree.Get([]byte("a"))
	require.NoError(t, err)
	require.Equal(t, []byte("b"), got)
}

func TestOpenTreeBlake3DiffersFromSHA256(t *testing.T) {
	sha, err := OpenTree(t.TempDir())
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, sha.Close()) })

	b3opts := iavl.DefaultTreeOptions()
	b3opts.UseBlake3 = true
	b3, err := OpenTreeWithOptions(t.TempDir(), b3opts)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, b3.Close()) })

	_, err = sha.Set([]byte("a"), []byte("b"))
	require.NoError(t, err)
	_, err = b3.Set([]byte("a"), []byte("b"))
	require.NoError(t, err)

	hSHA, _, err := sha.SaveVersion()
	require.NoError(t, err)
	hB3, _, err := b3.SaveVersion()
	require.NoError(t, err)
	require.NotEqual(t, hSHA, hB3)
}

func TestIngestSameKVHashesDifferByAlgo(t *testing.T) {
	kvs := [][2][]byte{{[]byte("bank/a"), []byte("1")}, {[]byte("bank/b"), []byte("2")}}
	hSHA, err := Ingest(t.TempDir(), kvs, false)
	require.NoError(t, err)
	hB3, err := Ingest(t.TempDir(), kvs, true)
	require.NoError(t, err)
	hB3b, err := Ingest(t.TempDir(), kvs, true)
	require.NoError(t, err)
	require.NotEqual(t, hSHA, hB3, "unsound if SHA-256 root equals BLAKE3 root")
	require.Equal(t, hB3, hB3b, "sound: same KV + BLAKE3 is deterministic")
}

func TestOpenMultiTreeSetSaveVersion(t *testing.T) {
	root := t.TempDir()
	mt, err := OpenMultiTree(root, []string{"bank"})
	require.NoError(t, err)
	t.Cleanup(func() {
		require.NoError(t, mt.Close())
	})

	tree := mt.Trees["bank"]
	require.NotNil(t, tree)
	_, err = tree.Set([]byte("k"), []byte("v"))
	require.NoError(t, err)

	hash, version, err := mt.SaveVersion()
	require.NoError(t, err)
	require.Equal(t, int64(1), version)
	require.NotEmpty(t, hash)

	got, err := tree.Get([]byte("k"))
	require.NoError(t, err)
	require.Equal(t, []byte("v"), got)
}
