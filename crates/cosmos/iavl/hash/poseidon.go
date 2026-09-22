package hash

import (
	"encoding/binary"

	"github.com/coinbase/kryptology/pkg/core/curves/native/pasta/fp"
	"github.com/coinbase/kryptology/pkg/signatures/schnorr/mina"
)

// PoseidonHasher implements the Hasher interface using the Poseidon hash function.
// This is optimized for ZK circuits with the Pallas curve.
type PoseidonHasher struct {
	// permutation type to use (ThreeW for 3-width sponge)
	permType mina.Permutation
	// network type (NullNet for generic usage without Mina-specific IV)
	networkType mina.NetworkType
}

// NewPoseidonHasher creates a new PoseidonHasher with default parameters.
// Uses ThreeW permutation (3-width sponge, rate 2) which is optimal for binary tree hashing.
func NewPoseidonHasher() *PoseidonHasher {
	return &PoseidonHasher{
		permType:    mina.ThreeW,
		networkType: mina.NullNet, // Use zero IV for generic Poseidon (not Mina-specific)
	}
}

// NewPoseidonHasherWithParams creates a new PoseidonHasher with custom parameters.
func NewPoseidonHasherWithParams(permType mina.Permutation, networkType mina.NetworkType) *PoseidonHasher {
	return &PoseidonHasher{
		permType:    permType,
		networkType: networkType,
	}
}

// newContext creates and initializes a new Poseidon context.
func (h *PoseidonHasher) newContext() *mina.Context {
	ctx := new(mina.Context)
	ctx.Init(h.permType, h.networkType)
	return ctx
}

// hash performs Poseidon hash on a slice of field elements and returns a 32-byte result.
func (h *PoseidonHasher) hash(elements []*fp.Fp) []byte {
	ctx := h.newContext()
	ctx.Update(elements)
	digest := ctx.Digest()
	bytes := digest.Bytes()
	return bytes[:]
}

// int64ToFp converts an int64 to a Pallas field element.
func int64ToFp(v int64) *fp.Fp {
	f := new(fp.Fp)
	if v >= 0 {
		f.SetUint64(uint64(v))
	} else {
		// Handle negative numbers by computing p - |v|
		f.SetUint64(uint64(-v))
		f.Neg(f)
	}
	return f
}

// int8ToFp converts an int8 to a Pallas field element.
func int8ToFp(v int8) *fp.Fp {
	return int64ToFp(int64(v))
}

// bytesToFpElements converts a byte slice to a slice of Pallas field elements.
// Each element holds up to 31 bytes to ensure it fits within the Pallas field.
func bytesToFpElements(data []byte) []*fp.Fp {
	if len(data) == 0 {
		return []*fp.Fp{new(fp.Fp).SetZero()}
	}

	numElements := (len(data) + FieldElementSize - 1) / FieldElementSize
	elements := make([]*fp.Fp, numElements)

	for i := 0; i < numElements; i++ {
		start := i * FieldElementSize
		end := start + FieldElementSize
		if end > len(data) {
			end = len(data)
		}

		chunk := data[start:end]

		// Convert chunk to field element using SetBytesWide for safe reduction
		// We pad to 64 bytes for SetBytesWide (512-bit input)
		var wide [64]byte
		// Copy chunk in little-endian order (kryptology uses little-endian)
		for j := 0; j < len(chunk); j++ {
			wide[j] = chunk[j]
		}

		elements[i] = new(fp.Fp).SetBytesWide(&wide)
	}

	return elements
}

// HashLeaf computes the Poseidon hash of a leaf node.
// Input structure: [height, size, version, key_chunks..., valueHash_chunks...]
func (h *PoseidonHasher) HashLeaf(height int8, size int64, version int64, key []byte, valueHash []byte) []byte {
	// Build input elements
	elements := make([]*fp.Fp, 0, 8)

	// Add metadata as field elements
	elements = append(elements, int8ToFp(height))
	elements = append(elements, int64ToFp(size))
	elements = append(elements, int64ToFp(version))

	// Add key as field elements
	keyElements := bytesToFpElements(key)
	elements = append(elements, keyElements...)

	// Add value hash as field elements
	valueHashElements := bytesToFpElements(valueHash)
	elements = append(elements, valueHashElements...)

	return h.hash(elements)
}

// HashInner computes the Poseidon hash of an inner node.
// Input structure: [height, size, version, leftHash_chunks..., rightHash_chunks...]
func (h *PoseidonHasher) HashInner(height int8, size int64, version int64, leftHash []byte, rightHash []byte) []byte {
	// Build input elements
	elements := make([]*fp.Fp, 0, 8)

	// Add metadata as field elements
	elements = append(elements, int8ToFp(height))
	elements = append(elements, int64ToFp(size))
	elements = append(elements, int64ToFp(version))

	// Add left hash as field elements
	leftElements := bytesToFpElements(leftHash)
	elements = append(elements, leftElements...)

	// Add right hash as field elements
	rightElements := bytesToFpElements(rightHash)
	elements = append(elements, rightElements...)

	return h.hash(elements)
}

// HashValue computes the Poseidon hash of a value.
func (h *PoseidonHasher) HashValue(value []byte) []byte {
	elements := bytesToFpElements(value)
	return h.hash(elements)
}

// EmptyHash returns the Poseidon hash of an empty input.
func (h *PoseidonHasher) EmptyHash() []byte {
	elements := []*fp.Fp{new(fp.Fp).SetZero()}
	return h.hash(elements)
}

// Algorithm returns Poseidon.
func (h *PoseidonHasher) Algorithm() HashAlgorithm {
	return Poseidon
}

// FieldSize returns 32 (Pallas field element size when serialized).
func (h *PoseidonHasher) FieldSize() int {
	return HashSize
}

// HashTwo performs Poseidon hash on exactly two 32-byte inputs.
// This is optimized for Merkle tree internal node hashing.
func (h *PoseidonHasher) HashTwo(left, right []byte) []byte {
	leftElements := bytesToFpElements(left)
	rightElements := bytesToFpElements(right)

	elements := make([]*fp.Fp, 0, len(leftElements)+len(rightElements))
	elements = append(elements, leftElements...)
	elements = append(elements, rightElements...)

	return h.hash(elements)
}

// HashFields directly hashes field elements (useful for circuit integration).
func (h *PoseidonHasher) HashFields(fields []*fp.Fp) []byte {
	return h.hash(fields)
}

// ToFieldElement converts bytes to a single field element (for values <= 31 bytes).
func ToFieldElement(data []byte) *fp.Fp {
	if len(data) == 0 {
		return new(fp.Fp).SetZero()
	}

	var wide [64]byte
	for i := 0; i < len(data) && i < FieldElementSize; i++ {
		wide[i] = data[i]
	}

	return new(fp.Fp).SetBytesWide(&wide)
}

// FromFieldElement converts a field element to bytes.
func FromFieldElement(f *fp.Fp) []byte {
	bytes := f.Bytes()
	return bytes[:]
}

// EncodeMetadata encodes node metadata (height, size, version) as field elements.
// This is useful for circuit witnesses.
func EncodeMetadata(height int8, size int64, version int64) []*fp.Fp {
	return []*fp.Fp{
		int8ToFp(height),
		int64ToFp(size),
		int64ToFp(version),
	}
}

// EncodeVarintToFp encodes a varint as a field element.
func EncodeVarintToFp(v int64) *fp.Fp {
	var buf [binary.MaxVarintLen64]byte
	n := binary.PutVarint(buf[:], v)
	return ToFieldElement(buf[:n])
}
