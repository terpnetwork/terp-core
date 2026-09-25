package tct

import (
	"bytes"
	"crypto/rand"
	"testing"
)

func TestStateCommitmentAdapterBasic(t *testing.T) {
	config := DefaultAdapterConfig()
	adapter := NewStateCommitmentAdapter(config)

	// Add some key-value pairs
	key1 := []byte("key1")
	value1 := []byte("value1")

	pos1, err := adapter.CommitKeyValue(key1, value1)
	if err != nil {
		t.Fatalf("CommitKeyValue failed: %v", err)
	}

	if pos1.Epoch != 0 || pos1.Block != 0 || pos1.Commitment != 0 {
		t.Errorf("First commit position: got %v, want (0,0,0)", pos1)
	}

	// Add another
	key2 := []byte("key2")
	value2 := []byte("value2")

	pos2, err := adapter.CommitKeyValue(key2, value2)
	if err != nil {
		t.Fatalf("CommitKeyValue failed: %v", err)
	}

	if pos2.Commitment != 1 {
		t.Errorf("Second commit position: got commitment=%d, want 1", pos2.Commitment)
	}

	// Verify position lookups
	foundPos, ok := adapter.GetPosition(key1)
	if !ok {
		t.Error("GetPosition should find key1")
	}
	if foundPos != pos1 {
		t.Errorf("GetPosition key1: got %v, want %v", foundPos, pos1)
	}
}

func TestStateCommitmentAdapterEndBlock(t *testing.T) {
	config := DefaultAdapterConfig()
	adapter := NewStateCommitmentAdapter(config)

	// Add commitments
	for i := 0; i < 5; i++ {
		key := make([]byte, 8)
		rand.Read(key)
		value := make([]byte, 32)
		rand.Read(value)
		_, err := adapter.CommitKeyValue(key, value)
		if err != nil {
			t.Fatalf("CommitKeyValue %d failed: %v", i, err)
		}
	}

	// End block
	blockRoot, err := adapter.EndBlock()
	if err != nil {
		t.Fatalf("EndBlock failed: %v", err)
	}

	if len(blockRoot) == 0 {
		t.Error("Block root should not be empty")
	}

	stats := adapter.Stats()
	if stats.CurrentBlock != 1 {
		t.Errorf("CurrentBlock after EndBlock: got %d, want 1", stats.CurrentBlock)
	}
}

func TestStateCommitmentAdapterEndEpoch(t *testing.T) {
	config := DefaultAdapterConfig()
	adapter := NewStateCommitmentAdapter(config)

	// Add commitments across multiple blocks
	for block := 0; block < 3; block++ {
		for i := 0; i < 5; i++ {
			key := make([]byte, 8)
			rand.Read(key)
			value := make([]byte, 32)
			rand.Read(value)
			adapter.CommitKeyValue(key, value)
		}
		if block < 2 {
			adapter.EndBlock()
		}
	}

	// End epoch (will also end pending block)
	epochRoot, err := adapter.EndEpoch()
	if err != nil {
		t.Fatalf("EndEpoch failed: %v", err)
	}

	if len(epochRoot) == 0 {
		t.Error("Epoch root should not be empty")
	}

	stats := adapter.Stats()
	if stats.CurrentEpoch != 1 {
		t.Errorf("CurrentEpoch after EndEpoch: got %d, want 1", stats.CurrentEpoch)
	}
	if stats.CurrentBlock != 0 {
		t.Errorf("CurrentBlock after EndEpoch: got %d, want 0", stats.CurrentBlock)
	}
}

func TestStateCommitmentAdapterProof(t *testing.T) {
	config := DefaultAdapterConfig()
	config.WitnessAll = true
	adapter := NewStateCommitmentAdapter(config)

	// Add commitments
	key := []byte("test-key")
	value := []byte("test-value")

	pos, err := adapter.CommitKeyValue(key, value)
	if err != nil {
		t.Fatalf("CommitKeyValue failed: %v", err)
	}

	// Need to finalize before generating proof
	adapter.EndBlock()
	adapter.EndEpoch()

	// Generate proof
	proof, err := adapter.GenerateProofAtPosition(pos)
	if err != nil {
		t.Fatalf("GenerateProofAtPosition failed: %v", err)
	}

	// Verify proof
	valid, err := adapter.VerifyProof(proof)
	if err != nil {
		t.Fatalf("VerifyProof failed: %v", err)
	}
	if !valid {
		t.Error("Proof should be valid")
	}
}

func TestStateCommitmentAdapterRemoveKey(t *testing.T) {
	config := DefaultAdapterConfig()
	adapter := NewStateCommitmentAdapter(config)

	// Add a key
	key := []byte("key-to-remove")
	value := []byte("some-value")

	pos1, err := adapter.CommitKeyValue(key, value)
	if err != nil {
		t.Fatalf("CommitKeyValue failed: %v", err)
	}

	// Remove the key (adds tombstone)
	pos2, err := adapter.RemoveKey(key)
	if err != nil {
		t.Fatalf("RemoveKey failed: %v", err)
	}

	// Position should have advanced
	if pos2.Commitment <= pos1.Commitment {
		t.Error("Tombstone position should be after original")
	}

	// Position lookup should return the tombstone position
	foundPos, ok := adapter.GetPosition(key)
	if !ok {
		t.Error("GetPosition should find removed key")
	}
	if foundPos != pos2 {
		t.Errorf("GetPosition for removed key: got %v, want %v", foundPos, pos2)
	}
}

func TestStateCommitmentAdapterStats(t *testing.T) {
	config := DefaultAdapterConfig()
	adapter := NewStateCommitmentAdapter(config)

	// Add some keys
	for i := 0; i < 10; i++ {
		key := make([]byte, 8)
		rand.Read(key)
		value := make([]byte, 32)
		rand.Read(value)
		adapter.CommitKeyValue(key, value)
	}

	stats := adapter.Stats()

	if stats.TotalKeys != 10 {
		t.Errorf("TotalKeys: got %d, want 10", stats.TotalKeys)
	}
	if stats.PendingCommits != 10 {
		t.Errorf("PendingCommits: got %d, want 10", stats.PendingCommits)
	}
	if stats.CurrentCommitment != 10 {
		t.Errorf("CurrentCommitment: got %d, want 10", stats.CurrentCommitment)
	}
}

func TestStateCommitmentAdapterClear(t *testing.T) {
	config := DefaultAdapterConfig()
	adapter := NewStateCommitmentAdapter(config)

	// Add some data
	for i := 0; i < 5; i++ {
		key := make([]byte, 8)
		rand.Read(key)
		value := make([]byte, 32)
		rand.Read(value)
		adapter.CommitKeyValue(key, value)
	}
	adapter.EndBlock()

	// Clear
	adapter.Clear()

	stats := adapter.Stats()
	if stats.TotalKeys != 0 {
		t.Error("TotalKeys should be 0 after Clear")
	}
	if stats.CurrentEpoch != 0 || stats.CurrentBlock != 0 || stats.CurrentCommitment != 0 {
		t.Error("Position should be (0,0,0) after Clear")
	}
}

func TestStateCommitmentAdapterAutoEndBlock(t *testing.T) {
	config := DefaultAdapterConfig()
	config.AutoEndBlock = true
	config.BlockThreshold = 5
	adapter := NewStateCommitmentAdapter(config)

	// Add enough commitments to trigger auto-end-block
	for i := 0; i < 10; i++ {
		key := make([]byte, 8)
		rand.Read(key)
		value := make([]byte, 32)
		rand.Read(value)
		adapter.CommitKeyValue(key, value)
	}

	stats := adapter.Stats()
	// Should have auto-ended at least one block
	if stats.CurrentBlock < 1 {
		t.Errorf("Auto-end-block should have triggered: got block %d", stats.CurrentBlock)
	}
}

func TestStateCommitmentAdapterWitness(t *testing.T) {
	config := DefaultAdapterConfig()
	config.WitnessAll = false // Don't witness by default
	adapter := NewStateCommitmentAdapter(config)

	// Add a key
	key := []byte("witness-key")
	value := []byte("witness-value")
	adapter.CommitKeyValue(key, value)

	// Manually witness the key
	err := adapter.WitnessKey(key)
	if err != nil {
		t.Fatalf("WitnessKey failed: %v", err)
	}

	// Verify it's witnessed
	pos, _ := adapter.GetPosition(key)
	if !adapter.GetTCT().IsWitnessed(pos) {
		t.Error("Key should be witnessed")
	}

	// Forget the key
	err = adapter.ForgetKey(key)
	if err != nil {
		t.Fatalf("ForgetKey failed: %v", err)
	}

	// Should no longer be witnessed
	if adapter.GetTCT().IsWitnessed(pos) {
		t.Error("Key should not be witnessed after ForgetKey")
	}
}

func TestStateCommitmentAdapterSparseSync(t *testing.T) {
	config := DefaultAdapterConfig()
	adapter := NewStateCommitmentAdapter(config)

	// Insert block roots directly (sparse sync mode)
	blockRoot := make([]byte, 32)
	rand.Read(blockRoot)

	err := adapter.InsertBlockRoot(blockRoot)
	if err != nil {
		t.Fatalf("InsertBlockRoot failed: %v", err)
	}

	stats := adapter.Stats()
	if stats.CurrentBlock != 1 {
		t.Errorf("CurrentBlock after InsertBlockRoot: got %d, want 1", stats.CurrentBlock)
	}

	// Insert epoch root
	epochRoot := make([]byte, 32)
	rand.Read(epochRoot)

	err = adapter.InsertEpochRoot(epochRoot)
	if err != nil {
		t.Fatalf("InsertEpochRoot failed: %v", err)
	}

	stats = adapter.Stats()
	if stats.CurrentEpoch != 1 {
		t.Errorf("CurrentEpoch after InsertEpochRoot: got %d, want 1", stats.CurrentEpoch)
	}
}

func TestStateCommitmentAdapterRootConsistency(t *testing.T) {
	config := DefaultAdapterConfig()
	adapter := NewStateCommitmentAdapter(config)

	// Get initial root
	root1, err := adapter.Root()
	if err != nil {
		t.Fatalf("Root failed: %v", err)
	}

	// Add commitments and end epoch
	for i := 0; i < 5; i++ {
		key := make([]byte, 8)
		rand.Read(key)
		value := make([]byte, 32)
		rand.Read(value)
		adapter.CommitKeyValue(key, value)
	}
	adapter.EndBlock()
	adapter.EndEpoch()

	// Root should have changed
	root2, err := adapter.Root()
	if err != nil {
		t.Fatalf("Root failed: %v", err)
	}

	if bytes.Equal(root1, root2) {
		t.Error("Root should change after EndEpoch")
	}
}
