package tct

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"sync"

	"github.com/cosmos/iavl/hash"
	"github.com/emicklei/dot"
)

// WitnessMode determines how commitments are tracked for proof generation.
type WitnessMode uint8

const (
	// WitnessNone does not keep the commitment for proofs (sparse mode).
	WitnessNone WitnessMode = iota
	// WitnessKeep keeps the commitment path for later proof generation.
	WitnessKeep
)

// TieredCommitmentTree implements the full TCT structure with three tiers:
// Eternity (epochs) -> Epoch (blocks) -> Block (commitments)
type TieredCommitmentTree struct {
	// hasher is the quaternary hasher for all tiers.
	hasher hash.QuaternaryHasher

	// eternityTree is the top-level tree containing epoch roots.
	eternityTree *QuaternaryTree

	// currentEpochTree is the currently active epoch tree.
	currentEpochTree *QuaternaryTree

	// currentBlockTree is the currently active block tree.
	currentBlockTree *QuaternaryTree

	// frontier tracks the current insertion position.
	frontier *Frontier

	// witnessedPositions tracks positions that should be kept for proofs.
	witnessedPositions map[uint64]struct{}

	// epochRoots caches finalized epoch roots for proof generation.
	epochRoots map[uint16][]byte

	// blockRoots caches finalized block roots within current epoch.
	blockRoots map[uint32][]byte // key: (epoch << 16) | block

	// finalizedBlockTrees stores finalized block trees for proof generation.
	// Key format: (epoch << 16) | block
	finalizedBlockTrees map[uint32]*QuaternaryTree

	// finalizedEpochTrees stores finalized epoch trees for proof generation.
	finalizedEpochTrees map[uint16]*QuaternaryTree

	// version tracks the overall tree version.
	version int64

	// mu protects concurrent access.
	mu sync.RWMutex

	// config holds the tree configuration.
	config TieredTreeConfig
}

// TieredTreeConfig holds configuration for the tiered tree.
type TieredTreeConfig struct {
	// Hasher is the quaternary hasher to use.
	Hasher hash.QuaternaryHasher

	// LazyHashing enables semi-lazy hash computation.
	LazyHashing bool

	// CacheSize is the maximum number of nodes to cache per tier.
	CacheSize int
}

// DefaultTieredTreeConfig returns the default configuration.
func DefaultTieredTreeConfig() TieredTreeConfig {
	return TieredTreeConfig{
		Hasher:      hash.NewPoseidonQuaternaryHasher(),
		LazyHashing: true,
		CacheSize:   1024,
	}
}

// NewTieredCommitmentTree creates a new tiered commitment tree.
func NewTieredCommitmentTree(config TieredTreeConfig) *TieredCommitmentTree {
	if config.Hasher == nil {
		config.Hasher = hash.NewPoseidonQuaternaryHasher()
	}

	tct := &TieredCommitmentTree{
		hasher:              config.Hasher,
		frontier:            NewFrontier(),
		witnessedPositions:  make(map[uint64]struct{}),
		epochRoots:          make(map[uint16][]byte),
		blockRoots:          make(map[uint32][]byte),
		finalizedBlockTrees: make(map[uint32]*QuaternaryTree),
		finalizedEpochTrees: make(map[uint16]*QuaternaryTree),
		config:              config,
	}

	// Initialize all three tiers
	tct.eternityTree = tct.createTierTree(TierEternity)
	tct.currentEpochTree = tct.createTierTree(TierEpoch)
	tct.currentBlockTree = tct.createTierTree(TierCommitment)

	return tct
}

// createTierTree creates a new quaternary tree for the specified tier.
func (t *TieredCommitmentTree) createTierTree(tier Tier) *QuaternaryTree {
	return NewQuaternaryTree(QuaternaryTreeConfig{
		Tier:        tier,
		Hasher:      t.hasher,
		LazyHashing: t.config.LazyHashing,
		CacheSize:   t.config.CacheSize,
	})
}

// InsertCommitment adds a new commitment to the tree.
// Returns the position where the commitment was inserted.
func (t *TieredCommitmentTree) InsertCommitment(commitment []byte, witness WitnessMode) (Position, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	pos := t.frontier.CurrentPosition

	// Check if we need to start a new block or epoch
	if pos.Commitment > MaxIndex {
		return Position{}, fmt.Errorf("block capacity exceeded")
	}

	// Insert into current block tree
	_, err := t.currentBlockTree.Insert(commitment)
	if err != nil {
		return Position{}, fmt.Errorf("failed to insert commitment: %w", err)
	}

	// Track for witnessing if requested
	if witness == WitnessKeep {
		t.witnessedPositions[pos.ToUint64()] = struct{}{}
	}

	// Advance frontier
	nextPos, commitOverflow, blockOverflow, epochOverflow := pos.Next()
	t.frontier.CurrentPosition = nextPos
	t.frontier.CommitmentFrontier.Index = nextPos.Commitment
	t.frontier.CommitmentFrontier.IsDirty = true

	// Handle overflows (these indicate we've filled a tier)
	if commitOverflow {
		t.frontier.BlockFrontier.IsDirty = true
	}
	if blockOverflow {
		t.frontier.EpochFrontier.IsDirty = true
	}
	if epochOverflow {
		return Position{}, fmt.Errorf("eternity tree capacity exceeded")
	}

	t.version++

	return pos, nil
}

// EndBlock finalizes the current block and returns its root hash.
// The block root is then inserted into the current epoch tree.
func (t *TieredCommitmentTree) EndBlock() ([]byte, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	// Finalize current block tree
	blockRoot, err := t.currentBlockTree.Finalize()
	if err != nil {
		return nil, fmt.Errorf("failed to finalize block: %w", err)
	}

	// Cache the block root and tree for proof generation
	pos := t.frontier.CurrentPosition
	blockKey := (uint32(pos.Epoch) << 16) | uint32(pos.Block)
	t.blockRoots[blockKey] = blockRoot
	t.finalizedBlockTrees[blockKey] = t.currentBlockTree

	// Insert block root into epoch tree
	_, err = t.currentEpochTree.Insert(blockRoot)
	if err != nil {
		return nil, fmt.Errorf("failed to insert block root: %w", err)
	}

	// Create new block tree for next block
	t.currentBlockTree = t.createTierTree(TierCommitment)

	// Update frontier
	t.frontier.CurrentPosition.Block++
	if t.frontier.CurrentPosition.Block == 0 {
		// Block counter wrapped - this is handled by EndEpoch
		return nil, fmt.Errorf("block index overflow: call EndEpoch first")
	}
	t.frontier.CurrentPosition.Commitment = 0
	t.frontier.BlockFrontier.Index = t.frontier.CurrentPosition.Block
	t.frontier.CommitmentFrontier = NewTierFrontier()

	t.version++

	return blockRoot, nil
}

// EndEpoch finalizes the current epoch and returns its root hash.
// The epoch root is then inserted into the eternity tree.
func (t *TieredCommitmentTree) EndEpoch() ([]byte, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	pos := t.frontier.CurrentPosition

	// First, end the current block if it has any commitments
	if t.currentBlockTree.Size() > 0 {
		blockRoot, err := t.currentBlockTree.Finalize()
		if err != nil {
			return nil, fmt.Errorf("failed to finalize final block: %w", err)
		}

		blockKey := (uint32(pos.Epoch) << 16) | uint32(pos.Block)
		t.blockRoots[blockKey] = blockRoot
		t.finalizedBlockTrees[blockKey] = t.currentBlockTree

		_, err = t.currentEpochTree.Insert(blockRoot)
		if err != nil {
			return nil, fmt.Errorf("failed to insert final block root: %w", err)
		}
	}

	// Finalize current epoch tree
	epochRoot, err := t.currentEpochTree.Finalize()
	if err != nil {
		return nil, fmt.Errorf("failed to finalize epoch: %w", err)
	}

	// Cache the epoch root and tree for proof generation
	epochIndex := pos.Epoch
	t.epochRoots[epochIndex] = epochRoot
	t.finalizedEpochTrees[epochIndex] = t.currentEpochTree

	// Insert epoch root into eternity tree
	_, err = t.eternityTree.Insert(epochRoot)
	if err != nil {
		return nil, fmt.Errorf("failed to insert epoch root: %w", err)
	}

	// Create new trees for next epoch
	t.currentEpochTree = t.createTierTree(TierEpoch)
	t.currentBlockTree = t.createTierTree(TierCommitment)

	// Update frontier
	t.frontier.CurrentPosition.Epoch++
	t.frontier.CurrentPosition.Block = 0
	t.frontier.CurrentPosition.Commitment = 0
	t.frontier.EpochFrontier.Index = t.frontier.CurrentPosition.Epoch
	t.frontier.BlockFrontier = NewTierFrontier()
	t.frontier.CommitmentFrontier = NewTierFrontier()

	t.version++

	return epochRoot, nil
}

// Root returns the current root hash of the entire tree (the "anchor").
// This is the finalized eternity root and only changes when EndEpoch is called.
// For TCT semantics, proofs are made against finalized anchors.
func (t *TieredCommitmentTree) Root() ([]byte, error) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	return t.eternityTree.GetHash()
}

// CurrentBlockRoot returns the root hash of the current working block.
// This changes as commitments are inserted.
func (t *TieredCommitmentTree) CurrentBlockRoot() ([]byte, error) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	return t.currentBlockTree.GetHash()
}

// CurrentEpochRoot returns the root hash of the current epoch.
// This includes all finalized blocks in this epoch, but not the current working block.
func (t *TieredCommitmentTree) CurrentEpochRoot() ([]byte, error) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	return t.currentEpochTree.GetHash()
}

// Forget removes a commitment from active witnessing.
// The commitment's hash is retained but the full path is pruned.
func (t *TieredCommitmentTree) Forget(pos Position) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	posKey := pos.ToUint64()
	delete(t.witnessedPositions, posKey)

	// TODO: Implement actual node pruning in the tree structure
	// For now, just remove from witnessed set

	return nil
}

// IsWitnessed returns true if the position is being witnessed.
func (t *TieredCommitmentTree) IsWitnessed(pos Position) bool {
	t.mu.RLock()
	defer t.mu.RUnlock()

	_, ok := t.witnessedPositions[pos.ToUint64()]
	return ok
}

// InsertBlockRoot inserts a pre-computed block root (for sparse sync).
// This is used by clients who don't need the full block details.
func (t *TieredCommitmentTree) InsertBlockRoot(blockRoot []byte) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	_, err := t.currentEpochTree.InsertSummary(blockRoot)
	if err != nil {
		return fmt.Errorf("failed to insert block root summary: %w", err)
	}

	// Update frontier
	t.frontier.CurrentPosition.Block++
	t.frontier.BlockFrontier.Index = t.frontier.CurrentPosition.Block

	return nil
}

// InsertEpochRoot inserts a pre-computed epoch root (for sparse sync).
// This is used by clients who don't need the full epoch details.
func (t *TieredCommitmentTree) InsertEpochRoot(epochRoot []byte) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	_, err := t.eternityTree.InsertSummary(epochRoot)
	if err != nil {
		return fmt.Errorf("failed to insert epoch root summary: %w", err)
	}

	// Cache the epoch root
	epochIndex := t.frontier.CurrentPosition.Epoch
	t.epochRoots[epochIndex] = epochRoot

	// Update frontier
	t.frontier.CurrentPosition.Epoch++
	t.frontier.CurrentPosition.Block = 0
	t.frontier.CurrentPosition.Commitment = 0
	t.frontier.EpochFrontier.Index = t.frontier.CurrentPosition.Epoch

	// Reset lower tier frontiers
	t.currentEpochTree = t.createTierTree(TierEpoch)
	t.currentBlockTree = t.createTierTree(TierCommitment)
	t.frontier.BlockFrontier = NewTierFrontier()
	t.frontier.CommitmentFrontier = NewTierFrontier()

	return nil
}

// CurrentPosition returns the current insertion position.
func (t *TieredCommitmentTree) CurrentPosition() Position {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.frontier.CurrentPosition
}

// Version returns the current tree version.
func (t *TieredCommitmentTree) Version() int64 {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.version
}

// Stats returns statistics about the tree.
func (t *TieredCommitmentTree) Stats() TieredTreeStats {
	t.mu.RLock()
	defer t.mu.RUnlock()

	return TieredTreeStats{
		CurrentEpoch:      t.frontier.CurrentPosition.Epoch,
		CurrentBlock:      t.frontier.CurrentPosition.Block,
		CurrentCommitment: t.frontier.CurrentPosition.Commitment,
		TotalEpochs:       t.eternityTree.Size(),
		BlocksInEpoch:     t.currentEpochTree.Size(),
		CommitsInBlock:    t.currentBlockTree.Size(),
		WitnessedCount:    uint64(len(t.witnessedPositions)),
		Version:           t.version,
	}
}

// TieredTreeStats holds statistics about a tiered tree.
type TieredTreeStats struct {
	CurrentEpoch      uint16
	CurrentBlock      uint16
	CurrentCommitment uint16
	TotalEpochs       uint64
	BlocksInEpoch     uint64
	CommitsInBlock    uint64
	WitnessedCount    uint64
	Version           int64
}

// GetBlockRoot returns the cached root for a specific block.
func (t *TieredCommitmentTree) GetBlockRoot(epoch, block uint16) ([]byte, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	key := (uint32(epoch) << 16) | uint32(block)
	root, ok := t.blockRoots[key]
	return root, ok
}

// GetEpochRoot returns the cached root for a specific epoch.
func (t *TieredCommitmentTree) GetEpochRoot(epoch uint16) ([]byte, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	root, ok := t.epochRoots[epoch]
	return root, ok
}

// GetHasher returns the quaternary hasher used by the tree.
func (t *TieredCommitmentTree) GetHasher() hash.QuaternaryHasher {
	return t.hasher
}

// Clear resets the tree to an empty state.
func (t *TieredCommitmentTree) Clear() {
	t.mu.Lock()
	defer t.mu.Unlock()

	t.eternityTree = t.createTierTree(TierEternity)
	t.currentEpochTree = t.createTierTree(TierEpoch)
	t.currentBlockTree = t.createTierTree(TierCommitment)
	t.frontier = NewFrontier()
	t.witnessedPositions = make(map[uint64]struct{})
	t.epochRoots = make(map[uint16][]byte)
	t.blockRoots = make(map[uint32][]byte)
	t.finalizedBlockTrees = make(map[uint32]*QuaternaryTree)
	t.finalizedEpochTrees = make(map[uint16]*QuaternaryTree)
	t.version = 0
}

// WriteDOTGraphToFile writes a DOT graph visualization of the TCT to a file.
// This helps visualize the quaternary tree structure and tiered organization.
// The resulting file can be rendered with: dot -Tpng /tmp/tct.dot > tct.png
func WriteDOTGraphToFile(filename string, tct *TieredCommitmentTree) error {
	f, err := os.Create(filename)
	if err != nil {
		return err
	}
	defer f.Close()

	writer := bufio.NewWriter(f)
	defer writer.Flush()

	return WriteDOTGraph(writer, tct)
}

// WriteDOTGraph writes a DOT graph visualization of the TCT structure.
func WriteDOTGraph(w io.Writer, tct *TieredCommitmentTree) error {
	graph := dot.NewGraph(dot.Directed)
	graph.Attr("rankdir", "TB")
	graph.Attr("splines", "ortho")

	// Create subgraphs for each tier
	eternitySub := graph.Subgraph("Eternity", dot.ClusterOption{})
	epochSub := graph.Subgraph("Epoch", dot.ClusterOption{})
	blockSub := graph.Subgraph("Block", dot.ClusterOption{})

	// Visualize eternity tree (epoch roots)
	if tct.eternityTree != nil && tct.eternityTree.Root != nil {
		visualizeQuaternaryTree(eternitySub, tct.eternityTree.Root, "E", 0)
	}

	// Visualize current epoch tree (block roots)
	if tct.currentEpochTree != nil && tct.currentEpochTree.Root != nil {
		visualizeQuaternaryTree(epochSub, tct.currentEpochTree.Root, "EP", 0)
	}

	// Visualize current block tree (commitments)
	if tct.currentBlockTree != nil && tct.currentBlockTree.Root != nil {
		visualizeQuaternaryTree(blockSub, tct.currentBlockTree.Root, "B", 0)
	}

	// Add tier connections
	if tct.eternityTree != nil && tct.currentEpochTree != nil {
		eternityRoot := eternitySub.Node("E0")
		epochRoot := epochSub.Node("EP0")
		eternityRoot.Edge(epochRoot, "contains")
	}

	if tct.currentEpochTree != nil && tct.currentBlockTree != nil {
		epochRoot := epochSub.Node("EP0")
		blockRoot := blockSub.Node("B0")
		epochRoot.Edge(blockRoot, "contains")
	}

	_, err := w.Write([]byte(graph.String()))
	return err
}

// visualizeQuaternaryTree recursively builds DOT nodes for a quaternary tree.
func visualizeQuaternaryTree(graph *dot.Graph, node *Node, prefix string, depth int) {
	if node == nil || depth > 12 { // Limit depth to avoid huge graphs
		return
	}

	nodeID := fmt.Sprintf("%s%d", prefix, depth)
	var label string

	if node.IsLeaf() {
		if len(node.Commitment) > 4 {
			label = fmt.Sprintf("Leaf\\n%x", node.Commitment[:4])
		} else {
			label = fmt.Sprintf("Leaf\\n%x", node.Commitment)
		}
	} else {
		label = fmt.Sprintf("L:%d", node.Level)
	}

	dotNode := graph.Node(nodeID).Attr("label", label)
	dotNode.Attr("shape", "box").Attr("fontsize", "10")

	if node.IsLeaf() {
		dotNode.Attr("fillcolor", "lightblue").Attr("style", "filled")
	} else {
		dotNode.Attr("fillcolor", "lightgray").Attr("style", "filled")
	}

	// Add children edges (quaternary: 4 children)
	childrenAdded := 0
	for i, child := range node.Children {
		if child != nil {
			childID := fmt.Sprintf("%s%d_%d", prefix, depth+1, i)
			childNode := graph.Node(childID)
			dotNode.Edge(childNode).Attr("fontsize", "8")

			childrenAdded++
			// Always recurse to show the full quaternary structure, but limit depth
			visualizeQuaternaryTree(graph, child, fmt.Sprintf("%s%d_", prefix, depth+1), depth+1)
		}
	}

	// If this is an internal node with no children shown, add a note
	if !node.IsLeaf() && childrenAdded == 0 {
		dotNode.Attr("label", fmt.Sprintf("L:%d\\n(empty)", node.Level))
	}
}
