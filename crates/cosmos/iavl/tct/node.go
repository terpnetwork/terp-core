package tct

import (
	"encoding/binary"
	"fmt"
	"sync"
)

// NodeState represents the state of a TCT node.
type NodeState uint8

const (
	// NodeStateEmpty indicates an empty/uninitialized node.
	NodeStateEmpty NodeState = iota
	// NodeStateFull indicates a fully materialized node with all children accessible.
	NodeStateFull
	// NodeStateSummary indicates a pruned node with only its hash retained (sparse representation).
	NodeStateSummary
	// NodeStateFrontier indicates a frontier node on the rightmost path.
	NodeStateFrontier
)

// String returns the string representation of a node state.
func (s NodeState) String() string {
	switch s {
	case NodeStateEmpty:
		return "empty"
	case NodeStateFull:
		return "full"
	case NodeStateSummary:
		return "summary"
	case NodeStateFrontier:
		return "frontier"
	default:
		return fmt.Sprintf("unknown(%d)", s)
	}
}

// Node represents a node in the quaternary TCT.
// It can be either an internal node (with up to 4 children) or a leaf node (containing a commitment).
type Node struct {
	// Tier indicates which tier this node belongs to.
	Tier Tier

	// Level indicates the height in the tree (0 = root, QuaternaryLevels = leaf level).
	Level int

	// Index is the position of this node at its level within its tier.
	Index uint64

	// State indicates the node's materialization state.
	State NodeState

	// Hash is the cached Poseidon hash of this node.
	// For summary nodes, this is the only data retained.
	Hash []byte

	// Children holds references to child nodes (nil for leaves or summary nodes).
	// For internal nodes, this has exactly 4 slots.
	Children [QuaternaryBranchingFactor]*Node

	// Commitment holds the leaf commitment value (only for leaf nodes at TierCommitment).
	Commitment []byte

	// Position holds the full position for commitment leaf nodes.
	Position *Position

	// Version tracks when this node was last modified.
	Version int64

	// mu protects concurrent access to mutable fields.
	mu sync.RWMutex

	// hashDirty indicates whether the hash needs recomputation.
	hashDirty bool
}

// NewEmptyNode creates a new empty internal node.
func NewEmptyNode(tier Tier, level int, index uint64) *Node {
	return &Node{
		Tier:      tier,
		Level:     level,
		Index:     index,
		State:     NodeStateEmpty,
		hashDirty: true,
	}
}

// NewLeafNode creates a new leaf node with a commitment.
func NewLeafNode(tier Tier, index uint64, commitment []byte, pos *Position) *Node {
	return &Node{
		Tier:       tier,
		Level:      QuaternaryLevels, // Leaf level
		Index:      index,
		State:      NodeStateFull,
		Commitment: commitment,
		Position:   pos,
		hashDirty:  true,
	}
}

// NewSummaryNode creates a node that only stores a hash (pruned subtree).
func NewSummaryNode(tier Tier, level int, index uint64, hash []byte) *Node {
	return &Node{
		Tier:      tier,
		Level:     level,
		Index:     index,
		State:     NodeStateSummary,
		Hash:      hash,
		hashDirty: false, // Hash is already known
	}
}

// IsLeaf returns true if this is a leaf node.
func (n *Node) IsLeaf() bool {
	return n.Level == QuaternaryLevels
}

// IsInternal returns true if this is an internal node.
func (n *Node) IsInternal() bool {
	return n.Level < QuaternaryLevels
}

// IsSummary returns true if this node is a summary (pruned) node.
func (n *Node) IsSummary() bool {
	return n.State == NodeStateSummary
}

// IsEmpty returns true if this node is empty.
func (n *Node) IsEmpty() bool {
	return n.State == NodeStateEmpty
}

// IsFull returns true if this node is fully materialized.
func (n *Node) IsFull() bool {
	return n.State == NodeStateFull
}

// SetChild sets a child node at the specified index (0-3).
func (n *Node) SetChild(childIndex uint8, child *Node) error {
	if childIndex >= QuaternaryBranchingFactor {
		return fmt.Errorf("child index %d out of range [0, %d)", childIndex, QuaternaryBranchingFactor)
	}
	if n.IsLeaf() {
		return fmt.Errorf("cannot set child on leaf node")
	}
	if n.IsSummary() {
		return fmt.Errorf("cannot set child on summary node")
	}

	n.mu.Lock()
	defer n.mu.Unlock()

	n.Children[childIndex] = child
	n.hashDirty = true

	// Update state based on children
	if n.State == NodeStateEmpty {
		n.State = NodeStateFull
	}

	return nil
}

// GetChild returns the child node at the specified index.
func (n *Node) GetChild(childIndex uint8) *Node {
	if childIndex >= QuaternaryBranchingFactor || n.IsLeaf() {
		return nil
	}
	n.mu.RLock()
	defer n.mu.RUnlock()
	return n.Children[childIndex]
}

// GetHash returns the cached hash or nil if not computed.
func (n *Node) GetHash() []byte {
	n.mu.RLock()
	defer n.mu.RUnlock()
	return n.Hash
}

// SetHash sets the hash value.
func (n *Node) SetHash(hash []byte) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.Hash = hash
	n.hashDirty = false
}

// IsHashDirty returns true if the hash needs recomputation.
func (n *Node) IsHashDirty() bool {
	n.mu.RLock()
	defer n.mu.RUnlock()
	return n.hashDirty
}

// MarkDirty marks the node's hash as needing recomputation.
func (n *Node) MarkDirty() {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.hashDirty = true
}

// ChildCount returns the number of non-nil children.
func (n *Node) ChildCount() int {
	if n.IsLeaf() {
		return 0
	}
	n.mu.RLock()
	defer n.mu.RUnlock()
	count := 0
	for _, child := range n.Children {
		if child != nil {
			count++
		}
	}
	return count
}

// Forget converts this node to a summary node, retaining only its hash.
// This is used for sparse representation to reduce memory usage.
func (n *Node) Forget() error {
	n.mu.Lock()
	defer n.mu.Unlock()

	if n.hashDirty || len(n.Hash) == 0 {
		return fmt.Errorf("cannot forget node without computed hash")
	}

	// Clear children and commitment
	n.Children = [QuaternaryBranchingFactor]*Node{}
	n.Commitment = nil
	n.State = NodeStateSummary

	return nil
}

// Clone creates a shallow copy of the node.
func (n *Node) Clone() *Node {
	n.mu.RLock()
	defer n.mu.RUnlock()

	clone := &Node{
		Tier:       n.Tier,
		Level:      n.Level,
		Index:      n.Index,
		State:      n.State,
		Hash:       append([]byte{}, n.Hash...),
		Commitment: append([]byte{}, n.Commitment...),
		Version:    n.Version,
		hashDirty:  n.hashDirty,
	}

	if n.Position != nil {
		pos := *n.Position
		clone.Position = &pos
	}

	// Shallow copy children references
	copy(clone.Children[:], n.Children[:])

	return clone
}

// NodeKey uniquely identifies a node in the tree.
type NodeKey struct {
	Tier  Tier
	Level int
	Index uint64
}

// ToBytes encodes the node key as bytes.
func (k NodeKey) ToBytes() []byte {
	buf := make([]byte, 11) // 1 + 1 + 1 + 8
	buf[0] = byte(k.Tier)
	buf[1] = byte(k.Level)
	binary.BigEndian.PutUint64(buf[2:], k.Index)
	return buf
}

// NodeKeyFromBytes decodes a node key from bytes.
func NodeKeyFromBytes(data []byte) (NodeKey, error) {
	if len(data) < 10 {
		return NodeKey{}, fmt.Errorf("node key data too short")
	}
	return NodeKey{
		Tier:  Tier(data[0]),
		Level: int(data[1]),
		Index: binary.BigEndian.Uint64(data[2:]),
	}, nil
}

// String returns a string representation of the node key.
func (k NodeKey) String() string {
	return fmt.Sprintf("NodeKey{tier=%s, level=%d, index=%d}", k.Tier, k.Level, k.Index)
}

// NodeSerializer handles node serialization/deserialization.
type NodeSerializer struct{}

// Serialize encodes a node to bytes.
func (s *NodeSerializer) Serialize(n *Node) ([]byte, error) {
	// Format:
	// - Tier (1 byte)
	// - Level (1 byte)
	// - State (1 byte)
	// - Index (8 bytes)
	// - Version (8 bytes)
	// - Hash length (4 bytes) + Hash
	// - Commitment length (4 bytes) + Commitment (if leaf)
	// - Position (8 bytes, if commitment leaf)
	// - Child hashes (for summary references)

	n.mu.RLock()
	defer n.mu.RUnlock()

	// Calculate size
	size := 1 + 1 + 1 + 8 + 8 // base fields
	size += 4 + len(n.Hash)
	if n.IsLeaf() {
		size += 4 + len(n.Commitment)
		if n.Position != nil {
			size += 8
		}
	}

	buf := make([]byte, 0, size)

	// Base fields
	buf = append(buf, byte(n.Tier))
	buf = append(buf, byte(n.Level))
	buf = append(buf, byte(n.State))

	indexBuf := make([]byte, 8)
	binary.BigEndian.PutUint64(indexBuf, n.Index)
	buf = append(buf, indexBuf...)

	versionBuf := make([]byte, 8)
	binary.BigEndian.PutUint64(versionBuf, uint64(n.Version))
	buf = append(buf, versionBuf...)

	// Hash
	hashLenBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(hashLenBuf, uint32(len(n.Hash)))
	buf = append(buf, hashLenBuf...)
	buf = append(buf, n.Hash...)

	// Commitment (if leaf)
	if n.IsLeaf() {
		commitLenBuf := make([]byte, 4)
		binary.BigEndian.PutUint32(commitLenBuf, uint32(len(n.Commitment)))
		buf = append(buf, commitLenBuf...)
		buf = append(buf, n.Commitment...)

		// Position
		if n.Position != nil {
			buf = append(buf, n.Position.ToBytes()...)
		}
	}

	return buf, nil
}

// Deserialize decodes a node from bytes.
func (s *NodeSerializer) Deserialize(data []byte) (*Node, error) {
	if len(data) < 19 { // minimum size
		return nil, fmt.Errorf("node data too short: %d bytes", len(data))
	}

	offset := 0

	tier := Tier(data[offset])
	offset++

	level := int(data[offset])
	offset++

	state := NodeState(data[offset])
	offset++

	index := binary.BigEndian.Uint64(data[offset:])
	offset += 8

	version := int64(binary.BigEndian.Uint64(data[offset:]))
	offset += 8

	hashLen := binary.BigEndian.Uint32(data[offset:])
	offset += 4

	if offset+int(hashLen) > len(data) {
		return nil, fmt.Errorf("invalid hash length")
	}
	hash := make([]byte, hashLen)
	copy(hash, data[offset:offset+int(hashLen)])
	offset += int(hashLen)

	node := &Node{
		Tier:      tier,
		Level:     level,
		Index:     index,
		State:     state,
		Hash:      hash,
		Version:   version,
		hashDirty: false,
	}

	// Read commitment if leaf
	if level == QuaternaryLevels && offset < len(data) {
		if offset+4 > len(data) {
			return nil, fmt.Errorf("invalid commitment length")
		}
		commitLen := binary.BigEndian.Uint32(data[offset:])
		offset += 4

		if offset+int(commitLen) > len(data) {
			return nil, fmt.Errorf("invalid commitment data")
		}
		node.Commitment = make([]byte, commitLen)
		copy(node.Commitment, data[offset:offset+int(commitLen)])
		offset += int(commitLen)

		// Read position if present
		if offset+8 <= len(data) {
			pos, err := PositionFromBytes(data[offset:])
			if err == nil {
				node.Position = &pos
			}
		}
	}

	return node, nil
}
