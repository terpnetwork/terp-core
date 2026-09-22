package hash

import (
	"github.com/coinbase/kryptology/pkg/core/curves/native/pasta/fp"
)

// QuaternaryHasher extends the Hasher interface with quaternary tree operations.
// This is specifically designed for the TCT (Tiered Commitment Tree) structure
// which uses 4-ary trees for more efficient ZK proofs.
type QuaternaryHasher interface {
	Hasher

	// HashQuaternary computes the hash of a quaternary internal node.
	// Takes exactly 4 child hashes and returns the parent hash.
	HashQuaternary(children [4][]byte) []byte

	// HashQuaternaryWithDomainSep computes hash with domain separation for tiered trees.
	// The tier and level parameters provide domain separation to prevent cross-tier attacks.
	HashQuaternaryWithDomainSep(tier uint8, level uint8, children [4][]byte) []byte

	// HashTCTLeaf computes the hash of a TCT leaf node (commitment).
	// This is optimized for the TCT structure without version/size metadata.
	HashTCTLeaf(tier uint8, commitment []byte) []byte

	// HashTCTEmpty returns the empty hash for a tier at a given level.
	// Empty subtrees at different levels have different hashes for security.
	HashTCTEmpty(tier uint8, level uint8) []byte

	// EmptyChildHashes returns the 4 empty child hashes for the specified tier and level.
	EmptyChildHashes(tier uint8, level uint8) [4][]byte
}

// PoseidonQuaternaryHasher implements QuaternaryHasher using Poseidon.
type PoseidonQuaternaryHasher struct {
	*PoseidonHasher

	// emptyHashes caches empty hashes for each tier and level.
	// Key format: (tier << 8) | level
	emptyHashes map[uint16][]byte
}

// NewPoseidonQuaternaryHasher creates a new PoseidonQuaternaryHasher.
func NewPoseidonQuaternaryHasher() *PoseidonQuaternaryHasher {
	return &PoseidonQuaternaryHasher{
		PoseidonHasher: NewPoseidonHasher(),
		emptyHashes:    make(map[uint16][]byte),
	}
}

// HashQuaternary computes the Poseidon hash of 4 child hashes.
// Input structure: [child0_element, child1_element, child2_element, child3_element]
// Each child hash is 32 bytes, which fits in 2 field elements (31 bytes each).
func (h *PoseidonQuaternaryHasher) HashQuaternary(children [4][]byte) []byte {
	// Build input elements: 4 children × 2 elements each = 8 elements
	elements := make([]*fp.Fp, 0, 8)

	for i := 0; i < 4; i++ {
		if len(children[i]) == 0 {
			// Use zero element for empty children
			elements = append(elements, new(fp.Fp).SetZero())
			elements = append(elements, new(fp.Fp).SetZero())
		} else {
			childElements := bytesToFpElements(children[i])
			elements = append(elements, childElements...)
			// Pad to exactly 2 elements if needed
			for len(elements) < (i+1)*2 {
				elements = append(elements, new(fp.Fp).SetZero())
			}
		}
	}

	return h.hash(elements)
}

// HashQuaternaryWithDomainSep computes hash with domain separation.
// Input structure: [tier, level, child0..., child1..., child2..., child3...]
func (h *PoseidonQuaternaryHasher) HashQuaternaryWithDomainSep(tier uint8, level uint8, children [4][]byte) []byte {
	// Build input elements: domain sep (2 elements) + 4 children × 2 elements = 10 elements
	elements := make([]*fp.Fp, 0, 10)

	// Domain separation: tier and level as field elements
	tierFp := new(fp.Fp)
	tierFp.SetUint64(uint64(tier))
	elements = append(elements, tierFp)

	levelFp := new(fp.Fp)
	levelFp.SetUint64(uint64(level))
	elements = append(elements, levelFp)

	// Add child hashes
	for i := 0; i < 4; i++ {
		if len(children[i]) == 0 {
			elements = append(elements, new(fp.Fp).SetZero())
			elements = append(elements, new(fp.Fp).SetZero())
		} else {
			childElements := bytesToFpElements(children[i])
			elements = append(elements, childElements...)
			// Pad to exactly 2 elements if needed
			for len(elements) < 2+(i+1)*2 {
				elements = append(elements, new(fp.Fp).SetZero())
			}
		}
	}

	return h.hash(elements)
}

// HashTCTLeaf computes the hash of a TCT leaf (commitment).
// Input structure: [tier, commitment_elements...]
func (h *PoseidonQuaternaryHasher) HashTCTLeaf(tier uint8, commitment []byte) []byte {
	elements := make([]*fp.Fp, 0, 4)

	// Domain separation: tier
	tierFp := new(fp.Fp)
	tierFp.SetUint64(uint64(tier))
	elements = append(elements, tierFp)

	// Commitment as field elements
	commitElements := bytesToFpElements(commitment)
	elements = append(elements, commitElements...)

	return h.hash(elements)
}

// HashTCTEmpty returns the empty hash for a given tier and level.
// Empty hashes are computed recursively and cached for efficiency.
func (h *PoseidonQuaternaryHasher) HashTCTEmpty(tier uint8, level uint8) []byte {
	key := (uint16(tier) << 8) | uint16(level)

	if cached, ok := h.emptyHashes[key]; ok {
		return cached
	}

	var hash []byte
	if level == 8 { // Leaf level (QuaternaryLevels)
		// Empty leaf: hash of zero commitment with tier domain separation
		hash = h.HashTCTLeaf(tier, nil)
	} else {
		// Empty internal node: hash of 4 empty children at level+1
		childEmpty := h.HashTCTEmpty(tier, level+1)
		children := [4][]byte{childEmpty, childEmpty, childEmpty, childEmpty}
		hash = h.HashQuaternaryWithDomainSep(tier, level, children)
	}

	h.emptyHashes[key] = hash
	return hash
}

// EmptyChildHashes returns 4 copies of the empty hash at the child level.
func (h *PoseidonQuaternaryHasher) EmptyChildHashes(tier uint8, level uint8) [4][]byte {
	childLevel := level + 1
	emptyChild := h.HashTCTEmpty(tier, childLevel)

	return [4][]byte{
		emptyChild,
		emptyChild,
		emptyChild,
		emptyChild,
	}
}

// HashFour is a convenience method for hashing exactly 4 values.
// This is the core operation for quaternary Merkle trees.
func (h *PoseidonQuaternaryHasher) HashFour(a, b, c, d []byte) []byte {
	return h.HashQuaternary([4][]byte{a, b, c, d})
}

// CombineProofHashes combines a proof element with sibling hashes at a given index.
// Used during proof verification to compute the parent hash.
func (h *PoseidonQuaternaryHasher) CombineProofHashes(
	tier uint8,
	level uint8,
	childIndex uint8,
	childHash []byte,
	siblings [3][]byte,
) []byte {
	var children [4][]byte

	sibIdx := 0
	for i := uint8(0); i < 4; i++ {
		if i == childIndex {
			children[i] = childHash
		} else {
			children[i] = siblings[sibIdx]
			sibIdx++
		}
	}

	return h.HashQuaternaryWithDomainSep(tier, level, children)
}

// Ensure PoseidonQuaternaryHasher implements QuaternaryHasher.
var _ QuaternaryHasher = (*PoseidonQuaternaryHasher)(nil)
