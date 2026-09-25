// Package tct provides a Tiered Commitment Tree (TCT) implementation
// for efficient ZK-friendly state commitments.
package tct

import (
	"fmt"
	"sync"

	"github.com/cosmos/iavl/hash"
)

// StateCommitmentAdapter bridges IAVL state changes to TCT commitments.
// It tracks key-value changes and converts them into TCT commitments
// for parallel ZK-friendly state tracking.
type StateCommitmentAdapter struct {
	// tct is the underlying tiered commitment tree
	tct *TieredCommitmentTree

	// hasher is used to compute commitment hashes from key-value pairs
	hasher hash.QuaternaryHasher

	// keyPositions maps keys to their TCT positions for proof generation
	keyPositions map[string]Position

	// positionKeys maps positions to keys for reverse lookup
	positionKeys map[uint64]string

	// pendingCommitments holds commitments for the current block
	pendingCommitments [][]byte

	// mu protects concurrent access
	mu sync.RWMutex

	// config holds the adapter configuration
	config AdapterConfig
}

// AdapterConfig holds configuration for the state commitment adapter.
type AdapterConfig struct {
	// Hasher is the quaternary hasher to use
	Hasher hash.QuaternaryHasher

	// WitnessAll if true, witnesses all commitments for proof generation
	WitnessAll bool

	// AutoEndBlock if true, automatically ends blocks at threshold
	AutoEndBlock bool

	// BlockThreshold is the number of commitments before auto-ending a block
	BlockThreshold int
}

// DefaultAdapterConfig returns the default adapter configuration.
func DefaultAdapterConfig() AdapterConfig {
	return AdapterConfig{
		Hasher:         hash.NewPoseidonQuaternaryHasher(),
		WitnessAll:     false,
		AutoEndBlock:   false,
		BlockThreshold: 10000,
	}
}

// NewStateCommitmentAdapter creates a new adapter for tracking IAVL state in TCT.
func NewStateCommitmentAdapter(config AdapterConfig) *StateCommitmentAdapter {
	if config.Hasher == nil {
		config.Hasher = hash.NewPoseidonQuaternaryHasher()
	}

	tctConfig := TieredTreeConfig{
		Hasher:      config.Hasher,
		LazyHashing: true,
		CacheSize:   1024,
	}

	return &StateCommitmentAdapter{
		tct:                NewTieredCommitmentTree(tctConfig),
		hasher:             config.Hasher,
		keyPositions:       make(map[string]Position),
		positionKeys:       make(map[uint64]string),
		pendingCommitments: make([][]byte, 0),
		config:             config,
	}
}

// CommitKeyValue adds a key-value pair as a commitment to the TCT.
// The commitment hash is computed as: H(key || H(value))
func (a *StateCommitmentAdapter) CommitKeyValue(key, value []byte) (Position, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Compute commitment from key-value pair
	commitment := a.computeCommitment(key, value)

	// Determine witness mode
	witness := WitnessNone
	if a.config.WitnessAll {
		witness = WitnessKeep
	}

	// Insert into TCT
	pos, err := a.tct.InsertCommitment(commitment, witness)
	if err != nil {
		return Position{}, fmt.Errorf("failed to insert commitment: %w", err)
	}

	// Track key-position mapping
	keyStr := string(key)
	a.keyPositions[keyStr] = pos
	a.positionKeys[pos.ToUint64()] = keyStr
	a.pendingCommitments = append(a.pendingCommitments, commitment)

	// Auto-end block if configured
	if a.config.AutoEndBlock && len(a.pendingCommitments) >= a.config.BlockThreshold {
		if _, err := a.tct.EndBlock(); err != nil {
			return pos, fmt.Errorf("auto end block failed: %w", err)
		}
		a.pendingCommitments = make([][]byte, 0)
	}

	return pos, nil
}

// RemoveKey marks a key as removed in the TCT by adding a tombstone commitment.
// This follows TCT's append-only semantics - we don't actually remove, we add a marker.
func (a *StateCommitmentAdapter) RemoveKey(key []byte) (Position, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Create tombstone commitment: H(key || TOMBSTONE_MARKER)
	tombstone := a.computeTombstone(key)

	witness := WitnessNone
	if a.config.WitnessAll {
		witness = WitnessKeep
	}

	pos, err := a.tct.InsertCommitment(tombstone, witness)
	if err != nil {
		return Position{}, fmt.Errorf("failed to insert tombstone: %w", err)
	}

	// Update position mapping (old position remains for historical proofs)
	keyStr := string(key)
	a.keyPositions[keyStr] = pos
	a.positionKeys[pos.ToUint64()] = keyStr
	a.pendingCommitments = append(a.pendingCommitments, tombstone)

	return pos, nil
}

// computeCommitment computes a TCT commitment from a key-value pair.
// Format: H(key_elements, value_hash_elements)
func (a *StateCommitmentAdapter) computeCommitment(key, value []byte) []byte {
	// Hash the value first
	valueHash := a.hasher.HashValue(value)

	// Combine key and value hash
	combined := make([]byte, 0, len(key)+len(valueHash))
	combined = append(combined, key...)
	combined = append(combined, valueHash...)

	// Return Poseidon hash of the combined data
	return a.hasher.HashTCTLeaf(uint8(TierCommitment), combined)
}

// tombstoneMarker is a special value indicating a deleted key
var tombstoneMarker = []byte{0xFF, 0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xFF}

// computeTombstone computes a tombstone commitment for a deleted key.
func (a *StateCommitmentAdapter) computeTombstone(key []byte) []byte {
	combined := make([]byte, 0, len(key)+len(tombstoneMarker))
	combined = append(combined, key...)
	combined = append(combined, tombstoneMarker...)
	return a.hasher.HashTCTLeaf(uint8(TierCommitment), combined)
}

// EndBlock finalizes the current block and returns its root.
func (a *StateCommitmentAdapter) EndBlock() ([]byte, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	root, err := a.tct.EndBlock()
	if err != nil {
		return nil, err
	}

	a.pendingCommitments = make([][]byte, 0)
	return root, nil
}

// EndEpoch finalizes the current epoch and returns its root.
func (a *StateCommitmentAdapter) EndEpoch() ([]byte, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	// End any pending block first
	if len(a.pendingCommitments) > 0 {
		if _, err := a.tct.EndBlock(); err != nil {
			return nil, fmt.Errorf("failed to end pending block: %w", err)
		}
		a.pendingCommitments = make([][]byte, 0)
	}

	return a.tct.EndEpoch()
}

// Root returns the current finalized root (anchor) of the TCT.
func (a *StateCommitmentAdapter) Root() ([]byte, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.tct.Root()
}

// CurrentBlockRoot returns the current working block root.
func (a *StateCommitmentAdapter) CurrentBlockRoot() ([]byte, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.tct.CurrentBlockRoot()
}

// GenerateProof generates a TCT proof for a key's commitment.
func (a *StateCommitmentAdapter) GenerateProof(key []byte) (*TCTProof, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()

	pos, ok := a.keyPositions[string(key)]
	if !ok {
		return nil, fmt.Errorf("key not found in TCT")
	}

	return a.tct.GenerateProofFinalized(pos)
}

// GenerateProofAtPosition generates a proof for a specific position.
func (a *StateCommitmentAdapter) GenerateProofAtPosition(pos Position) (*TCTProof, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.tct.GenerateProofFinalized(pos)
}

// GetPosition returns the TCT position for a key.
func (a *StateCommitmentAdapter) GetPosition(key []byte) (Position, bool) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	pos, ok := a.keyPositions[string(key)]
	return pos, ok
}

// GetKey returns the key for a TCT position.
func (a *StateCommitmentAdapter) GetKey(pos Position) (string, bool) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	key, ok := a.positionKeys[pos.ToUint64()]
	return key, ok
}

// WitnessKey marks a key's position for proof generation.
func (a *StateCommitmentAdapter) WitnessKey(key []byte) error {
	a.mu.Lock()
	defer a.mu.Unlock()

	pos, ok := a.keyPositions[string(key)]
	if !ok {
		return fmt.Errorf("key not found in TCT")
	}

	// Mark as witnessed (keep for proof generation)
	a.tct.witnessedPositions[pos.ToUint64()] = struct{}{}
	return nil
}

// ForgetKey removes witnessing for a key's position.
func (a *StateCommitmentAdapter) ForgetKey(key []byte) error {
	a.mu.Lock()
	defer a.mu.Unlock()

	pos, ok := a.keyPositions[string(key)]
	if !ok {
		return fmt.Errorf("key not found in TCT")
	}

	return a.tct.Forget(pos)
}

// Stats returns statistics about the adapter and TCT.
func (a *StateCommitmentAdapter) Stats() AdapterStats {
	a.mu.RLock()
	defer a.mu.RUnlock()

	tctStats := a.tct.Stats()
	return AdapterStats{
		TotalKeys:         len(a.keyPositions),
		PendingCommits:    len(a.pendingCommitments),
		CurrentEpoch:      tctStats.CurrentEpoch,
		CurrentBlock:      tctStats.CurrentBlock,
		CurrentCommitment: tctStats.CurrentCommitment,
		WitnessedCount:    tctStats.WitnessedCount,
	}
}

// AdapterStats holds statistics about the adapter.
type AdapterStats struct {
	TotalKeys         int
	PendingCommits    int
	CurrentEpoch      uint16
	CurrentBlock      uint16
	CurrentCommitment uint16
	WitnessedCount    uint64
}

// Clear resets the adapter to an empty state.
func (a *StateCommitmentAdapter) Clear() {
	a.mu.Lock()
	defer a.mu.Unlock()

	a.tct.Clear()
	a.keyPositions = make(map[string]Position)
	a.positionKeys = make(map[uint64]string)
	a.pendingCommitments = make([][]byte, 0)
}

// GetTCT returns the underlying TieredCommitmentTree for direct access.
// Use with caution - direct manipulation may break adapter state.
func (a *StateCommitmentAdapter) GetTCT() *TieredCommitmentTree {
	return a.tct
}

// GetHasher returns the quaternary hasher used by the adapter.
func (a *StateCommitmentAdapter) GetHasher() hash.QuaternaryHasher {
	return a.hasher
}

// InsertBlockRoot inserts a pre-computed block root for sparse sync.
func (a *StateCommitmentAdapter) InsertBlockRoot(blockRoot []byte) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.tct.InsertBlockRoot(blockRoot)
}

// InsertEpochRoot inserts a pre-computed epoch root for sparse sync.
func (a *StateCommitmentAdapter) InsertEpochRoot(epochRoot []byte) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.tct.InsertEpochRoot(epochRoot)
}

// VerifyProof verifies a TCT proof.
func (a *StateCommitmentAdapter) VerifyProof(proof *TCTProof) (bool, error) {
	return VerifyProof(proof, a.hasher)
}
