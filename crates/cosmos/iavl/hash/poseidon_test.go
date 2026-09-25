package hash

import (
	"bytes"
	"testing"

	"github.com/coinbase/kryptology/pkg/core/curves/native/pasta/fp"
)

func TestNewPoseidonHasher(t *testing.T) {
	h := NewPoseidonHasher()
	if h == nil {
		t.Fatal("NewPoseidonHasher returned nil")
	}
	if h.Algorithm() != Poseidon {
		t.Errorf("Expected algorithm Poseidon, got %s", h.Algorithm())
	}
	if h.FieldSize() != HashSize {
		t.Errorf("Expected field size %d, got %d", HashSize, h.FieldSize())
	}
}

func TestPoseidonEmptyHash(t *testing.T) {
	h := NewPoseidonHasher()
	emptyHash := h.EmptyHash()

	if len(emptyHash) != HashSize {
		t.Errorf("Expected empty hash length %d, got %d", HashSize, len(emptyHash))
	}

	// Empty hash should be deterministic
	emptyHash2 := h.EmptyHash()
	if !bytes.Equal(emptyHash, emptyHash2) {
		t.Error("Empty hash is not deterministic")
	}
}

func TestPoseidonHashValue(t *testing.T) {
	h := NewPoseidonHasher()

	// Test hashing a simple value
	value := []byte("hello world")
	hash1 := h.HashValue(value)

	if len(hash1) != HashSize {
		t.Errorf("Expected hash length %d, got %d", HashSize, len(hash1))
	}

	// Same value should produce same hash
	hash2 := h.HashValue(value)
	if !bytes.Equal(hash1, hash2) {
		t.Error("Hash is not deterministic")
	}

	// Different value should produce different hash
	hash3 := h.HashValue([]byte("different value"))
	if bytes.Equal(hash1, hash3) {
		t.Error("Different values produced same hash")
	}
}

func TestPoseidonHashLeaf(t *testing.T) {
	h := NewPoseidonHasher()

	key := []byte("test-key")
	valueHash := h.HashValue([]byte("test-value"))
	height := int8(0)
	size := int64(1)
	version := int64(1)

	hash1 := h.HashLeaf(height, size, version, key, valueHash)

	if len(hash1) != HashSize {
		t.Errorf("Expected hash length %d, got %d", HashSize, len(hash1))
	}

	// Same inputs should produce same hash
	hash2 := h.HashLeaf(height, size, version, key, valueHash)
	if !bytes.Equal(hash1, hash2) {
		t.Error("Leaf hash is not deterministic")
	}

	// Different key should produce different hash
	hash3 := h.HashLeaf(height, size, version, []byte("different-key"), valueHash)
	if bytes.Equal(hash1, hash3) {
		t.Error("Different keys produced same leaf hash")
	}

	// Different version should produce different hash
	hash4 := h.HashLeaf(height, size, version+1, key, valueHash)
	if bytes.Equal(hash1, hash4) {
		t.Error("Different versions produced same leaf hash")
	}
}

func TestPoseidonHashInner(t *testing.T) {
	h := NewPoseidonHasher()

	leftHash := h.HashValue([]byte("left"))
	rightHash := h.HashValue([]byte("right"))
	height := int8(1)
	size := int64(2)
	version := int64(1)

	hash1 := h.HashInner(height, size, version, leftHash, rightHash)

	if len(hash1) != HashSize {
		t.Errorf("Expected hash length %d, got %d", HashSize, len(hash1))
	}

	// Same inputs should produce same hash
	hash2 := h.HashInner(height, size, version, leftHash, rightHash)
	if !bytes.Equal(hash1, hash2) {
		t.Error("Inner hash is not deterministic")
	}

	// Swapped children should produce different hash
	hash3 := h.HashInner(height, size, version, rightHash, leftHash)
	if bytes.Equal(hash1, hash3) {
		t.Error("Swapped children produced same inner hash")
	}

	// Different height should produce different hash
	hash4 := h.HashInner(height+1, size, version, leftHash, rightHash)
	if bytes.Equal(hash1, hash4) {
		t.Error("Different heights produced same inner hash")
	}
}

func TestPoseidonHashTwo(t *testing.T) {
	h := NewPoseidonHasher()

	left := h.HashValue([]byte("left"))
	right := h.HashValue([]byte("right"))

	hash1 := h.HashTwo(left, right)

	if len(hash1) != HashSize {
		t.Errorf("Expected hash length %d, got %d", HashSize, len(hash1))
	}

	// Same inputs should produce same hash
	hash2 := h.HashTwo(left, right)
	if !bytes.Equal(hash1, hash2) {
		t.Error("HashTwo is not deterministic")
	}

	// Order matters
	hash3 := h.HashTwo(right, left)
	if bytes.Equal(hash1, hash3) {
		t.Error("HashTwo should be order-dependent")
	}
}

func TestBytesToFpElements(t *testing.T) {
	tests := []struct {
		name     string
		input    []byte
		expected int // number of field elements
	}{
		{"empty", []byte{}, 1},
		{"small", []byte("hello"), 1},
		{"31 bytes", make([]byte, 31), 1},
		{"32 bytes", make([]byte, 32), 2},
		{"62 bytes", make([]byte, 62), 2},
		{"63 bytes", make([]byte, 63), 3},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			elements := bytesToFpElements(tt.input)
			if len(elements) != tt.expected {
				t.Errorf("Expected %d elements, got %d", tt.expected, len(elements))
			}
		})
	}
}

func TestInt64ToFp(t *testing.T) {
	tests := []struct {
		name  string
		value int64
	}{
		{"zero", 0},
		{"positive", 12345},
		{"large", 9223372036854775807},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := int64ToFp(tt.value)
			if f == nil {
				t.Fatal("int64ToFp returned nil")
			}
			// Verify the field element is valid
			bytes := f.Bytes()
			if len(bytes) != 32 {
				t.Errorf("Expected 32 bytes, got %d", len(bytes))
			}
		})
	}
}

func TestToFieldElement(t *testing.T) {
	tests := []struct {
		name  string
		input []byte
	}{
		{"empty", []byte{}},
		{"small", []byte{1, 2, 3}},
		{"max size", make([]byte, FieldElementSize)},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := ToFieldElement(tt.input)
			if f == nil {
				t.Fatal("ToFieldElement returned nil")
			}
		})
	}
}

func TestFromFieldElement(t *testing.T) {
	f := new(fp.Fp).SetUint64(12345)
	b := FromFieldElement(f)

	if len(b) != 32 {
		t.Errorf("Expected 32 bytes, got %d", len(b))
	}
}

func TestPoseidonDifferentFromSHA256(t *testing.T) {
	poseidonHasher := NewPoseidonHasher()
	sha256Hasher := NewSHA256Hasher()

	value := []byte("test value")
	poseidonHash := poseidonHasher.HashValue(value)
	sha256Hash := sha256Hasher.HashValue(value)

	if bytes.Equal(poseidonHash, sha256Hash) {
		t.Error("Poseidon and SHA256 should produce different hashes")
	}
}

func TestEncodeMetadata(t *testing.T) {
	elements := EncodeMetadata(1, 100, 5)

	if len(elements) != 3 {
		t.Errorf("Expected 3 elements, got %d", len(elements))
	}
}

func BenchmarkPoseidonHashValue(b *testing.B) {
	h := NewPoseidonHasher()
	value := make([]byte, 100)
	for i := range value {
		value[i] = byte(i)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		h.HashValue(value)
	}
}

func BenchmarkPoseidonHashLeaf(b *testing.B) {
	h := NewPoseidonHasher()
	key := []byte("benchmark-key")
	valueHash := make([]byte, 32)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		h.HashLeaf(0, 1, int64(i), key, valueHash)
	}
}

func BenchmarkPoseidonHashInner(b *testing.B) {
	h := NewPoseidonHasher()
	leftHash := make([]byte, 32)
	rightHash := make([]byte, 32)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		h.HashInner(1, 2, int64(i), leftHash, rightHash)
	}
}

func BenchmarkSHA256HashValue(b *testing.B) {
	h := NewSHA256Hasher()
	value := make([]byte, 100)
	for i := range value {
		value[i] = byte(i)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		h.HashValue(value)
	}
}
