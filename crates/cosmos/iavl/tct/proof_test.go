package tct

import (
	"bytes"
	"crypto/rand"
	"testing"

	"github.com/cosmos/iavl/hash"
)

func TestProofGenerationAndVerification(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert commitments
	commitments := make([][]byte, 10)
	positions := make([]Position, 10)

	for i := 0; i < 10; i++ {
		commitments[i] = make([]byte, 32)
		rand.Read(commitments[i])
		pos, err := tct.InsertCommitment(commitments[i], WitnessKeep)
		if err != nil {
			t.Fatalf("InsertCommitment %d failed: %v", i, err)
		}
		positions[i] = pos
	}

	// Finalize the block and epoch (TCT proofs are against finalized anchors)
	_, err := tct.EndBlock()
	if err != nil {
		t.Fatalf("EndBlock failed: %v", err)
	}
	_, err = tct.EndEpoch()
	if err != nil {
		t.Fatalf("EndEpoch failed: %v", err)
	}

	// Generate and verify proofs for each commitment
	// Note: positions are in epoch 0, block 0, which is now finalized
	for i := 0; i < 10; i++ {
		proof, err := tct.GenerateProofFinalized(positions[i])
		if err != nil {
			t.Fatalf("GenerateProofFinalized for position %v failed: %v", positions[i], err)
		}

		// Verify the commitment in the proof matches
		if !bytes.Equal(proof.Commitment, commitments[i]) {
			t.Errorf("Proof commitment mismatch at position %v", positions[i])
		}

		// Verify the proof
		valid, err := VerifyProof(proof, tct.GetHasher())
		if err != nil {
			t.Fatalf("VerifyProof failed: %v", err)
		}
		if !valid {
			t.Errorf("Proof verification failed for position %v", positions[i])
		}
	}
}

func TestProofVerificationWithWrongRoot(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert a commitment
	commitment := make([]byte, 32)
	rand.Read(commitment)
	pos, _ := tct.InsertCommitment(commitment, WitnessKeep)

	// Finalize
	tct.EndBlock()
	tct.EndEpoch()

	// Generate proof
	proof, err := tct.GenerateProofFinalized(pos)
	if err != nil {
		t.Fatalf("GenerateProofFinalized failed: %v", err)
	}

	// Modify the root
	proof.Root = make([]byte, 32)
	rand.Read(proof.Root)

	// Verification should fail
	valid, _ := VerifyProof(proof, tct.GetHasher())
	if valid {
		t.Error("Proof verification should fail with wrong root")
	}
}

func TestProofVerificationWithWrongCommitment(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert a commitment
	commitment := make([]byte, 32)
	rand.Read(commitment)
	pos, _ := tct.InsertCommitment(commitment, WitnessKeep)

	// Finalize
	tct.EndBlock()
	tct.EndEpoch()

	// Generate proof
	proof, err := tct.GenerateProofFinalized(pos)
	if err != nil {
		t.Fatalf("GenerateProofFinalized failed: %v", err)
	}

	// Modify the commitment
	proof.Commitment = make([]byte, 32)
	rand.Read(proof.Commitment)

	// Verification should fail
	valid, _ := VerifyProof(proof, tct.GetHasher())
	if valid {
		t.Error("Proof verification should fail with wrong commitment")
	}
}

func TestProofSerializationRoundTrip(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert some commitments
	for i := 0; i < 5; i++ {
		commitment := make([]byte, 32)
		rand.Read(commitment)
		tct.InsertCommitment(commitment, WitnessKeep)
	}

	// Finalize
	tct.EndBlock()
	tct.EndEpoch()

	// Generate a proof
	pos := Position{Epoch: 0, Block: 0, Commitment: 2}
	proof, err := tct.GenerateProofFinalized(pos)
	if err != nil {
		t.Fatalf("GenerateProofFinalized failed: %v", err)
	}

	// Serialize
	data, err := proof.Serialize()
	if err != nil {
		t.Fatalf("Serialize failed: %v", err)
	}

	// Deserialize
	restored, err := DeserializeProof(data)
	if err != nil {
		t.Fatalf("DeserializeProof failed: %v", err)
	}

	// Verify the restored proof matches
	if restored.Position != proof.Position {
		t.Error("Position mismatch after deserialization")
	}
	if !bytes.Equal(restored.Commitment, proof.Commitment) {
		t.Error("Commitment mismatch after deserialization")
	}
	if !bytes.Equal(restored.Root, proof.Root) {
		t.Error("Root mismatch after deserialization")
	}

	// The restored proof should still verify
	valid, err := VerifyProof(restored, tct.GetHasher())
	if err != nil {
		t.Fatalf("VerifyProof on restored proof failed: %v", err)
	}
	if !valid {
		t.Error("Restored proof should verify")
	}
}

func TestProofStats(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert a commitment
	commitment := make([]byte, 32)
	rand.Read(commitment)
	pos, _ := tct.InsertCommitment(commitment, WitnessKeep)

	// Finalize
	tct.EndBlock()
	tct.EndEpoch()

	// Generate proof
	proof, err := tct.GenerateProofFinalized(pos)
	if err != nil {
		t.Fatalf("GenerateProofFinalized failed: %v", err)
	}

	stats := proof.Stats()

	if stats.PathLevels != QuaternaryLevels {
		t.Errorf("PathLevels: got %d, want %d", stats.PathLevels, QuaternaryLevels)
	}

	if stats.SiblingsPerLevel != 3 {
		t.Errorf("SiblingsPerLevel: got %d, want 3", stats.SiblingsPerLevel)
	}

	if stats.TotalSiblings != 3*QuaternaryLevels*3 {
		t.Errorf("TotalSiblings: got %d, want %d", stats.TotalSiblings, 3*QuaternaryLevels*3)
	}

	if stats.HashSize != 32 {
		t.Errorf("HashSize: got %d, want 32", stats.HashSize)
	}
}

func TestTierProofPath(t *testing.T) {
	// Test that computePathFromIndex correctly inverts the index
	testCases := []struct {
		index uint16
	}{
		{0},
		{1},
		{4},
		{16},
		{255},
		{1024},
		{65535},
	}

	for _, tc := range testCases {
		path := computePathFromIndex(tc.index)

		// Reconstruct index from path
		var reconstructed uint16
		for _, childIdx := range path {
			reconstructed = (reconstructed << 2) | uint16(childIdx)
		}

		if reconstructed != tc.index {
			t.Errorf("Path reconstruction failed for index %d: got %d", tc.index, reconstructed)
		}
	}
}

func TestVerifyTierProofLogic(t *testing.T) {
	hasher := hash.NewPoseidonQuaternaryHasher()

	// Create a simple tier proof manually
	leafHash := make([]byte, 32)
	rand.Read(leafHash)

	// Create siblings (all zeros for simplicity)
	proof := &TierProof{
		Tier:      TierCommitment,
		LeafIndex: 0, // All path elements are 0
		LeafHash:  leafHash,
		Path:      make([][3][]byte, QuaternaryLevels),
	}

	// Fill in empty siblings
	for level := 0; level < QuaternaryLevels; level++ {
		for i := 0; i < 3; i++ {
			proof.Path[level][i] = hasher.HashTCTEmpty(uint8(TierCommitment), uint8(level+1))
		}
	}

	// Verify the tier proof computes a root
	root, err := verifyTierProof(proof, leafHash, hasher)
	if err != nil {
		t.Fatalf("verifyTierProof failed: %v", err)
	}

	if len(root) != 32 {
		t.Errorf("Root length: got %d, want 32", len(root))
	}
}

func TestProofAcrossBlocks(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert commitments across multiple blocks
	var positions []Position

	for block := 0; block < 3; block++ {
		for i := 0; i < 5; i++ {
			commitment := make([]byte, 32)
			rand.Read(commitment)
			pos, err := tct.InsertCommitment(commitment, WitnessKeep)
			if err != nil {
				t.Fatalf("InsertCommitment failed: %v", err)
			}
			positions = append(positions, pos)
		}
		// End each block
		_, err := tct.EndBlock()
		if err != nil {
			t.Fatalf("EndBlock failed: %v", err)
		}
	}

	// Finalize the epoch
	_, err := tct.EndEpoch()
	if err != nil {
		t.Fatalf("EndEpoch failed: %v", err)
	}

	// Generate proof for a commitment in the first block (now finalized)
	proof, err := tct.GenerateProofFinalized(positions[0])
	if err != nil {
		t.Fatalf("GenerateProofFinalized failed: %v", err)
	}

	valid, err := VerifyProof(proof, tct.GetHasher())
	if err != nil {
		t.Fatalf("VerifyProof failed: %v", err)
	}
	if !valid {
		t.Error("Proof should verify for finalized commitment")
	}
}

func TestNilProofVerification(t *testing.T) {
	hasher := hash.NewPoseidonQuaternaryHasher()

	valid, err := VerifyProof(nil, hasher)
	if err == nil {
		t.Error("VerifyProof should return error for nil proof")
	}
	if valid {
		t.Error("Nil proof should not verify as valid")
	}
}
