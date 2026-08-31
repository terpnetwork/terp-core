package iavlv2

import (
	"testing"

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
