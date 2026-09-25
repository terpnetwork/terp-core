// Package tct implements a Tiered Commitment Tree (TCT) design inspired by Penumbra's TCT.
// The TCT uses quaternary (4-ary) tree structure organized in tiers for efficient
// ZK-circuit operations with Poseidon hashing.
package tct

import (
	"encoding/binary"
	"fmt"
)

// Tier represents the level in the tiered tree hierarchy.
type Tier uint8

const (
	// TierCommitment is the leaf level containing state commitments.
	TierCommitment Tier = iota
	// TierBlock contains block roots (up to 65,536 commitments per block).
	TierBlock
	// TierEpoch contains epoch roots (up to 65,536 blocks per epoch).
	TierEpoch
	// TierEternity is the global root level (up to 65,536 epochs).
	TierEternity
)

// String returns the string representation of a tier.
func (t Tier) String() string {
	switch t {
	case TierCommitment:
		return "commitment"
	case TierBlock:
		return "block"
	case TierEpoch:
		return "epoch"
	case TierEternity:
		return "eternity"
	default:
		return fmt.Sprintf("unknown(%d)", t)
	}
}

// Position represents a unique location in the tiered commitment tree.
// Each position uniquely identifies a commitment within the tree structure.
type Position struct {
	Epoch      uint16 // 0 .. 65,535 epochs
	Block      uint16 // 0 .. 65,535 blocks per epoch
	Commitment uint16 // 0 .. 65,535 commitments per block
}

// MaxIndex is the maximum index at each tier (2^16 - 1).
const MaxIndex uint16 = 65535

// QuaternaryLevels is the number of quaternary levels per tier (log4(65536) = 8).
const QuaternaryLevels = 8

// QuaternaryBranchingFactor is the number of children per internal node.
const QuaternaryBranchingFactor = 4

// NewPosition creates a new position from epoch, block, and commitment indices.
func NewPosition(epoch, block, commitment uint16) Position {
	return Position{
		Epoch:      epoch,
		Block:      block,
		Commitment: commitment,
	}
}

// ToUint64 encodes the position as a 64-bit integer.
// Format: (epoch << 32) | (block << 16) | commitment
func (p Position) ToUint64() uint64 {
	return (uint64(p.Epoch) << 32) | (uint64(p.Block) << 16) | uint64(p.Commitment)
}

// PositionFromUint64 decodes a position from a 64-bit integer.
func PositionFromUint64(pos uint64) Position {
	return Position{
		Epoch:      uint16((pos >> 32) & 0xFFFF),
		Block:      uint16((pos >> 16) & 0xFFFF),
		Commitment: uint16(pos & 0xFFFF),
	}
}

// ToBytes encodes the position as bytes (8 bytes).
func (p Position) ToBytes() []byte {
	buf := make([]byte, 8)
	binary.BigEndian.PutUint64(buf, p.ToUint64())
	return buf
}

// PositionFromBytes decodes a position from bytes.
func PositionFromBytes(data []byte) (Position, error) {
	if len(data) < 8 {
		return Position{}, fmt.Errorf("position data too short: expected 8 bytes, got %d", len(data))
	}
	return PositionFromUint64(binary.BigEndian.Uint64(data)), nil
}

// String returns a string representation of the position.
func (p Position) String() string {
	return fmt.Sprintf("Position{epoch=%d, block=%d, commitment=%d}", p.Epoch, p.Block, p.Commitment)
}

// IsZero returns true if this is the zero position.
func (p Position) IsZero() bool {
	return p.Epoch == 0 && p.Block == 0 && p.Commitment == 0
}

// Next returns the next position in sequence, handling tier overflow.
// Returns the incremented position and whether an overflow occurred at each tier.
func (p Position) Next() (Position, bool, bool, bool) {
	var commitmentOverflow, blockOverflow, epochOverflow bool

	next := p
	next.Commitment++
	if next.Commitment == 0 { // overflow
		commitmentOverflow = true
		next.Block++
		if next.Block == 0 { // overflow
			blockOverflow = true
			next.Epoch++
			if next.Epoch == 0 { // overflow
				epochOverflow = true
			}
		}
	}
	return next, commitmentOverflow, blockOverflow, epochOverflow
}

// QuaternaryPath returns the path from root to this position within a tier.
// The path is a sequence of child indices (0-3) at each level.
// The tier parameter determines which index component to use.
func (p Position) QuaternaryPath(tier Tier) []uint8 {
	var index uint16
	switch tier {
	case TierCommitment:
		index = p.Commitment
	case TierBlock:
		index = p.Block
	case TierEpoch:
		index = p.Epoch
	default:
		return nil
	}

	// Each level extracts 2 bits (for 4-way branching)
	// Level 0 is the root, level 7 is just above leaves
	path := make([]uint8, QuaternaryLevels)
	for level := QuaternaryLevels - 1; level >= 0; level-- {
		path[level] = uint8(index & 0x03) // Extract lowest 2 bits
		index >>= 2
	}
	return path
}

// QuaternaryIndex computes the node index at a specific level within a tier.
// Level 0 is the root, level 7 is just above leaves.
func (p Position) QuaternaryIndex(tier Tier, level int) uint16 {
	var index uint16
	switch tier {
	case TierCommitment:
		index = p.Commitment
	case TierBlock:
		index = p.Block
	case TierEpoch:
		index = p.Epoch
	default:
		return 0
	}

	// Shift right to get the index at the specified level
	// Level 0 = full index >> 14, level 7 = full index >> 0
	shift := uint(2 * (QuaternaryLevels - 1 - level))
	return index >> shift
}

// ChildIndex returns which child (0-3) this position corresponds to at a given level.
func (p Position) ChildIndex(tier Tier, level int) uint8 {
	var index uint16
	switch tier {
	case TierCommitment:
		index = p.Commitment
	case TierBlock:
		index = p.Block
	case TierEpoch:
		index = p.Epoch
	default:
		return 0
	}

	// Extract the 2 bits at the specified level
	shift := uint(2 * (QuaternaryLevels - 1 - level))
	return uint8((index >> shift) & 0x03)
}

// Frontier represents the current insertion frontier in the tree.
// It tracks the rightmost path for efficient append operations.
type Frontier struct {
	// CurrentPosition is the next position to be filled
	CurrentPosition Position

	// EpochFrontier tracks the current epoch's frontier
	EpochFrontier *TierFrontier

	// BlockFrontier tracks the current block's frontier
	BlockFrontier *TierFrontier

	// CommitmentFrontier tracks the current commitment frontier
	CommitmentFrontier *TierFrontier
}

// TierFrontier tracks the frontier state for a single tier.
type TierFrontier struct {
	// Index is the current index being filled
	Index uint16

	// PathHashes contains the sibling hashes along the frontier path.
	// These are needed for computing the root hash.
	// Index i contains the hash at level i (0 = root level, 7 = leaf level)
	PathHashes [QuaternaryLevels][QuaternaryBranchingFactor - 1][]byte

	// IsDirty indicates whether the frontier has uncommitted changes
	IsDirty bool
}

// NewFrontier creates a new frontier starting at position zero.
func NewFrontier() *Frontier {
	return &Frontier{
		CurrentPosition:    Position{},
		EpochFrontier:      NewTierFrontier(),
		BlockFrontier:      NewTierFrontier(),
		CommitmentFrontier: NewTierFrontier(),
	}
}

// NewTierFrontier creates a new tier frontier.
func NewTierFrontier() *TierFrontier {
	return &TierFrontier{
		Index:   0,
		IsDirty: false,
	}
}

// GetFrontierForTier returns the appropriate frontier for a tier.
func (f *Frontier) GetFrontierForTier(tier Tier) *TierFrontier {
	switch tier {
	case TierCommitment:
		return f.CommitmentFrontier
	case TierBlock:
		return f.BlockFrontier
	case TierEpoch:
		return f.EpochFrontier
	default:
		return nil
	}
}

// PathIndex represents an index along the quaternary path.
type PathIndex struct {
	Level      int   // 0 = root, QuaternaryLevels-1 = leaf parent
	ChildIndex uint8 // 0-3 indicating which child
}

// ComputeSiblingIndices returns the sibling indices for a given path.
// These are the indices that would be needed for a Merkle proof.
func ComputeSiblingIndices(path []uint8) [][]PathIndex {
	siblings := make([][]PathIndex, len(path))
	for level, childIdx := range path {
		levelSiblings := make([]PathIndex, 0, QuaternaryBranchingFactor-1)
		for i := uint8(0); i < QuaternaryBranchingFactor; i++ {
			if i != childIdx {
				levelSiblings = append(levelSiblings, PathIndex{
					Level:      level,
					ChildIndex: i,
				})
			}
		}
		siblings[level] = levelSiblings
	}
	return siblings
}
