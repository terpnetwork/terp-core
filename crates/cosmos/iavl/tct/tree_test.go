package tct

import (
	"bytes"
	"crypto/rand"
	"testing"

	"github.com/cosmos/iavl/hash"
)

func randomCommitment() []byte {
	data := make([]byte, 32)
	rand.Read(data)
	return data
}

func TestQuaternaryTreeBasicOperations(t *testing.T) {
	config := DefaultQuaternaryTreeConfig(TierCommitment)
	tree := NewQuaternaryTree(config)

	// Test empty tree
	if !tree.IsEmpty() {
		t.Error("New tree should be empty")
	}

	if tree.Size() != 0 {
		t.Errorf("New tree size: got %d, want 0", tree.Size())
	}

	// Insert a commitment
	commitment := randomCommitment()
	idx, err := tree.Insert(commitment)
	if err != nil {
		t.Fatalf("Insert failed: %v", err)
	}

	if idx != 0 {
		t.Errorf("First insertion index: got %d, want 0", idx)
	}

	if tree.IsEmpty() {
		t.Error("Tree should not be empty after insertion")
	}

	if tree.Size() != 1 {
		t.Errorf("Tree size after insertion: got %d, want 1", tree.Size())
	}
}

func TestQuaternaryTreeMultipleInsertions(t *testing.T) {
	config := DefaultQuaternaryTreeConfig(TierCommitment)
	tree := NewQuaternaryTree(config)

	n := 100
	commitments := make([][]byte, n)

	for i := 0; i < n; i++ {
		commitments[i] = randomCommitment()
		idx, err := tree.Insert(commitments[i])
		if err != nil {
			t.Fatalf("Insert %d failed: %v", i, err)
		}
		if idx != uint64(i) {
			t.Errorf("Insert %d index: got %d, want %d", i, idx, i)
		}
	}

	if tree.Size() != uint64(n) {
		t.Errorf("Tree size: got %d, want %d", tree.Size(), n)
	}

	// Verify we can retrieve leaves
	for i := 0; i < n; i++ {
		leaf := tree.GetLeaf(uint16(i))
		if leaf == nil {
			t.Errorf("GetLeaf(%d) returned nil", i)
			continue
		}
		if !bytes.Equal(leaf.Commitment, commitments[i]) {
			t.Errorf("GetLeaf(%d) commitment mismatch", i)
		}
	}
}

func TestQuaternaryTreeHashComputation(t *testing.T) {
	config := DefaultQuaternaryTreeConfig(TierCommitment)
	tree := NewQuaternaryTree(config)

	// Get hash of empty tree
	emptyHash, err := tree.GetHash()
	if err != nil {
		t.Fatalf("GetHash on empty tree failed: %v", err)
	}
	if len(emptyHash) == 0 {
		t.Error("Empty tree hash should not be empty")
	}

	// Insert and get hash
	commitment := randomCommitment()
	tree.Insert(commitment)

	hash1, err := tree.GetHash()
	if err != nil {
		t.Fatalf("GetHash failed: %v", err)
	}

	// Hash should be different from empty
	if bytes.Equal(hash1, emptyHash) {
		t.Error("Hash after insertion should differ from empty hash")
	}

	// Insert another and verify hash changes
	tree.Insert(randomCommitment())
	hash2, err := tree.GetHash()
	if err != nil {
		t.Fatalf("GetHash failed: %v", err)
	}

	if bytes.Equal(hash1, hash2) {
		t.Error("Hash should change after another insertion")
	}
}

func TestQuaternaryTreeSummaryNode(t *testing.T) {
	config := DefaultQuaternaryTreeConfig(TierCommitment)
	tree := NewQuaternaryTree(config)

	// Insert a known hash as a summary
	summaryHash := randomCommitment()
	idx, err := tree.InsertSummary(summaryHash)
	if err != nil {
		t.Fatalf("InsertSummary failed: %v", err)
	}

	if idx != 0 {
		t.Errorf("InsertSummary index: got %d, want 0", idx)
	}

	// The summary should be retrievable
	leaf := tree.GetLeaf(0)
	if leaf == nil {
		t.Fatal("GetLeaf returned nil for summary")
	}

	if !leaf.IsSummary() {
		t.Error("Node should be a summary node")
	}
}

func TestQuaternaryTreeForget(t *testing.T) {
	config := DefaultQuaternaryTreeConfig(TierCommitment)
	tree := NewQuaternaryTree(config)

	// Insert a commitment
	commitment := randomCommitment()
	tree.Insert(commitment)

	// Compute hash first
	_, err := tree.GetHash()
	if err != nil {
		t.Fatalf("GetHash failed: %v", err)
	}

	// Forget the commitment
	err = tree.Forget(0)
	if err != nil {
		t.Fatalf("Forget failed: %v", err)
	}

	// The leaf should now be a summary
	leaf := tree.GetLeaf(0)
	if leaf == nil {
		t.Fatal("GetLeaf returned nil after forget")
	}

	if !leaf.IsSummary() {
		t.Error("Node should be summary after forget")
	}
}

func TestTieredCommitmentTreeBasic(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Test initial state
	stats := tct.Stats()
	if stats.CurrentEpoch != 0 || stats.CurrentBlock != 0 || stats.CurrentCommitment != 0 {
		t.Error("New TCT should start at position (0,0,0)")
	}

	// Insert a commitment
	commitment := randomCommitment()
	pos, err := tct.InsertCommitment(commitment, WitnessKeep)
	if err != nil {
		t.Fatalf("InsertCommitment failed: %v", err)
	}

	if pos.Epoch != 0 || pos.Block != 0 || pos.Commitment != 0 {
		t.Errorf("First position: got %v, want (0,0,0)", pos)
	}

	// Verify witnessed
	if !tct.IsWitnessed(pos) {
		t.Error("Position should be witnessed after WitnessKeep")
	}
}

func TestTieredCommitmentTreeEndBlock(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert some commitments
	for i := 0; i < 10; i++ {
		_, err := tct.InsertCommitment(randomCommitment(), WitnessNone)
		if err != nil {
			t.Fatalf("InsertCommitment %d failed: %v", i, err)
		}
	}

	// End the block
	blockRoot, err := tct.EndBlock()
	if err != nil {
		t.Fatalf("EndBlock failed: %v", err)
	}

	if len(blockRoot) == 0 {
		t.Error("Block root should not be empty")
	}

	// Verify position moved to next block
	pos := tct.CurrentPosition()
	if pos.Block != 1 {
		t.Errorf("Block index after EndBlock: got %d, want 1", pos.Block)
	}
	if pos.Commitment != 0 {
		t.Errorf("Commitment index after EndBlock: got %d, want 0", pos.Commitment)
	}

	// Insert more commitments in new block
	for i := 0; i < 5; i++ {
		_, err := tct.InsertCommitment(randomCommitment(), WitnessNone)
		if err != nil {
			t.Fatalf("InsertCommitment in block 2 failed: %v", err)
		}
	}

	// End second block
	blockRoot2, err := tct.EndBlock()
	if err != nil {
		t.Fatalf("EndBlock 2 failed: %v", err)
	}

	// Block roots should be different
	if bytes.Equal(blockRoot, blockRoot2) {
		t.Error("Different blocks should have different roots")
	}
}

func TestTieredCommitmentTreeEndEpoch(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert commitments and end a few blocks
	for block := 0; block < 3; block++ {
		for i := 0; i < 5; i++ {
			_, err := tct.InsertCommitment(randomCommitment(), WitnessNone)
			if err != nil {
				t.Fatalf("InsertCommitment failed: %v", err)
			}
		}
		if block < 2 { // Don't end last block, EndEpoch will handle it
			_, err := tct.EndBlock()
			if err != nil {
				t.Fatalf("EndBlock failed: %v", err)
			}
		}
	}

	// End the epoch
	epochRoot, err := tct.EndEpoch()
	if err != nil {
		t.Fatalf("EndEpoch failed: %v", err)
	}

	if len(epochRoot) == 0 {
		t.Error("Epoch root should not be empty")
	}

	// Verify position moved to next epoch
	pos := tct.CurrentPosition()
	if pos.Epoch != 1 {
		t.Errorf("Epoch index after EndEpoch: got %d, want 1", pos.Epoch)
	}
	if pos.Block != 0 {
		t.Errorf("Block index after EndEpoch: got %d, want 0", pos.Block)
	}
	if pos.Commitment != 0 {
		t.Errorf("Commitment index after EndEpoch: got %d, want 0", pos.Commitment)
	}
}

func TestTieredCommitmentTreeRootHash(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Get initial root (the finalized anchor)
	root1, err := tct.Root()
	if err != nil {
		t.Fatalf("Root failed: %v", err)
	}

	// Insert a commitment - the global root (anchor) should NOT change
	// because it only changes on EndEpoch (TCT semantics)
	tct.InsertCommitment(randomCommitment(), WitnessNone)
	root2, err := tct.Root()
	if err != nil {
		t.Fatalf("Root failed: %v", err)
	}

	// Global root should be the same (no finalization yet)
	if !bytes.Equal(root1, root2) {
		t.Error("Global root (anchor) should NOT change until EndEpoch")
	}

	// But the current block root SHOULD change after insertion
	blockRoot1, err := tct.CurrentBlockRoot()
	if err != nil {
		t.Fatalf("CurrentBlockRoot failed: %v", err)
	}

	tct.InsertCommitment(randomCommitment(), WitnessNone)
	blockRoot2, err := tct.CurrentBlockRoot()
	if err != nil {
		t.Fatalf("CurrentBlockRoot failed: %v", err)
	}

	if bytes.Equal(blockRoot1, blockRoot2) {
		t.Error("Block root should change after insertion")
	}

	// End block and epoch - now the global root should change
	tct.EndBlock()
	tct.EndEpoch()

	root3, err := tct.Root()
	if err != nil {
		t.Fatalf("Root failed: %v", err)
	}

	if bytes.Equal(root1, root3) {
		t.Error("Global root should change after EndEpoch")
	}
}

func TestTieredCommitmentTreeSparseSync(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Simulate sparse client receiving block roots
	blockRoot := randomCommitment()
	err := tct.InsertBlockRoot(blockRoot)
	if err != nil {
		t.Fatalf("InsertBlockRoot failed: %v", err)
	}

	// Position should advance
	pos := tct.CurrentPosition()
	if pos.Block != 1 {
		t.Errorf("Block after InsertBlockRoot: got %d, want 1", pos.Block)
	}

	// Insert epoch root
	epochRoot := randomCommitment()
	err = tct.InsertEpochRoot(epochRoot)
	if err != nil {
		t.Fatalf("InsertEpochRoot failed: %v", err)
	}

	pos = tct.CurrentPosition()
	if pos.Epoch != 1 {
		t.Errorf("Epoch after InsertEpochRoot: got %d, want 1", pos.Epoch)
	}
}

func TestTieredCommitmentTreeStats(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert some commitments with witnessing
	for i := 0; i < 10; i++ {
		witness := WitnessNone
		if i%2 == 0 {
			witness = WitnessKeep
		}
		tct.InsertCommitment(randomCommitment(), witness)
	}

	stats := tct.Stats()

	if stats.CommitsInBlock != 10 {
		t.Errorf("CommitsInBlock: got %d, want 10", stats.CommitsInBlock)
	}

	if stats.WitnessedCount != 5 {
		t.Errorf("WitnessedCount: got %d, want 5", stats.WitnessedCount)
	}
}

func TestTieredCommitmentTreeClear(t *testing.T) {
	config := DefaultTieredTreeConfig()
	tct := NewTieredCommitmentTree(config)

	// Insert some data
	for i := 0; i < 10; i++ {
		tct.InsertCommitment(randomCommitment(), WitnessKeep)
	}
	tct.EndBlock()
	tct.InsertCommitment(randomCommitment(), WitnessKeep)

	// Clear
	tct.Clear()

	// Verify reset
	stats := tct.Stats()
	if stats.CurrentEpoch != 0 || stats.CurrentBlock != 0 || stats.CurrentCommitment != 0 {
		t.Error("TCT should be reset after Clear")
	}
	if stats.WitnessedCount != 0 {
		t.Error("Witnessed count should be 0 after Clear")
	}
}

func TestQuaternaryHasherInterface(t *testing.T) {
	hasher := hash.NewPoseidonQuaternaryHasher()

	// Test HashQuaternary
	children := [4][]byte{
		randomCommitment(),
		randomCommitment(),
		randomCommitment(),
		randomCommitment(),
	}

	hash1 := hasher.HashQuaternary(children)
	if len(hash1) != 32 {
		t.Errorf("HashQuaternary output length: got %d, want 32", len(hash1))
	}

	// Same input should produce same hash
	hash2 := hasher.HashQuaternary(children)
	if !bytes.Equal(hash1, hash2) {
		t.Error("HashQuaternary should be deterministic")
	}

	// Different input should produce different hash
	children[0] = randomCommitment()
	hash3 := hasher.HashQuaternary(children)
	if bytes.Equal(hash1, hash3) {
		t.Error("HashQuaternary should produce different hash for different input")
	}
}

func TestQuaternaryHasherDomainSeparation(t *testing.T) {
	hasher := hash.NewPoseidonQuaternaryHasher()

	children := [4][]byte{
		randomCommitment(),
		randomCommitment(),
		randomCommitment(),
		randomCommitment(),
	}

	// Same children with different tier should produce different hash
	hash1 := hasher.HashQuaternaryWithDomainSep(0, 0, children)
	hash2 := hasher.HashQuaternaryWithDomainSep(1, 0, children)

	if bytes.Equal(hash1, hash2) {
		t.Error("Different tiers should produce different hashes")
	}

	// Same children with different level should produce different hash
	hash3 := hasher.HashQuaternaryWithDomainSep(0, 1, children)
	if bytes.Equal(hash1, hash3) {
		t.Error("Different levels should produce different hashes")
	}
}

func TestQuaternaryHasherEmptyHashes(t *testing.T) {
	hasher := hash.NewPoseidonQuaternaryHasher()

	// Empty hashes at different levels should be different
	empty0 := hasher.HashTCTEmpty(0, 0)
	empty1 := hasher.HashTCTEmpty(0, 1)

	if bytes.Equal(empty0, empty1) {
		t.Error("Empty hashes at different levels should be different")
	}

	// Empty hashes at different tiers should be different
	emptyTier0 := hasher.HashTCTEmpty(0, 0)
	emptyTier1 := hasher.HashTCTEmpty(1, 0)

	if bytes.Equal(emptyTier0, emptyTier1) {
		t.Error("Empty hashes at different tiers should be different")
	}

	// Same tier and level should return cached value
	empty0Again := hasher.HashTCTEmpty(0, 0)
	if !bytes.Equal(empty0, empty0Again) {
		t.Error("Empty hash should be cached and consistent")
	}
}
