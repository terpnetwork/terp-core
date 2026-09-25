package iavlhash

import (
	"testing"

	"github.com/cosmos/iavl"
	dbm "github.com/cosmos/iavl/db"
	ics23 "github.com/cosmos/ics23/go"
	"github.com/stretchr/testify/require"
)

func treeWithKV(t *testing.T, storeName string, key, value []byte) *iavl.MutableTree {
	t.Helper()
	tree := iavl.NewMutableTree(dbm.NewMemDB(), 0, false, iavl.NewNopLogger(), iavl.HasherOptionForStore(storeName))
	_, err := tree.Set(key, value)
	require.NoError(t, err)
	_, _, err = tree.SaveVersion()
	require.NoError(t, err)
	return tree
}

func TestV63MembershipProofsExclusive(t *testing.T) {
	iavl.SetHasherMode(iavl.HasherModeV63)
	t.Cleanup(func() { iavl.SetHasherMode(iavl.HasherModeV63) })

	key, val := []byte("k"), []byte("v")
	live := treeWithKV(t, "bank", key, val)
	dest := treeWithKV(t, "b3-bank", key, val)
	ibc := treeWithKV(t, "ibc", key, val)

	require.Equal(t, "sha256", AlgorithmName("bank"))
	require.Equal(t, "blake3", AlgorithmName("b3-bank"))
	require.Equal(t, "sha256", AlgorithmName("ibc"))

	require.NotEqual(t, live.Hash(), dest.Hash(), "same KV SHA-256 vs BLAKE3 must differ")
	require.Equal(t, live.Hash(), ibc.Hash(), "live bank and ibc are both SHA-256 with the same KV")

	pdest, err := dest.GetMembershipProof(key)
	require.NoError(t, err)
	hop, err := ProofHashOp(pdest)
	require.NoError(t, err)
	require.Equal(t, ics23.HashOp_BLAKE3, hop)
	require.NoError(t, VerifyExclusive("b3-bank", dest.Hash(), pdest, key, val))

	pibc, err := ibc.GetMembershipProof(key)
	require.NoError(t, err)
	hop, err = ProofHashOp(pibc)
	require.NoError(t, err)
	require.Equal(t, ics23.HashOp_SHA256, hop)
	require.NoError(t, VerifyExclusive("ibc", ibc.Hash(), pibc, key, val))

	plive, err := live.GetMembershipProof(key)
	require.NoError(t, err)
	hop, err = ProofHashOp(plive)
	require.NoError(t, err)
	require.Equal(t, ics23.HashOp_SHA256, hop)
	require.NoError(t, VerifyExclusive("bank", live.Hash(), plive, key, val))
}

func TestSpecForStore(t *testing.T) {
	require.Equal(t, ics23.Blake3IavlSpec, SpecForStore("b3-bank"))
	require.Equal(t, ics23.IavlSpec, SpecForStore("bank"))
	require.Equal(t, ics23.IavlSpec, SpecForStore("ibc"))
	require.Equal(t, ics23.IavlSpec, SpecForStore("08-wasm"))
	require.True(t, IsIBCStore("ibc"))
	require.False(t, IsIBCStore("bank"))
}
