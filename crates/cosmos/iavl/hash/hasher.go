package hash

import (
	"math/big"
)

// HashAlgorithm represents the type of hash algorithm used.
type HashAlgorithm string

const (
	// SHA256 is the standard SHA-256 hashing algorithm.
	SHA256 HashAlgorithm = "sha256"
	// BLAKE3 is the default IAVL hashing algorithm (32-byte output).
	BLAKE3 HashAlgorithm = "blake3"
	// Poseidon is the ZK-friendly Poseidon hash function.
	Poseidon HashAlgorithm = "poseidon"
)

// HashSize is the size of all hashes in bytes (32 bytes for SHA256, BLAKE3, and Poseidon with Pallas).
const HashSize = 32

// FieldElementSize is the maximum number of bytes that can fit in a single Pallas field element.
// Pallas field is ~254 bits, so we use 31 bytes to ensure values fit within the field.
const FieldElementSize = 31

// Hasher defines the interface for hash operations in the IAVL tree.
// This abstraction allows swapping between BLAKE3, SHA256, and Poseidon hash functions.
type Hasher interface {
	// HashLeaf computes the hash of a leaf node.
	// Parameters:
	//   - height: the height of the node (always 0 for leaves)
	//   - size: the size of the subtree (always 1 for leaves)
	//   - version: the tree version
	//   - key: the leaf's key
	//   - valueHash: the hash of the leaf's value
	HashLeaf(height int8, size int64, version int64, key []byte, valueHash []byte) []byte

	// HashInner computes the hash of an inner node.
	// Parameters:
	//   - height: the height of the node
	//   - size: the size of the subtree
	//   - version: the tree version
	//   - leftHash: the hash of the left child
	//   - rightHash: the hash of the right child
	HashInner(height int8, size int64, version int64, leftHash []byte, rightHash []byte) []byte

	// HashValue computes the hash of a value (used for leaf value indirection).
	HashValue(value []byte) []byte

	// EmptyHash returns the hash of an empty tree.
	EmptyHash() []byte

	// Algorithm returns the hash algorithm type.
	Algorithm() HashAlgorithm

	// FieldSize returns the size of a field element in bytes.
	FieldSize() int
}

// BytesToFieldElements converts a byte slice into a slice of field elements.
// Each field element is represented as a *big.Int.
// This is used by Poseidon to chunk variable-length data into fixed-size inputs.
func BytesToFieldElements(data []byte) []*big.Int {
	if len(data) == 0 {
		return []*big.Int{big.NewInt(0)}
	}

	numElements := (len(data) + FieldElementSize - 1) / FieldElementSize
	elements := make([]*big.Int, numElements)

	for i := 0; i < numElements; i++ {
		start := i * FieldElementSize
		end := start + FieldElementSize
		if end > len(data) {
			end = len(data)
		}

		chunk := data[start:end]
		// Pad to FieldElementSize if needed (for consistent representation)
		if len(chunk) < FieldElementSize {
			padded := make([]byte, FieldElementSize)
			copy(padded, chunk)
			chunk = padded
		}

		elements[i] = new(big.Int).SetBytes(chunk)
	}

	return elements
}

// FieldElementToBytes converts a field element back to bytes.
func FieldElementToBytes(fe *big.Int, size int) []byte {
	b := fe.Bytes()
	if len(b) >= size {
		return b[:size]
	}
	// Pad with leading zeros
	result := make([]byte, size)
	copy(result[size-len(b):], b)
	return result
}

// Int64ToFieldElement converts an int64 to a field element.
func Int64ToFieldElement(v int64) *big.Int {
	return big.NewInt(v)
}

// Int8ToFieldElement converts an int8 to a field element.
func Int8ToFieldElement(v int8) *big.Int {
	return big.NewInt(int64(v))
}
