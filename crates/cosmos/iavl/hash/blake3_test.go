package hash

import (
	"bytes"
	"encoding/hex"
	"testing"
)

// Official BLAKE3 test vector for the empty input (32-byte output).
// https://github.com/BLAKE3-team/BLAKE3/blob/master/test_vectors/test_vectors.json
const blake3EmptyHex = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

func TestNewBLAKE3Hasher(t *testing.T) {
	h := NewBLAKE3Hasher()
	if h == nil {
		t.Fatal("NewBLAKE3Hasher returned nil")
	}
	if h.Algorithm() != BLAKE3 {
		t.Errorf("Expected algorithm BLAKE3, got %s", h.Algorithm())
	}
	if h.FieldSize() != HashSize {
		t.Errorf("Expected field size %d, got %d", HashSize, h.FieldSize())
	}
}

func TestBLAKE3EmptyHash(t *testing.T) {
	h := NewBLAKE3Hasher()
	emptyHash := h.EmptyHash()

	if len(emptyHash) != HashSize {
		t.Errorf("Expected empty hash length %d, got %d", HashSize, len(emptyHash))
	}

	want, err := hex.DecodeString(blake3EmptyHex)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(emptyHash, want) {
		t.Errorf("Empty hash mismatch\n got %x\nwant %x", emptyHash, want)
	}

	emptyHash2 := h.EmptyHash()
	if !bytes.Equal(emptyHash, emptyHash2) {
		t.Error("Empty hash is not deterministic")
	}

	// Mutating the returned slice must not affect later calls.
	emptyHash[0] ^= 0xff
	if bytes.Equal(h.EmptyHash(), emptyHash) {
		t.Error("EmptyHash returned a shared mutable buffer")
	}
}

func TestBLAKE3HashValue(t *testing.T) {
	h := NewBLAKE3Hasher()

	value := []byte("hello world")
	hash1 := h.HashValue(value)

	if len(hash1) != HashSize {
		t.Errorf("Expected hash length %d, got %d", HashSize, len(hash1))
	}

	hash2 := h.HashValue(value)
	if !bytes.Equal(hash1, hash2) {
		t.Error("Hash is not deterministic")
	}

	hash3 := h.HashValue([]byte("different value"))
	if bytes.Equal(hash1, hash3) {
		t.Error("Different values produced same hash")
	}

	emptyValue := h.HashValue(nil)
	if !bytes.Equal(emptyValue, h.EmptyHash()) {
		t.Error("HashValue(nil) should equal EmptyHash")
	}
}

func TestBLAKE3HashLeaf(t *testing.T) {
	h := NewBLAKE3Hasher()

	key := []byte("test-key")
	valueHash := h.HashValue([]byte("test-value"))
	height := int8(0)
	size := int64(1)
	version := int64(1)

	hash1 := h.HashLeaf(height, size, version, key, valueHash)

	if len(hash1) != HashSize {
		t.Errorf("Expected hash length %d, got %d", HashSize, len(hash1))
	}

	hash2 := h.HashLeaf(height, size, version, key, valueHash)
	if !bytes.Equal(hash1, hash2) {
		t.Error("Leaf hash is not deterministic")
	}

	hash3 := h.HashLeaf(height, size, version, []byte("different-key"), valueHash)
	if bytes.Equal(hash1, hash3) {
		t.Error("Different keys produced same leaf hash")
	}

	hash4 := h.HashLeaf(height, size, version+1, key, valueHash)
	if bytes.Equal(hash1, hash4) {
		t.Error("Different versions produced same leaf hash")
	}
}

func TestBLAKE3HashInner(t *testing.T) {
	h := NewBLAKE3Hasher()

	leftHash := h.HashValue([]byte("left"))
	rightHash := h.HashValue([]byte("right"))
	height := int8(1)
	size := int64(2)
	version := int64(1)

	hash1 := h.HashInner(height, size, version, leftHash, rightHash)

	if len(hash1) != HashSize {
		t.Errorf("Expected hash length %d, got %d", HashSize, len(hash1))
	}

	hash2 := h.HashInner(height, size, version, leftHash, rightHash)
	if !bytes.Equal(hash1, hash2) {
		t.Error("Inner hash is not deterministic")
	}

	hash3 := h.HashInner(height, size, version, rightHash, leftHash)
	if bytes.Equal(hash1, hash3) {
		t.Error("Swapped children produced same inner hash")
	}

	hash4 := h.HashInner(height+1, size, version, leftHash, rightHash)
	if bytes.Equal(hash1, hash4) {
		t.Error("Different heights produced same inner hash")
	}
}

func TestBLAKE3DifferentFromSHA256AndPoseidon(t *testing.T) {
	blake3Hasher := NewBLAKE3Hasher()
	sha256Hasher := NewSHA256Hasher()
	poseidonHasher := NewPoseidonHasher()

	value := []byte("test value")
	b3 := blake3Hasher.HashValue(value)
	s2 := sha256Hasher.HashValue(value)
	p := poseidonHasher.HashValue(value)

	if bytes.Equal(b3, s2) {
		t.Error("BLAKE3 and SHA256 should produce different hashes")
	}
	if bytes.Equal(b3, p) {
		t.Error("BLAKE3 and Poseidon should produce different hashes")
	}
}
