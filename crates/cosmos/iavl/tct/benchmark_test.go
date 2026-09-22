package tct

import (
	"crypto/rand"
	"testing"

	"github.com/cosmos/iavl/hash"
)

// BenchmarkQuaternaryTreeInsert benchmarks insertion into a quaternary tree.
func BenchmarkQuaternaryTreeInsert(b *testing.B) {
	config := DefaultQuaternaryTreeConfig(TierCommitment)
	tree := NewQuaternaryTree(config)

	commitment := make([]byte, 32)
	rand.Read(commitment)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tree.Insert(commitment)
		if tree.Size() >= uint64(MaxIndex) {
			tree.Clear()
		}
	}
}

// BenchmarkQuaternaryTreeGetHash benchmarks root hash computation.
func BenchmarkQuaternaryTreeGetHash(b *testing.B) {
	config := DefaultQuaternaryTreeConfig(TierCommitment)
	tree := NewQuaternaryTree(config)

	// Pre-populate with some data
	for i := 0; i < 100; i++ {
		commitment := make([]byte, 32)
		rand.Read(commitment)
		tree.Insert(commitment)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tree.GetHash()
	}
}

// BenchmarkTieredTreeInsertCommitment benchmarks commitment insertion.
func BenchmarkTieredTreeInsertCommitment(b *testing.B) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	commitment := make([]byte, 32)
	rand.Read(commitment)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tct.InsertCommitment(commitment, WitnessNone)
		// Periodically end blocks to avoid overflow
		if tct.CurrentPosition().Commitment%1000 == 999 {
			tct.EndBlock()
		}
	}
}

// BenchmarkTieredTreeInsertWitnessed benchmarks witnessed commitment insertion.
func BenchmarkTieredTreeInsertWitnessed(b *testing.B) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	commitment := make([]byte, 32)
	rand.Read(commitment)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tct.InsertCommitment(commitment, WitnessKeep)
		if tct.CurrentPosition().Commitment%1000 == 999 {
			tct.EndBlock()
		}
	}
}

// BenchmarkTieredTreeEndBlock benchmarks block finalization.
func BenchmarkTieredTreeEndBlock(b *testing.B) {
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		config := DefaultTieredTreeConfig()
		tct := NewTieredCommitmentTree(config)

		// Insert 100 commitments
		commitment := make([]byte, 32)
		for j := 0; j < 100; j++ {
			rand.Read(commitment)
			tct.InsertCommitment(commitment, WitnessNone)
		}

		b.StartTimer()
		tct.EndBlock()
	}
}

// BenchmarkTieredTreeRoot benchmarks root hash computation.
func BenchmarkTieredTreeRoot(b *testing.B) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Pre-populate
	for i := 0; i < 100; i++ {
		commitment := make([]byte, 32)
		rand.Read(commitment)
		tct.InsertCommitment(commitment, WitnessNone)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tct.Root()
	}
}

// BenchmarkProofGeneration benchmarks Merkle proof generation.
func BenchmarkProofGeneration(b *testing.B) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Pre-populate
	var positions []Position
	for i := 0; i < 100; i++ {
		commitment := make([]byte, 32)
		rand.Read(commitment)
		pos, _ := tct.InsertCommitment(commitment, WitnessKeep)
		positions = append(positions, pos)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tct.GenerateProof(positions[i%len(positions)])
	}
}

// BenchmarkProofVerification benchmarks Merkle proof verification.
func BenchmarkProofVerification(b *testing.B) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Pre-populate
	var proofs []*TCTProof
	for i := 0; i < 100; i++ {
		commitment := make([]byte, 32)
		rand.Read(commitment)
		pos, _ := tct.InsertCommitment(commitment, WitnessKeep)
		proof, _ := tct.GenerateProof(pos)
		proofs = append(proofs, proof)
	}

	hasher := tct.GetHasher()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		VerifyProof(proofs[i%len(proofs)], hasher)
	}
}

// BenchmarkProofSerialization benchmarks proof serialization.
func BenchmarkProofSerialization(b *testing.B) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	commitment := make([]byte, 32)
	rand.Read(commitment)
	pos, _ := tct.InsertCommitment(commitment, WitnessKeep)
	proof, _ := tct.GenerateProof(pos)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		proof.Serialize()
	}
}

// BenchmarkProofDeserialization benchmarks proof deserialization.
func BenchmarkProofDeserialization(b *testing.B) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	commitment := make([]byte, 32)
	rand.Read(commitment)
	pos, _ := tct.InsertCommitment(commitment, WitnessKeep)
	proof, _ := tct.GenerateProof(pos)
	data, _ := proof.Serialize()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		DeserializeProof(data)
	}
}

// BenchmarkQuaternaryHash benchmarks quaternary hash operations.
func BenchmarkQuaternaryHash(b *testing.B) {
	hasher := hash.NewPoseidonQuaternaryHasher()

	children := [4][]byte{
		make([]byte, 32),
		make([]byte, 32),
		make([]byte, 32),
		make([]byte, 32),
	}
	for i := range children {
		rand.Read(children[i])
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		hasher.HashQuaternary(children)
	}
}

// BenchmarkQuaternaryHashWithDomainSep benchmarks hash with domain separation.
func BenchmarkQuaternaryHashWithDomainSep(b *testing.B) {
	hasher := hash.NewPoseidonQuaternaryHasher()

	children := [4][]byte{
		make([]byte, 32),
		make([]byte, 32),
		make([]byte, 32),
		make([]byte, 32),
	}
	for i := range children {
		rand.Read(children[i])
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		hasher.HashQuaternaryWithDomainSep(0, 0, children)
	}
}

// BenchmarkTCTLeafHash benchmarks TCT leaf hashing.
func BenchmarkTCTLeafHash(b *testing.B) {
	hasher := hash.NewPoseidonQuaternaryHasher()
	commitment := make([]byte, 32)
	rand.Read(commitment)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		hasher.HashTCTLeaf(0, commitment)
	}
}

// BenchmarkPoseidonBinaryHash benchmarks binary Poseidon hash for comparison.
func BenchmarkPoseidonBinaryHash(b *testing.B) {
	hasher := hash.NewPoseidonHasher()
	left := make([]byte, 32)
	right := make([]byte, 32)
	rand.Read(left)
	rand.Read(right)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		hasher.HashTwo(left, right)
	}
}

// BenchmarkHashOperationComparison compares hash operations between quaternary and binary.
func BenchmarkHashOperationComparison(b *testing.B) {
	b.Run("Binary/2-children", func(b *testing.B) {
		hasher := hash.NewPoseidonHasher()
		left := make([]byte, 32)
		right := make([]byte, 32)
		rand.Read(left)
		rand.Read(right)

		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			hasher.HashTwo(left, right)
		}
	})

	b.Run("Quaternary/4-children", func(b *testing.B) {
		hasher := hash.NewPoseidonQuaternaryHasher()
		children := [4][]byte{
			make([]byte, 32),
			make([]byte, 32),
			make([]byte, 32),
			make([]byte, 32),
		}
		for i := range children {
			rand.Read(children[i])
		}

		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			hasher.HashQuaternary(children)
		}
	})
}

// BenchmarkTreeDepthComparison compares effective tree depth operations.
func BenchmarkTreeDepthComparison(b *testing.B) {
	n := 10000

	b.Run("Binary-tree-sim/log2", func(b *testing.B) {
		hasher := hash.NewPoseidonHasher()
		leaf := make([]byte, 32)
		rand.Read(leaf)

		// Simulate binary tree path (log2(65536) ≈ 16 levels)
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			current := leaf
			for level := 0; level < 16; level++ {
				sibling := leaf // Simplified
				current = hasher.HashTwo(current, sibling)
			}
		}
	})

	b.Run("Quaternary-tree-sim/log4", func(b *testing.B) {
		hasher := hash.NewPoseidonQuaternaryHasher()
		leaf := make([]byte, 32)
		rand.Read(leaf)

		// Simulate quaternary tree path (log4(65536) = 8 levels)
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			current := leaf
			for level := 0; level < 8; level++ {
				children := [4][]byte{current, leaf, leaf, leaf}
				current = hasher.HashQuaternary(children)
			}
		}
	})

	_ = n // silence unused variable warning
}

// BenchmarkTCTVisualization benchmarks the DOT graph generation for TCT.
func BenchmarkTCTVisualization(b *testing.B) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Pre-populate with some commitments to create an interesting tree structure
	for i := 0; i < 100; i++ {
		commitment := make([]byte, 32)
		rand.Read(commitment)
		tct.InsertCommitment(commitment, WitnessKeep)
		if i%10 == 9 {
			tct.EndBlock()
		}
	}
	tct.EndEpoch()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		WriteDOTGraphToFile("/tmp/tct_visualization.dot", tct)
	}
}

// BenchmarkMassInsertion benchmarks inserting many commitments.
func BenchmarkMassInsertion(b *testing.B) {
	sizes := []int{100, 1000, 10000}

	for _, size := range sizes {
		b.Run(string(rune(size)), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				b.StopTimer()
				config := DefaultTieredTreeConfig()
				tct := NewTieredCommitmentTree(config)
				commitments := make([][]byte, size)
				for j := range commitments {
					commitments[j] = make([]byte, 32)
					rand.Read(commitments[j])
				}
				b.StartTimer()

				for _, c := range commitments {
					tct.InsertCommitment(c, WitnessNone)
				}
				tct.EndBlock()
			}
		})
	}
}

// BenchmarkSparseClientSync benchmarks sparse client synchronization.
func BenchmarkSparseClientSync(b *testing.B) {
	// Simulate a sparse client receiving block roots
	blockRoots := make([][]byte, 100)
	for i := range blockRoots {
		blockRoots[i] = make([]byte, 32)
		rand.Read(blockRoots[i])
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		config := DefaultTieredTreeConfig()
		tct := NewTieredCommitmentTree(config)

		for _, root := range blockRoots {
			tct.InsertBlockRoot(root)
		}
	}
}
