package hash

import (
	"crypto/sha256"
	"encoding/binary"
	"sync"
)

// SHA256Hasher implements the Hasher interface using SHA-256.
// This provides backward compatibility with the original IAVL implementation.
type SHA256Hasher struct{}

var (
	sha256HasherPool = &sync.Pool{
		New: func() any {
			return sha256.New()
		},
	}
	sha256EmptyHash = sha256.New().Sum(nil)
)

// NewSHA256Hasher creates a new SHA256Hasher instance.
func NewSHA256Hasher() *SHA256Hasher {
	return &SHA256Hasher{}
}

// HashLeaf computes the SHA-256 hash of a leaf node.
func (h *SHA256Hasher) HashLeaf(height int8, size int64, version int64, key []byte, valueHash []byte) []byte {
	hasher := sha256HasherPool.Get().(interface {
		Write([]byte) (int, error)
		Sum([]byte) []byte
		Reset()
	})
	defer func() {
		hasher.Reset()
		sha256HasherPool.Put(hasher)
	}()

	var buf [binary.MaxVarintLen64]byte

	// Write height (varint)
	n := binary.PutVarint(buf[:], int64(height))
	hasher.Write(buf[:n])

	// Write size (varint)
	n = binary.PutVarint(buf[:], size)
	hasher.Write(buf[:n])

	// Write version (varint)
	n = binary.PutVarint(buf[:], version)
	hasher.Write(buf[:n])

	// Write key (length-prefixed)
	n = binary.PutUvarint(buf[:], uint64(len(key)))
	hasher.Write(buf[:n])
	hasher.Write(key)

	// Write value hash (length-prefixed)
	n = binary.PutUvarint(buf[:], uint64(len(valueHash)))
	hasher.Write(buf[:n])
	hasher.Write(valueHash)

	return hasher.Sum(nil)
}

// HashInner computes the SHA-256 hash of an inner node.
func (h *SHA256Hasher) HashInner(height int8, size int64, version int64, leftHash []byte, rightHash []byte) []byte {
	hasher := sha256HasherPool.Get().(interface {
		Write([]byte) (int, error)
		Sum([]byte) []byte
		Reset()
	})
	defer func() {
		hasher.Reset()
		sha256HasherPool.Put(hasher)
	}()

	var buf [binary.MaxVarintLen64]byte

	// Write height (varint)
	n := binary.PutVarint(buf[:], int64(height))
	hasher.Write(buf[:n])

	// Write size (varint)
	n = binary.PutVarint(buf[:], size)
	hasher.Write(buf[:n])

	// Write version (varint)
	n = binary.PutVarint(buf[:], version)
	hasher.Write(buf[:n])

	// Write left hash (length-prefixed)
	n = binary.PutUvarint(buf[:], uint64(len(leftHash)))
	hasher.Write(buf[:n])
	hasher.Write(leftHash)

	// Write right hash (length-prefixed)
	n = binary.PutUvarint(buf[:], uint64(len(rightHash)))
	hasher.Write(buf[:n])
	hasher.Write(rightHash)

	return hasher.Sum(nil)
}

// HashValue computes the SHA-256 hash of a value.
func (h *SHA256Hasher) HashValue(value []byte) []byte {
	hash := sha256.Sum256(value)
	return hash[:]
}

// EmptyHash returns the SHA-256 hash of an empty input.
func (h *SHA256Hasher) EmptyHash() []byte {
	result := make([]byte, len(sha256EmptyHash))
	copy(result, sha256EmptyHash)
	return result
}

// Algorithm returns SHA256.
func (h *SHA256Hasher) Algorithm() HashAlgorithm {
	return SHA256
}

// FieldSize returns 32 (SHA-256 output size).
func (h *SHA256Hasher) FieldSize() int {
	return HashSize
}
