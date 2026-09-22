package iavl

import (
	"encoding/hex"
	"testing"

	"github.com/cosmos/iavl/hash"
	ics23 "github.com/cosmos/ics23/go"
	"github.com/stretchr/testify/require"

	dbm "github.com/cosmos/iavl/db"
)

func TestIsSHA256Store(t *testing.T) {
	require.True(t, IsSHA256Store("ibc"))
	require.True(t, IsSHA256Store("transfer"))
	require.True(t, IsSHA256Store("icahost"))
	require.False(t, IsSHA256Store("bank"))
	require.False(t, IsSHA256Store("staking"))
	require.False(t, IsSHA256Store("wasm"))
	require.False(t, IsSHA256Store("acc"))
}

func TestHasherForStore(t *testing.T) {
	require.Nil(t, HasherForStore("ibc"))
	require.Nil(t, HasherForStore("transfer"))
	require.Nil(t, HasherForStore("bank"), "v6.3 live bank stays SHA-256")

	h := HasherForStore("b3-bank")
	require.NotNil(t, h)
	require.Equal(t, hash.BLAKE3, h.Algorithm())
}

func TestStoreHashAlgorithm(t *testing.T) {
	require.Equal(t, hash.SHA256, StoreHashAlgorithm("ibc"))
	require.Equal(t, hash.SHA256, StoreHashAlgorithm("bank"))
	require.Equal(t, hash.BLAKE3, StoreHashAlgorithm("b3-bank"))
}

func TestHasherModeFullAndSHA256(t *testing.T) {
	t.Cleanup(func() { SetHasherMode(HasherModeV63) })

	SetHasherMode(HasherModeBLAKE3)
	require.Equal(t, hash.BLAKE3, StoreHashAlgorithm("ibc"))
	require.Equal(t, hash.BLAKE3, StoreHashAlgorithm("bank"))

	SetHasherMode(HasherModeSHA256)
	require.Equal(t, hash.SHA256, StoreHashAlgorithm("ibc"))
	require.Equal(t, hash.SHA256, StoreHashAlgorithm("bank"))

	SetHasherMode(HasherModeHybrid)
	require.Equal(t, hash.SHA256, StoreHashAlgorithm("ibc"))
	require.Equal(t, hash.BLAKE3, StoreHashAlgorithm("bank"))
	require.True(t, IsSHA256Store("08-wasm"))
}

func TestIcs23ProofUsesTreeHasher(t *testing.T) {
	t.Cleanup(func() { SetHasherMode(HasherModeV63) })
	SetHasherMode(HasherModeHybrid)
	bank := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), HasherOptionForStore("bank"))
	_, err := bank.Set([]byte("k"), []byte("v"))
	require.NoError(t, err)
	_, _, err = bank.SaveVersion()
	require.NoError(t, err)
	p, err := bank.GetMembershipProof([]byte("k"))
	require.NoError(t, err)
	exist := p.GetExist()
	require.NotNil(t, exist)
	require.Equal(t, ics23.HashOp_BLAKE3, exist.Leaf.Hash)

	ibc := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), HasherOptionForStore("ibc"))
	_, err = ibc.Set([]byte("k"), []byte("v"))
	require.NoError(t, err)
	_, _, err = ibc.SaveVersion()
	require.NoError(t, err)
	p2, err := ibc.GetMembershipProof([]byte("k"))
	require.NoError(t, err)
	require.Equal(t, ics23.HashOp_SHA256, p2.GetExist().Leaf.Hash)
}

func TestV63DestBankProofRejectsSHA256(t *testing.T) {
	t.Cleanup(func() { SetHasherMode(HasherModeV63) })
	SetHasherMode(HasherModeV63)

	key, val := []byte("k"), []byte("v")
	mk := func(name string) *MutableTree {
		tree := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), HasherOptionForStore(name))
		_, err := tree.Set(key, val)
		require.NoError(t, err)
		_, _, err = tree.SaveVersion()
		require.NoError(t, err)
		return tree
	}
	dest := mk("b3-bank")
	ibc := mk("ibc")
	live := mk("bank")

	require.NotEqual(t, dest.Hash(), live.Hash())
	require.Equal(t, live.Hash(), ibc.Hash())

	pd, err := dest.GetMembershipProof(key)
	require.NoError(t, err)
	require.Equal(t, ics23.HashOp_BLAKE3, pd.GetExist().Leaf.Hash)
	require.True(t, ics23.VerifyMembership(ics23.Blake3IavlSpec, dest.Hash(), pd, key, val))
	require.False(t, ics23.VerifyMembership(ics23.IavlSpec, dest.Hash(), pd, key, val))

	pi, err := ibc.GetMembershipProof(key)
	require.NoError(t, err)
	require.Equal(t, ics23.HashOp_SHA256, pi.GetExist().Leaf.Hash)
	require.True(t, ics23.VerifyMembership(ics23.IavlSpec, ibc.Hash(), pi, key, val))
	require.False(t, ics23.VerifyMembership(ics23.Blake3IavlSpec, ibc.Hash(), pi, key, val))
}

func TestHybridTreesProduceDifferentEmptyHashes(t *testing.T) {
	t.Cleanup(func() { SetHasherMode(HasherModeV63) })
	SetHasherMode(HasherModeHybrid)
	ibc := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), HasherOptionForStore("ibc"))
	bank := NewMutableTree(dbm.NewMemDB(), 0, false, NewNopLogger(), HasherOptionForStore("bank"))

	require.Equal(t, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		hex.EncodeToString(ibc.Hash()))
	require.Equal(t, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
		hex.EncodeToString(bank.Hash()))
}
