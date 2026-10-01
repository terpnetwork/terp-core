package iavl

import (
	"fmt"

	ics23 "github.com/cosmos/ics23/go"
)

// SpecForStore is the ICS-23 spec that must accept a membership proof for storeName.
func SpecForStore(storeName string) *ics23.ProofSpec {
	if AlgorithmName(storeName) == "blake3" {
		return ics23.Blake3IavlSpec
	}
	return ics23.IavlSpec
}

// OtherSpec is the hasher spec that must reject a membership proof for storeName.
func OtherSpec(storeName string) *ics23.ProofSpec {
	if AlgorithmName(storeName) == "blake3" {
		return ics23.IavlSpec
	}
	return ics23.Blake3IavlSpec
}

// VerifyExclusive checks that proof verifies with the store's hasher spec and
// fails the other. This is the IAVL light-client membership check TSH uses.
func VerifyExclusive(storeName string, root []byte, proof *ics23.CommitmentProof, key, value []byte) error {
	if proof == nil || proof.GetExist() == nil {
		return fmt.Errorf("%s: missing existence proof", storeName)
	}
	want := SpecForStore(storeName)
	if !ics23.VerifyMembership(want, root, proof, key, value) {
		return fmt.Errorf("%s: membership failed for %s spec", storeName, AlgorithmName(storeName))
	}
	if ics23.VerifyMembership(OtherSpec(storeName), root, proof, key, value) {
		return fmt.Errorf("%s: unsound: proof also verified with the other hasher spec", storeName)
	}
	return nil
}

// ProofHashOp returns the leaf HashOp on an existence proof.
func ProofHashOp(proof *ics23.CommitmentProof) (ics23.HashOp, error) {
	if proof == nil || proof.GetExist() == nil || proof.GetExist().Leaf == nil {
		return 0, fmt.Errorf("missing existence leaf")
	}
	return proof.GetExist().Leaf.Hash, nil
}
