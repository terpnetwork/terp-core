package tct

import (
	"bytes"
	"encoding/binary"
	"fmt"

	"github.com/cosmos/iavl/hash"
)

// TierProof contains the Merkle proof for a single tier in the TCT.
type TierProof struct {
	// Tier identifies which tier this proof is for.
	Tier Tier

	// Path contains the sibling hashes at each level.
	// For a quaternary tree, each level has 3 siblings.
	// Index 0 is the level closest to the root.
	Path [][3][]byte

	// LeafIndex is the index of the leaf being proven.
	LeafIndex uint16

	// LeafHash is the hash of the proven leaf.
	LeafHash []byte
}

// TCTProof contains the complete proof for a commitment in the tiered tree.
type TCTProof struct {
	// Position identifies the exact location of the commitment.
	Position Position

	// Commitment is the value being proven.
	Commitment []byte

	// CommitmentProof proves the commitment within its block.
	CommitmentProof *TierProof

	// BlockProof proves the block within its epoch.
	BlockProof *TierProof

	// EpochProof proves the epoch within the eternity tree.
	EpochProof *TierProof

	// Root is the expected root hash of the entire tree.
	Root []byte
}

// GenerateProof generates a proof for a commitment at the given position.
func (t *TieredCommitmentTree) GenerateProof(pos Position) (*TCTProof, error) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	// First, compute the current root to include in the proof
	root, err := t.eternityTree.GetHash()
	if err != nil {
		return nil, fmt.Errorf("failed to get root: %w", err)
	}

	proof := &TCTProof{
		Position: pos,
		Root:     root,
	}

	// Generate commitment-tier proof
	commitProof, commitment, err := t.generateTierProof(t.currentBlockTree, pos.Commitment)
	if err != nil {
		return nil, fmt.Errorf("failed to generate commitment proof: %w", err)
	}
	proof.CommitmentProof = commitProof
	proof.Commitment = commitment

	// Get block root for block-tier proof
	blockRoot, err := t.currentBlockTree.GetHash()
	if err != nil {
		return nil, fmt.Errorf("failed to get block root: %w", err)
	}

	// Generate block-tier proof
	blockProof, _, err := t.generateTierProofWithLeafHash(t.currentEpochTree, pos.Block, blockRoot)
	if err != nil {
		return nil, fmt.Errorf("failed to generate block proof: %w", err)
	}
	proof.BlockProof = blockProof

	// Get epoch root for epoch-tier proof
	epochRoot, err := t.currentEpochTree.GetHash()
	if err != nil {
		return nil, fmt.Errorf("failed to get epoch root: %w", err)
	}

	// Generate epoch-tier proof
	epochProof, _, err := t.generateTierProofWithLeafHash(t.eternityTree, pos.Epoch, epochRoot)
	if err != nil {
		return nil, fmt.Errorf("failed to generate epoch proof: %w", err)
	}
	proof.EpochProof = epochProof

	return proof, nil
}

// GenerateProofFinalized generates a proof for a commitment in finalized state.
// The position must reference a finalized block and epoch.
func (t *TieredCommitmentTree) GenerateProofFinalized(pos Position) (*TCTProof, error) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	// Get the finalized trees for this position
	blockKey := (uint32(pos.Epoch) << 16) | uint32(pos.Block)
	blockTree, ok := t.finalizedBlockTrees[blockKey]
	if !ok {
		return nil, fmt.Errorf("block (%d, %d) not finalized", pos.Epoch, pos.Block)
	}

	epochTree, ok := t.finalizedEpochTrees[pos.Epoch]
	if !ok {
		return nil, fmt.Errorf("epoch %d not finalized", pos.Epoch)
	}

	// Get the finalized root (anchor)
	root, err := t.eternityTree.GetHash()
	if err != nil {
		return nil, fmt.Errorf("failed to get root: %w", err)
	}

	proof := &TCTProof{
		Position: pos,
		Root:     root,
	}

	// Generate commitment-tier proof from finalized block tree
	commitProof, commitment, err := t.generateTierProof(blockTree, pos.Commitment)
	if err != nil {
		return nil, fmt.Errorf("failed to generate commitment proof: %w", err)
	}
	proof.CommitmentProof = commitProof
	proof.Commitment = commitment

	// Get block root from finalized epoch tree
	blockRoot, ok := t.blockRoots[blockKey]
	if !ok {
		return nil, fmt.Errorf("block root not found for (%d, %d)", pos.Epoch, pos.Block)
	}

	// Generate block-tier proof from finalized epoch tree
	blockProof, _, err := t.generateTierProofWithLeafHash(epochTree, pos.Block, blockRoot)
	if err != nil {
		return nil, fmt.Errorf("failed to generate block proof: %w", err)
	}
	proof.BlockProof = blockProof

	// Get epoch root
	epochRoot, ok := t.epochRoots[pos.Epoch]
	if !ok {
		return nil, fmt.Errorf("epoch root not found for %d", pos.Epoch)
	}

	// Generate epoch-tier proof from eternity tree
	epochProof, _, err := t.generateTierProofWithLeafHash(t.eternityTree, pos.Epoch, epochRoot)
	if err != nil {
		return nil, fmt.Errorf("failed to generate epoch proof: %w", err)
	}
	proof.EpochProof = epochProof

	return proof, nil
}

// generateTierProof generates a proof within a single tier.
func (t *TieredCommitmentTree) generateTierProof(tree *QuaternaryTree, index uint16) (*TierProof, []byte, error) {
	path := tree.computePath(index)

	proof := &TierProof{
		Tier:      tree.Tier,
		Path:      make([][3][]byte, QuaternaryLevels),
		LeafIndex: index,
	}

	// Navigate the tree and collect siblings
	current := tree.Root
	for level := 0; level < QuaternaryLevels; level++ {
		if current == nil || current.IsSummary() {
			return nil, nil, fmt.Errorf("incomplete tree path at level %d", level)
		}

		childIdx := path[level]

		// Collect sibling hashes (all children except the one we're traversing)
		sibIdx := 0
		for i := uint8(0); i < QuaternaryBranchingFactor; i++ {
			if i == childIdx {
				continue
			}

			sibling := current.GetChild(i)
			if sibling == nil {
				// Use empty hash for missing siblings
				proof.Path[level][sibIdx] = t.hasher.HashTCTEmpty(uint8(tree.Tier), uint8(level+1))
			} else {
				sibHash, err := tree.computeNodeHash(sibling)
				if err != nil {
					return nil, nil, fmt.Errorf("failed to compute sibling hash: %w", err)
				}
				proof.Path[level][sibIdx] = sibHash
			}
			sibIdx++
		}

		// Move to next level
		current = current.GetChild(childIdx)
	}

	// Get leaf data
	if current != nil {
		proof.LeafHash = current.GetHash()
		return proof, current.Commitment, nil
	}

	return nil, nil, fmt.Errorf("leaf not found at index %d", index)
}

// generateTierProofWithLeafHash generates a proof when we already know the leaf hash.
func (t *TieredCommitmentTree) generateTierProofWithLeafHash(tree *QuaternaryTree, index uint16, leafHash []byte) (*TierProof, []byte, error) {
	path := tree.computePath(index)

	proof := &TierProof{
		Tier:      tree.Tier,
		Path:      make([][3][]byte, QuaternaryLevels),
		LeafIndex: index,
		LeafHash:  leafHash,
	}

	// Navigate the tree and collect siblings
	current := tree.Root
	for level := 0; level < QuaternaryLevels; level++ {
		if current == nil {
			// Use empty hashes for missing path
			for i := 0; i < 3; i++ {
				proof.Path[level][i] = t.hasher.HashTCTEmpty(uint8(tree.Tier), uint8(level+1))
			}
			continue
		}

		if current.IsSummary() {
			return nil, nil, fmt.Errorf("cannot generate proof through summary node at level %d", level)
		}

		childIdx := path[level]

		// Collect sibling hashes
		sibIdx := 0
		for i := uint8(0); i < QuaternaryBranchingFactor; i++ {
			if i == childIdx {
				continue
			}

			sibling := current.GetChild(i)
			if sibling == nil {
				proof.Path[level][sibIdx] = t.hasher.HashTCTEmpty(uint8(tree.Tier), uint8(level+1))
			} else {
				sibHash, err := tree.computeNodeHash(sibling)
				if err != nil {
					return nil, nil, fmt.Errorf("failed to compute sibling hash: %w", err)
				}
				proof.Path[level][sibIdx] = sibHash
			}
			sibIdx++
		}

		current = current.GetChild(childIdx)
	}

	return proof, nil, nil
}

// VerifyProof verifies a TCT proof against a root hash.
func VerifyProof(proof *TCTProof, hasher hash.QuaternaryHasher) (bool, error) {
	if proof == nil {
		return false, fmt.Errorf("nil proof")
	}

	// Verify commitment tier proof
	// The commitment is hashed as a leaf in the block tree (TierCommitment)
	commitmentHash := hasher.HashTCTLeaf(uint8(TierCommitment), proof.Commitment)
	blockRoot, err := verifyTierProof(proof.CommitmentProof, commitmentHash, hasher)
	if err != nil {
		return false, fmt.Errorf("commitment proof invalid: %w", err)
	}

	// Verify block tier proof
	// The block root is hashed as a leaf in the epoch tree (TierEpoch)
	blockRootLeafHash := hasher.HashTCTLeaf(uint8(TierEpoch), blockRoot)
	epochRoot, err := verifyTierProof(proof.BlockProof, blockRootLeafHash, hasher)
	if err != nil {
		return false, fmt.Errorf("block proof invalid: %w", err)
	}

	// Verify epoch tier proof
	// The epoch root is hashed as a leaf in the eternity tree (TierEternity)
	epochRootLeafHash := hasher.HashTCTLeaf(uint8(TierEternity), epochRoot)
	computedRoot, err := verifyTierProof(proof.EpochProof, epochRootLeafHash, hasher)
	if err != nil {
		return false, fmt.Errorf("epoch proof invalid: %w", err)
	}

	// Compare computed root with expected root
	if !bytes.Equal(computedRoot, proof.Root) {
		return false, fmt.Errorf("root mismatch: computed %x, expected %x", computedRoot, proof.Root)
	}

	return true, nil
}

// verifyTierProof verifies a single-tier proof and returns the computed root.
func verifyTierProof(proof *TierProof, leafHash []byte, hasher hash.QuaternaryHasher) ([]byte, error) {
	if proof == nil {
		return nil, fmt.Errorf("nil tier proof")
	}

	if len(proof.Path) != QuaternaryLevels {
		return nil, fmt.Errorf("invalid path length: %d, expected %d", len(proof.Path), QuaternaryLevels)
	}

	// Compute the path from leaf to root
	path := computePathFromIndex(proof.LeafIndex)
	currentHash := leafHash

	// Traverse from leaf to root
	for level := QuaternaryLevels - 1; level >= 0; level-- {
		childIdx := path[level]
		siblings := proof.Path[level]

		// Reconstruct the 4 child hashes
		var children [4][]byte
		sibIdx := 0
		for i := uint8(0); i < QuaternaryBranchingFactor; i++ {
			if i == childIdx {
				children[i] = currentHash
			} else {
				if sibIdx >= len(siblings) {
					return nil, fmt.Errorf("insufficient siblings at level %d", level)
				}
				children[i] = siblings[sibIdx]
				sibIdx++
			}
		}

		// Compute parent hash
		currentHash = hasher.HashQuaternaryWithDomainSep(uint8(proof.Tier), uint8(level), children)
	}

	return currentHash, nil
}

// computePathFromIndex computes the quaternary path for a leaf index.
func computePathFromIndex(index uint16) [QuaternaryLevels]uint8 {
	var path [QuaternaryLevels]uint8
	for level := QuaternaryLevels - 1; level >= 0; level-- {
		path[level] = uint8(index & 0x03)
		index >>= 2
	}
	return path
}

// Serialize encodes a TCT proof to bytes.
func (p *TCTProof) Serialize() ([]byte, error) {
	buf := bytes.NewBuffer(nil)

	// Write position (8 bytes)
	buf.Write(p.Position.ToBytes())

	// Write commitment
	if err := writeBytes(buf, p.Commitment); err != nil {
		return nil, err
	}

	// Write root
	if err := writeBytes(buf, p.Root); err != nil {
		return nil, err
	}

	// Write tier proofs
	if err := serializeTierProof(buf, p.CommitmentProof); err != nil {
		return nil, err
	}
	if err := serializeTierProof(buf, p.BlockProof); err != nil {
		return nil, err
	}
	if err := serializeTierProof(buf, p.EpochProof); err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}

// DeserializeProof decodes a TCT proof from bytes.
func DeserializeProof(data []byte) (*TCTProof, error) {
	if len(data) < 8 {
		return nil, fmt.Errorf("proof data too short")
	}

	buf := bytes.NewReader(data)

	// Read position
	posBytes := make([]byte, 8)
	if _, err := buf.Read(posBytes); err != nil {
		return nil, err
	}
	pos, err := PositionFromBytes(posBytes)
	if err != nil {
		return nil, err
	}

	// Read commitment
	commitment, err := readBytes(buf)
	if err != nil {
		return nil, err
	}

	// Read root
	root, err := readBytes(buf)
	if err != nil {
		return nil, err
	}

	// Read tier proofs
	commitProof, err := deserializeTierProof(buf)
	if err != nil {
		return nil, err
	}

	blockProof, err := deserializeTierProof(buf)
	if err != nil {
		return nil, err
	}

	epochProof, err := deserializeTierProof(buf)
	if err != nil {
		return nil, err
	}

	return &TCTProof{
		Position:        pos,
		Commitment:      commitment,
		Root:            root,
		CommitmentProof: commitProof,
		BlockProof:      blockProof,
		EpochProof:      epochProof,
	}, nil
}

func serializeTierProof(buf *bytes.Buffer, proof *TierProof) error {
	if proof == nil {
		buf.WriteByte(0)
		return nil
	}
	buf.WriteByte(1)

	// Tier and leaf index
	buf.WriteByte(byte(proof.Tier))
	binary.Write(buf, binary.BigEndian, proof.LeafIndex)

	// Leaf hash
	if err := writeBytes(buf, proof.LeafHash); err != nil {
		return err
	}

	// Path
	for level := 0; level < QuaternaryLevels; level++ {
		for i := 0; i < 3; i++ {
			if err := writeBytes(buf, proof.Path[level][i]); err != nil {
				return err
			}
		}
	}

	return nil
}

func deserializeTierProof(buf *bytes.Reader) (*TierProof, error) {
	present, err := buf.ReadByte()
	if err != nil {
		return nil, err
	}
	if present == 0 {
		return nil, nil
	}

	tierByte, err := buf.ReadByte()
	if err != nil {
		return nil, err
	}

	var leafIndex uint16
	if err := binary.Read(buf, binary.BigEndian, &leafIndex); err != nil {
		return nil, err
	}

	leafHash, err := readBytes(buf)
	if err != nil {
		return nil, err
	}

	proof := &TierProof{
		Tier:      Tier(tierByte),
		LeafIndex: leafIndex,
		LeafHash:  leafHash,
		Path:      make([][3][]byte, QuaternaryLevels),
	}

	for level := 0; level < QuaternaryLevels; level++ {
		for i := 0; i < 3; i++ {
			proof.Path[level][i], err = readBytes(buf)
			if err != nil {
				return nil, err
			}
		}
	}

	return proof, nil
}

func writeBytes(buf *bytes.Buffer, data []byte) error {
	if err := binary.Write(buf, binary.BigEndian, uint32(len(data))); err != nil {
		return err
	}
	buf.Write(data)
	return nil
}

func readBytes(buf *bytes.Reader) ([]byte, error) {
	var length uint32
	if err := binary.Read(buf, binary.BigEndian, &length); err != nil {
		return nil, err
	}
	if length == 0 {
		return nil, nil
	}
	data := make([]byte, length)
	if _, err := buf.Read(data); err != nil {
		return nil, err
	}
	return data, nil
}

// ProofStats contains statistics about a proof.
type ProofStats struct {
	// TotalSize is the total serialized size in bytes.
	TotalSize int

	// PathLevels is the number of levels in each tier.
	PathLevels int

	// SiblingsPerLevel is the number of sibling hashes per level (3 for quaternary).
	SiblingsPerLevel int

	// TotalSiblings is the total number of sibling hashes across all tiers.
	TotalSiblings int

	// HashSize is the size of each hash in bytes.
	HashSize int
}

// Stats computes statistics about a proof.
func (p *TCTProof) Stats() ProofStats {
	stats := ProofStats{
		PathLevels:       QuaternaryLevels,
		SiblingsPerLevel: QuaternaryBranchingFactor - 1,
		TotalSiblings:    3 * QuaternaryLevels * 3, // 3 tiers × 8 levels × 3 siblings
		HashSize:         32,
	}

	// Compute serialized size
	serialized, err := p.Serialize()
	if err == nil {
		stats.TotalSize = len(serialized)
	}

	return stats
}
