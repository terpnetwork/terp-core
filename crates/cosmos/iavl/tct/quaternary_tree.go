package tct

import (
	"fmt"
	"sync"

	"github.com/cosmos/iavl/hash"
)

// QuaternaryTree implements a single-tier quaternary sparse Merkle tree.
// This is the building block for the tiered commitment tree.
type QuaternaryTree struct {
	// Tier identifies which tier this tree belongs to.
	Tier Tier

	// Root is the root node of the tree.
	Root *Node

	// hasher is the quaternary hasher for computing node hashes.
	hasher hash.QuaternaryHasher

	// nodeCount tracks the number of leaves inserted.
	nodeCount uint64

	// nextIndex is the next available leaf index for insertion.
	nextIndex uint64

	// version tracks the tree version for cache invalidation.
	version int64

	// mu protects concurrent access to the tree.
	mu sync.RWMutex

	// lazyHashing enables semi-lazy hash computation.
	lazyHashing bool

	// nodeCache caches frequently accessed nodes by their key.
	nodeCache map[NodeKey]*Node

	// cacheSize is the maximum number of nodes to cache.
	cacheSize int
}

// QuaternaryTreeConfig holds configuration for creating a quaternary tree.
type QuaternaryTreeConfig struct {
	Tier        Tier
	Hasher      hash.QuaternaryHasher
	LazyHashing bool
	CacheSize   int
}

// DefaultQuaternaryTreeConfig returns the default configuration.
func DefaultQuaternaryTreeConfig(tier Tier) QuaternaryTreeConfig {
	return QuaternaryTreeConfig{
		Tier:        tier,
		Hasher:      hash.NewPoseidonQuaternaryHasher(),
		LazyHashing: true,
		CacheSize:   1024,
	}
}

// NewQuaternaryTree creates a new quaternary tree with the given configuration.
func NewQuaternaryTree(config QuaternaryTreeConfig) *QuaternaryTree {
	return &QuaternaryTree{
		Tier:        config.Tier,
		Root:        NewEmptyNode(config.Tier, 0, 0),
		hasher:      config.Hasher,
		lazyHashing: config.LazyHashing,
		nodeCache:   make(map[NodeKey]*Node),
		cacheSize:   config.CacheSize,
	}
}

// Insert adds a new commitment at the next available position.
// Returns the leaf index where the commitment was inserted.
func (t *QuaternaryTree) Insert(commitment []byte) (uint64, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.nextIndex > uint64(MaxIndex) {
		return 0, fmt.Errorf("tree capacity exceeded: max %d leaves", int(MaxIndex)+1)
	}

	index := t.nextIndex
	pos := uint16(index)

	// Create leaf node
	position := Position{Commitment: pos}
	leaf := NewLeafNode(t.Tier, index, commitment, &position)

	// Compute leaf hash immediately (leaves always have their hash computed)
	leafHash := t.hasher.HashTCTLeaf(uint8(t.Tier), commitment)
	leaf.SetHash(leafHash)

	// Insert into tree structure
	err := t.insertLeafAt(leaf, pos)
	if err != nil {
		return 0, err
	}

	t.nextIndex++
	t.nodeCount++
	t.version++

	return index, nil
}

// insertLeafAt inserts a leaf node at the specified index position.
func (t *QuaternaryTree) insertLeafAt(leaf *Node, index uint16) error {
	// Navigate/create path from root to leaf position
	path := t.computePath(index)

	current := t.Root
	for level := 0; level < QuaternaryLevels; level++ {
		childIdx := path[level]

		// Ensure current node is not a summary node
		if current.IsSummary() {
			return fmt.Errorf("cannot insert into summary node at level %d", level)
		}

		// Ensure current node has children array
		if current.State == NodeStateEmpty {
			current.State = NodeStateFull
		}

		// Get or create child node
		child := current.GetChild(childIdx)
		if child == nil {
			if level == QuaternaryLevels-1 {
				// At leaf parent level, set the leaf
				if err := current.SetChild(childIdx, leaf); err != nil {
					return err
				}
				// Mark path as dirty for lazy hashing
				t.markPathDirty(path[:level+1])
				return nil
			}

			// Create intermediate node
			childIndex := t.computeNodeIndex(path[:level+1])
			child = NewEmptyNode(t.Tier, level+1, childIndex)
			if err := current.SetChild(childIdx, child); err != nil {
				return err
			}
		}

		current = child
	}

	return fmt.Errorf("unexpected: reached end of path without inserting leaf")
}

// computePath returns the quaternary path from root to the given index.
// Each element is a child index (0-3) at that level.
func (t *QuaternaryTree) computePath(index uint16) [QuaternaryLevels]uint8 {
	var path [QuaternaryLevels]uint8
	for level := QuaternaryLevels - 1; level >= 0; level-- {
		path[level] = uint8(index & 0x03)
		index >>= 2
	}
	return path
}

// computeNodeIndex computes the node index from a partial path.
func (t *QuaternaryTree) computeNodeIndex(path []uint8) uint64 {
	var index uint64
	for _, childIdx := range path {
		index = (index << 2) | uint64(childIdx)
	}
	return index
}

// markPathDirty marks all nodes along a path as needing hash recomputation.
func (t *QuaternaryTree) markPathDirty(path []uint8) {
	current := t.Root
	current.MarkDirty()

	for _, childIdx := range path {
		child := current.GetChild(childIdx)
		if child != nil {
			child.MarkDirty()
			current = child
		} else {
			break
		}
	}
}

// GetHash computes and returns the root hash of the tree.
// If lazy hashing is enabled, this computes all dirty hashes.
func (t *QuaternaryTree) GetHash() ([]byte, error) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	if t.Root == nil {
		return t.hasher.EmptyHash(), nil
	}

	return t.computeNodeHash(t.Root)
}

// computeNodeHash recursively computes the hash of a node.
func (t *QuaternaryTree) computeNodeHash(node *Node) ([]byte, error) {
	if node == nil {
		return t.hasher.HashTCTEmpty(uint8(t.Tier), QuaternaryLevels), nil
	}

	// Return cached hash if not dirty
	if !node.IsHashDirty() && len(node.GetHash()) > 0 {
		return node.GetHash(), nil
	}

	// For summary nodes, the hash is already known
	if node.IsSummary() {
		return node.GetHash(), nil
	}

	// For leaf nodes, compute leaf hash
	if node.IsLeaf() {
		leafHash := t.hasher.HashTCTLeaf(uint8(t.Tier), node.Commitment)
		node.SetHash(leafHash)
		return leafHash, nil
	}

	// For internal nodes, compute hash from children
	var childHashes [4][]byte
	for i := uint8(0); i < QuaternaryBranchingFactor; i++ {
		child := node.GetChild(i)
		if child == nil {
			// Empty child - use empty hash for this level
			childHashes[i] = t.hasher.HashTCTEmpty(uint8(t.Tier), uint8(node.Level+1))
		} else {
			childHash, err := t.computeNodeHash(child)
			if err != nil {
				return nil, err
			}
			childHashes[i] = childHash
		}
	}

	hash := t.hasher.HashQuaternaryWithDomainSep(uint8(t.Tier), uint8(node.Level), childHashes)
	node.SetHash(hash)

	return hash, nil
}

// GetLeaf returns the leaf node at the given index, or nil if not found.
func (t *QuaternaryTree) GetLeaf(index uint16) *Node {
	t.mu.RLock()
	defer t.mu.RUnlock()

	path := t.computePath(index)
	current := t.Root

	for level := 0; level < QuaternaryLevels; level++ {
		if current == nil || current.IsSummary() {
			return nil
		}
		current = current.GetChild(path[level])
	}

	return current
}

// Forget prunes a leaf at the given index, converting it to a summary node.
// The subtree's hash is retained for proof verification.
func (t *QuaternaryTree) Forget(index uint16) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	path := t.computePath(index)
	current := t.Root

	// Navigate to parent of the leaf
	for level := 0; level < QuaternaryLevels-1; level++ {
		if current == nil || current.IsSummary() {
			return fmt.Errorf("cannot forget: path not fully materialized at level %d", level)
		}
		current = current.GetChild(path[level])
	}

	if current == nil {
		return fmt.Errorf("cannot forget: parent node not found")
	}

	// Get the leaf
	leaf := current.GetChild(path[QuaternaryLevels-1])
	if leaf == nil {
		return fmt.Errorf("cannot forget: leaf not found at index %d", index)
	}

	// Ensure leaf has a computed hash
	if leaf.IsHashDirty() || len(leaf.GetHash()) == 0 {
		leafHash := t.hasher.HashTCTLeaf(uint8(t.Tier), leaf.Commitment)
		leaf.SetHash(leafHash)
	}

	// Convert leaf to summary
	return leaf.Forget()
}

// InsertSummary inserts a summary hash at the next available position.
// This is used for sparse client representation.
func (t *QuaternaryTree) InsertSummary(hash []byte) (uint64, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.nextIndex > uint64(MaxIndex) {
		return 0, fmt.Errorf("tree capacity exceeded")
	}

	index := t.nextIndex
	pos := uint16(index)

	// Create summary node
	summary := NewSummaryNode(t.Tier, QuaternaryLevels, index, hash)

	// Insert into tree structure
	err := t.insertSummaryAt(summary, pos)
	if err != nil {
		return 0, err
	}

	t.nextIndex++
	t.nodeCount++
	t.version++

	return index, nil
}

// insertSummaryAt inserts a summary node at the specified position.
func (t *QuaternaryTree) insertSummaryAt(summary *Node, index uint16) error {
	path := t.computePath(index)

	current := t.Root
	for level := 0; level < QuaternaryLevels; level++ {
		childIdx := path[level]

		if current.IsSummary() {
			return fmt.Errorf("cannot insert into summary node at level %d", level)
		}

		if current.State == NodeStateEmpty {
			current.State = NodeStateFull
		}

		child := current.GetChild(childIdx)
		if child == nil {
			if level == QuaternaryLevels-1 {
				if err := current.SetChild(childIdx, summary); err != nil {
					return err
				}
				t.markPathDirty(path[:level+1])
				return nil
			}

			childIndex := t.computeNodeIndex(path[:level+1])
			child = NewEmptyNode(t.Tier, level+1, childIndex)
			if err := current.SetChild(childIdx, child); err != nil {
				return err
			}
		}

		current = child
	}

	return fmt.Errorf("unexpected: reached end of path without inserting summary")
}

// Size returns the number of leaves in the tree.
func (t *QuaternaryTree) Size() uint64 {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.nodeCount
}

// NextIndex returns the next available leaf index.
func (t *QuaternaryTree) NextIndex() uint64 {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.nextIndex
}

// Version returns the current tree version.
func (t *QuaternaryTree) Version() int64 {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.version
}

// IsEmpty returns true if the tree has no leaves.
func (t *QuaternaryTree) IsEmpty() bool {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.nodeCount == 0
}

// Clear resets the tree to an empty state.
func (t *QuaternaryTree) Clear() {
	t.mu.Lock()
	defer t.mu.Unlock()

	t.Root = NewEmptyNode(t.Tier, 0, 0)
	t.nodeCount = 0
	t.nextIndex = 0
	t.version++
	t.nodeCache = make(map[NodeKey]*Node)
}

// Finalize computes all pending hashes and returns the root hash.
// This is called at the end of a block/epoch to seal the tree.
func (t *QuaternaryTree) Finalize() ([]byte, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	return t.computeNodeHash(t.Root)
}

// GetHasher returns the quaternary hasher used by this tree.
func (t *QuaternaryTree) GetHasher() hash.QuaternaryHasher {
	return t.hasher
}

// SetHasher updates the hasher (primarily for testing).
func (t *QuaternaryTree) SetHasher(hasher hash.QuaternaryHasher) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.hasher = hasher
}

// collectNodes returns all materialized nodes in the tree.
func (t *QuaternaryTree) collectNodes() []*Node {
	t.mu.RLock()
	defer t.mu.RUnlock()

	var nodes []*Node
	t.collectNodesRecursive(t.Root, &nodes)
	return nodes
}

func (t *QuaternaryTree) collectNodesRecursive(node *Node, nodes *[]*Node) {
	if node == nil {
		return
	}

	*nodes = append(*nodes, node)

	if !node.IsLeaf() && !node.IsSummary() {
		for i := uint8(0); i < QuaternaryBranchingFactor; i++ {
			child := node.GetChild(i)
			t.collectNodesRecursive(child, nodes)
		}
	}
}
