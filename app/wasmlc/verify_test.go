package wasmlc

import (
	"os"
	"testing"

	"github.com/cosmos/iavl"
	dbm "github.com/cosmos/iavl/db"
	ics23 "github.com/cosmos/ics23/go"
	"github.com/stretchr/testify/require"

	terpiavl "github.com/terpnetwork/terp-core/v6/app/iavl"
)

func treeKV(t *testing.T, store string, key, val []byte) (*iavl.MutableTree, *ics23.CommitmentProof) {
	t.Helper()
	tree := iavl.NewMutableTree(dbm.NewMemDB(), 0, false, iavl.NewNopLogger(), iavl.HasherOptionForStore(store))
	_, err := tree.Set(key, val)
	require.NoError(t, err)
	_, _, err = tree.SaveVersion()
	require.NoError(t, err)
	p, err := tree.GetMembershipProof(key)
	require.NoError(t, err)
	return tree, p
}

func loadWasm(t *testing.T) []byte {
	t.Helper()
	p, err := FindWasm()
	if err != nil {
		t.Skip(err.Error())
	}
	bz, err := os.ReadFile(p)
	require.NoError(t, err)
	require.Greater(t, len(bz), 1000)
	return bz
}

func TestWasmLcVerifyMembershipBlake3BankAndSha256IBC(t *testing.T) {
	iavl.SetHasherMode(iavl.HasherModeV63)
	t.Cleanup(func() { iavl.SetHasherMode(iavl.HasherModeV63) })

	wasm := loadWasm(t)
	key, val := []byte("k"), []byte("v")

	bank, pBank := treeKV(t, "b3-bank", key, val)
	hop, err := terpiavl.ProofHashOp(pBank)
	require.NoError(t, err)
	require.Equal(t, ics23.HashOp_BLAKE3, hop)

	ibc, pIBC := treeKV(t, "ibc", key, val)
	hop, err = terpiavl.ProofHashOp(pIBC)
	require.NoError(t, err)
	require.Equal(t, ics23.HashOp_SHA256, hop)

	err = ExclusiveWasm(wasm, Membership{
		Store:  "b3-bank",
		Key:    key,
		Value:  val,
		Proofs: []*ics23.CommitmentProof{pBank},
		Root:   bank.Hash(),
		Height: 1,
	})
	require.NoError(t, err, "08-wasm LC must accept BLAKE3 IAVL membership for dest bank")

	err = ExclusiveWasm(wasm, Membership{
		Store:  "ibc",
		Key:    key,
		Value:  val,
		Proofs: []*ics23.CommitmentProof{pIBC},
		Root:   ibc.Hash(),
		Height: 1,
	})
	require.NoError(t, err, "08-wasm LC must accept SHA-256 IAVL membership for ibc")

	_, err = Verify(wasm, "sha256", Membership{
		Store:  "b3-bank",
		Key:    key,
		Value:  val,
		Proofs: []*ics23.CommitmentProof{pBank},
		Root:   bank.Hash(),
		Height: 1,
	})
	require.Error(t, err, "sha256-mode LC must reject a BLAKE3 dest-bank proof")
}
