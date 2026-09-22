package tct

import (
	"encoding/binary"
	"fmt"

	"github.com/cosmos/iavl/hash"
)

// TCTProofSpec defines the specification for TCT proofs.
// This is analogous to ICS-23 ProofSpec but for quaternary tiered trees.
var TCTProofSpec = &TCTSpec{
	// Each tier is a quaternary tree with 8 levels
	TierDepth: QuaternaryLevels,

	// Siblings per level (4-ary tree = 3 siblings)
	SiblingsPerLevel: QuaternaryBranchingFactor - 1,

	// Number of tiers: Commitment -> Block -> Epoch
	NumTiers: 3,

	// Hash output size in bytes
	HashSize: 32,

	// Total proof path length: 3 tiers × 8 levels × 3 siblings = 72 hashes
	TotalPathElements: 3 * QuaternaryLevels * (QuaternaryBranchingFactor - 1),
}

// TCTSpec defines the proof specification for TCT.
type TCTSpec struct {
	TierDepth         int
	SiblingsPerLevel  int
	NumTiers          int
	HashSize          int
	TotalPathElements int
}

// TCTExistenceProof is a proof that a commitment exists in the TCT.
// This is analogous to ICS-23 ExistenceProof.
type TCTExistenceProof struct {
	// Key is the original key (optional, for key-value commitments)
	Key []byte

	// Value is the original value (optional, for key-value commitments)
	Value []byte

	// Commitment is the commitment hash being proven
	Commitment []byte

	// Position is the location in the TCT
	Position Position

	// Proof is the full TCT membership proof
	Proof *TCTProof
}

// Verify verifies this existence proof against a root hash.
func (p *TCTExistenceProof) Verify(hasher hash.QuaternaryHasher, root []byte) (bool, error) {
	if p.Proof == nil {
		return false, fmt.Errorf("nil proof")
	}

	// Set the expected root in the proof if not already set
	if len(p.Proof.Root) == 0 {
		p.Proof.Root = root
	}

	return VerifyProof(p.Proof, hasher)
}

// TCTCommitmentProof wraps a TCT proof in a format suitable for commitment verification.
// This is analogous to ICS-23 CommitmentProof.
type TCTCommitmentProof struct {
	// Type indicates the proof type
	Type TCTProofType

	// Exist is the existence proof (when Type == TCTProofTypeExist)
	Exist *TCTExistenceProof

	// BatchProof contains multiple existence proofs (when Type == TCTProofTypeBatch)
	BatchProof []*TCTExistenceProof
}

// TCTProofType indicates the type of TCT proof.
type TCTProofType uint8

const (
	// TCTProofTypeExist is a single existence proof
	TCTProofTypeExist TCTProofType = iota

	// TCTProofTypeBatch is a batch of existence proofs
	TCTProofTypeBatch
)

// VerifyMembership verifies that a commitment exists in the TCT with the given root.
func VerifyMembership(spec *TCTSpec, root []byte, proof *TCTCommitmentProof, commitment []byte, hasher hash.QuaternaryHasher) bool {
	if proof == nil || proof.Type != TCTProofTypeExist || proof.Exist == nil {
		return false
	}

	// Verify commitment matches
	if len(proof.Exist.Commitment) > 0 && string(proof.Exist.Commitment) != string(commitment) {
		return false
	}

	valid, err := proof.Exist.Verify(hasher, root)
	if err != nil {
		return false
	}

	return valid
}

// CreateTCTExistenceProof creates an existence proof for a commitment.
func (t *TieredCommitmentTree) CreateTCTExistenceProof(pos Position) (*TCTExistenceProof, error) {
	proof, err := t.GenerateProofFinalized(pos)
	if err != nil {
		return nil, fmt.Errorf("failed to generate proof: %w", err)
	}

	return &TCTExistenceProof{
		Commitment: proof.Commitment,
		Position:   pos,
		Proof:      proof,
	}, nil
}

// CreateTCTCommitmentProof creates a commitment proof for verification.
func (t *TieredCommitmentTree) CreateTCTCommitmentProof(pos Position) (*TCTCommitmentProof, error) {
	exist, err := t.CreateTCTExistenceProof(pos)
	if err != nil {
		return nil, err
	}

	return &TCTCommitmentProof{
		Type:  TCTProofTypeExist,
		Exist: exist,
	}, nil
}

// SerializeExistenceProof serializes a TCT existence proof to bytes.
func SerializeExistenceProof(proof *TCTExistenceProof) ([]byte, error) {
	if proof == nil || proof.Proof == nil {
		return nil, fmt.Errorf("nil proof")
	}

	// Serialize the underlying TCT proof
	proofBytes, err := proof.Proof.Serialize()
	if err != nil {
		return nil, fmt.Errorf("failed to serialize proof: %w", err)
	}

	// Build the full proof bytes
	// Format: [key_len(4)][key][value_len(4)][value][proof_bytes]
	totalLen := 4 + len(proof.Key) + 4 + len(proof.Value) + len(proofBytes)
	result := make([]byte, 0, totalLen)

	// Key
	keyLenBytes := make([]byte, 4)
	binary.BigEndian.PutUint32(keyLenBytes, uint32(len(proof.Key)))
	result = append(result, keyLenBytes...)
	result = append(result, proof.Key...)

	// Value
	valueLenBytes := make([]byte, 4)
	binary.BigEndian.PutUint32(valueLenBytes, uint32(len(proof.Value)))
	result = append(result, valueLenBytes...)
	result = append(result, proof.Value...)

	// Proof
	result = append(result, proofBytes...)

	return result, nil
}

// DeserializeExistenceProof deserializes a TCT existence proof from bytes.
func DeserializeExistenceProof(data []byte) (*TCTExistenceProof, error) {
	if len(data) < 8 {
		return nil, fmt.Errorf("data too short")
	}

	offset := 0

	// Read key
	keyLen := binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4
	if offset+int(keyLen) > len(data) {
		return nil, fmt.Errorf("invalid key length")
	}
	key := make([]byte, keyLen)
	copy(key, data[offset:offset+int(keyLen)])
	offset += int(keyLen)

	// Read value
	if offset+4 > len(data) {
		return nil, fmt.Errorf("data too short for value length")
	}
	valueLen := binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4
	if offset+int(valueLen) > len(data) {
		return nil, fmt.Errorf("invalid value length")
	}
	value := make([]byte, valueLen)
	copy(value, data[offset:offset+int(valueLen)])
	offset += int(valueLen)

	// Read proof
	proof, err := DeserializeProof(data[offset:])
	if err != nil {
		return nil, fmt.Errorf("failed to deserialize proof: %w", err)
	}

	return &TCTExistenceProof{
		Key:        key,
		Value:      value,
		Commitment: proof.Commitment,
		Position:   proof.Position,
		Proof:      proof,
	}, nil
}

// TCTBatchProof contains multiple proofs that share a common root.
type TCTBatchProof struct {
	// Root is the shared root hash
	Root []byte

	// Proofs is the list of individual proofs
	Proofs []*TCTProof
}

// VerifyBatch verifies all proofs in the batch against the root.
func (b *TCTBatchProof) VerifyBatch(hasher hash.QuaternaryHasher) (bool, error) {
	if len(b.Proofs) == 0 {
		return true, nil
	}

	for i, proof := range b.Proofs {
		// Set root from batch
		proof.Root = b.Root

		valid, err := VerifyProof(proof, hasher)
		if err != nil {
			return false, fmt.Errorf("proof %d verification error: %w", i, err)
		}
		if !valid {
			return false, fmt.Errorf("proof %d invalid", i)
		}
	}

	return true, nil
}

// ProofSizeEstimate returns an estimate of the proof size in bytes.
// Useful for planning network bandwidth and storage.
func ProofSizeEstimate() int {
	// Position: 8 bytes
	// Commitment: 32 bytes
	// Root: 32 bytes
	// 3 tier proofs × (1 tier byte + 2 index bytes + 32 leaf hash + 8 levels × 3 siblings × 32 bytes)
	//   = 3 × (1 + 2 + 32 + 8 × 3 × 32) = 3 × (35 + 768) = 3 × 803 = 2409
	// Total: 8 + 32 + 32 + 2409 = 2481 bytes
	return 2500 // Round up for length prefixes
}

// CompressedProofSize returns size when using compressed path encoding.
// In practice, many siblings are empty hashes which can be represented more compactly.
func CompressedProofSize(proof *TCTProof, hasher hash.QuaternaryHasher) int {
	if proof == nil {
		return 0
	}

	// Count non-empty hashes (empty hashes can be represented with 1 byte)
	nonEmptyCount := 0

	// Check each tier
	for _, tierProof := range []*TierProof{proof.CommitmentProof, proof.BlockProof, proof.EpochProof} {
		if tierProof == nil {
			continue
		}

		for level := 0; level < QuaternaryLevels; level++ {
			emptyHash := hasher.HashTCTEmpty(uint8(tierProof.Tier), uint8(level+1))
			for _, sibling := range tierProof.Path[level] {
				if string(sibling) != string(emptyHash) {
					nonEmptyCount++
				}
			}
		}
	}

	// Base: 72 bytes (position + commitment + root)
	// Non-empty siblings: 32 bytes each
	// Empty siblings: 1 byte marker each
	emptyCount := 3*QuaternaryLevels*3 - nonEmptyCount
	return 72 + nonEmptyCount*32 + emptyCount*1
}
