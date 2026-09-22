package tct

import (
	"testing"
)

func TestPositionEncoding(t *testing.T) {
	tests := []struct {
		name       string
		epoch      uint16
		block      uint16
		commitment uint16
	}{
		{"zero position", 0, 0, 0},
		{"first commitment", 0, 0, 1},
		{"first block", 0, 1, 0},
		{"first epoch", 1, 0, 0},
		{"mixed values", 123, 456, 789},
		{"max values", 65535, 65535, 65535},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pos := NewPosition(tt.epoch, tt.block, tt.commitment)

			// Test ToUint64 and back
			encoded := pos.ToUint64()
			decoded := PositionFromUint64(encoded)

			if decoded.Epoch != tt.epoch {
				t.Errorf("Epoch mismatch: got %d, want %d", decoded.Epoch, tt.epoch)
			}
			if decoded.Block != tt.block {
				t.Errorf("Block mismatch: got %d, want %d", decoded.Block, tt.block)
			}
			if decoded.Commitment != tt.commitment {
				t.Errorf("Commitment mismatch: got %d, want %d", decoded.Commitment, tt.commitment)
			}

			// Test ToBytes and back
			bytes := pos.ToBytes()
			decodedFromBytes, err := PositionFromBytes(bytes)
			if err != nil {
				t.Fatalf("PositionFromBytes error: %v", err)
			}

			if decodedFromBytes != pos {
				t.Errorf("Bytes round-trip mismatch: got %v, want %v", decodedFromBytes, pos)
			}
		})
	}
}

func TestPositionNext(t *testing.T) {
	tests := []struct {
		name           string
		pos            Position
		expectedNext   Position
		commitOverflow bool
		blockOverflow  bool
		epochOverflow  bool
	}{
		{
			name:           "simple increment",
			pos:            Position{0, 0, 0},
			expectedNext:   Position{0, 0, 1},
			commitOverflow: false,
			blockOverflow:  false,
			epochOverflow:  false,
		},
		{
			name:           "commitment overflow",
			pos:            Position{0, 0, 65535},
			expectedNext:   Position{0, 1, 0},
			commitOverflow: true,
			blockOverflow:  false,
			epochOverflow:  false,
		},
		{
			name:           "block overflow",
			pos:            Position{0, 65535, 65535},
			expectedNext:   Position{1, 0, 0},
			commitOverflow: true,
			blockOverflow:  true,
			epochOverflow:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			next, cOverflow, bOverflow, eOverflow := tt.pos.Next()

			if next != tt.expectedNext {
				t.Errorf("Next position mismatch: got %v, want %v", next, tt.expectedNext)
			}
			if cOverflow != tt.commitOverflow {
				t.Errorf("Commit overflow mismatch: got %v, want %v", cOverflow, tt.commitOverflow)
			}
			if bOverflow != tt.blockOverflow {
				t.Errorf("Block overflow mismatch: got %v, want %v", bOverflow, tt.blockOverflow)
			}
			if eOverflow != tt.epochOverflow {
				t.Errorf("Epoch overflow mismatch: got %v, want %v", eOverflow, tt.epochOverflow)
			}
		})
	}
}

func TestQuaternaryPath(t *testing.T) {
	tests := []struct {
		name         string
		index        uint16
		expectedPath []uint8
	}{
		{
			name:         "index 0",
			index:        0,
			expectedPath: []uint8{0, 0, 0, 0, 0, 0, 0, 0},
		},
		{
			name:         "index 1",
			index:        1,
			expectedPath: []uint8{0, 0, 0, 0, 0, 0, 0, 1},
		},
		{
			name:         "index 4",
			index:        4,
			expectedPath: []uint8{0, 0, 0, 0, 0, 0, 1, 0},
		},
		{
			name:         "index 16",
			index:        16,
			expectedPath: []uint8{0, 0, 0, 0, 0, 1, 0, 0},
		},
		{
			name:         "index 65535 (max)",
			index:        65535,
			expectedPath: []uint8{3, 3, 3, 3, 3, 3, 3, 3},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pos := Position{Commitment: tt.index}
			path := pos.QuaternaryPath(TierCommitment)

			if len(path) != len(tt.expectedPath) {
				t.Fatalf("Path length mismatch: got %d, want %d", len(path), len(tt.expectedPath))
			}

			for i, v := range path {
				if v != tt.expectedPath[i] {
					t.Errorf("Path[%d] mismatch: got %d, want %d", i, v, tt.expectedPath[i])
				}
			}
		})
	}
}

func TestChildIndex(t *testing.T) {
	// Test that ChildIndex returns the correct child for each level
	pos := Position{Commitment: 0b11_10_01_00_11_10_01_00} // 4-bit groups: 3,2,1,0,3,2,1,0

	expectedChildIndices := []uint8{3, 2, 1, 0, 3, 2, 1, 0}

	for level := 0; level < QuaternaryLevels; level++ {
		childIdx := pos.ChildIndex(TierCommitment, level)
		if childIdx != expectedChildIndices[level] {
			t.Errorf("ChildIndex at level %d: got %d, want %d", level, childIdx, expectedChildIndices[level])
		}
	}
}

func TestTierString(t *testing.T) {
	tests := []struct {
		tier     Tier
		expected string
	}{
		{TierCommitment, "commitment"},
		{TierBlock, "block"},
		{TierEpoch, "epoch"},
		{TierEternity, "eternity"},
	}

	for _, tt := range tests {
		if tt.tier.String() != tt.expected {
			t.Errorf("Tier.String() for %d: got %s, want %s", tt.tier, tt.tier.String(), tt.expected)
		}
	}
}

func TestFrontier(t *testing.T) {
	frontier := NewFrontier()

	if !frontier.CurrentPosition.IsZero() {
		t.Error("New frontier should start at zero position")
	}

	if frontier.EpochFrontier == nil {
		t.Error("EpochFrontier should not be nil")
	}
	if frontier.BlockFrontier == nil {
		t.Error("BlockFrontier should not be nil")
	}
	if frontier.CommitmentFrontier == nil {
		t.Error("CommitmentFrontier should not be nil")
	}

	// Test GetFrontierForTier
	if frontier.GetFrontierForTier(TierCommitment) != frontier.CommitmentFrontier {
		t.Error("GetFrontierForTier(TierCommitment) returned wrong frontier")
	}
	if frontier.GetFrontierForTier(TierBlock) != frontier.BlockFrontier {
		t.Error("GetFrontierForTier(TierBlock) returned wrong frontier")
	}
	if frontier.GetFrontierForTier(TierEpoch) != frontier.EpochFrontier {
		t.Error("GetFrontierForTier(TierEpoch) returned wrong frontier")
	}
}

func TestComputeSiblingIndices(t *testing.T) {
	path := []uint8{2, 0, 3, 1}

	siblings := ComputeSiblingIndices(path)

	if len(siblings) != len(path) {
		t.Fatalf("Siblings length mismatch: got %d, want %d", len(siblings), len(path))
	}

	// For path[0]=2, siblings should be 0,1,3
	expectedSiblings := [][]uint8{
		{0, 1, 3}, // level 0, path element 2
		{1, 2, 3}, // level 1, path element 0
		{0, 1, 2}, // level 2, path element 3
		{0, 2, 3}, // level 3, path element 1
	}

	for level := range path {
		if len(siblings[level]) != 3 {
			t.Errorf("Level %d siblings count: got %d, want 3", level, len(siblings[level]))
			continue
		}

		for i, sib := range siblings[level] {
			if sib.ChildIndex != expectedSiblings[level][i] {
				t.Errorf("Level %d sibling %d: got %d, want %d", level, i, sib.ChildIndex, expectedSiblings[level][i])
			}
		}
	}
}
