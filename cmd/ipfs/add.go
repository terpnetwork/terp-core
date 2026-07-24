package ipfs

import (
	"fmt"

	mh "github.com/multiformats/go-multihash"
)

// DefaultChunkSize is Kubo's default size-262144 chunker limit.
// Files at or below this size become a single UnixFS file block under
// default `ipfs add` settings.
const DefaultChunkSize = 262144

// AddBytes returns the CIDv0 that default `ipfs add` produces for data.
//
// Layout matches Kubo defaults for a single-block file:
//  1. UnixFS Data{Type=File, Data=content, filesize=len}
//  2. dag-pb PBNode{Data=unixfs}
//  3. sha2-256 multihash → CIDv0 (base58btc "Qm…")
//
// Content larger than DefaultChunkSize is rejected; multi-block balanced
// DAGs are not implemented here (proposal metadata is always small).
func AddBytes(data []byte) (Cid, error) {
	if len(data) > DefaultChunkSize {
		return Undef, fmt.Errorf("ipfs.AddBytes: %d bytes exceeds single-block limit %d", len(data), DefaultChunkSize)
	}

	block := encodeUnixFSFileBlock(data)
	hash, err := mh.Sum(block, mh.SHA2_256, -1)
	if err != nil {
		return Undef, err
	}
	return NewCidV0(hash), nil
}

// AddBytesString is AddBytes then Cid.String() (CIDv0 base58btc).
func AddBytesString(data []byte) (string, error) {
	c, err := AddBytes(data)
	if err != nil {
		return "", err
	}
	return c.String(), nil
}

// encodeUnixFSFileBlock builds the raw dag-pb bytes for a single UnixFS file node.
func encodeUnixFSFileBlock(data []byte) []byte {
	// UnixFS Data protobuf (go-unixfs/pb):
	//   Type (field 1, varint) = File (2)
	//   Data (field 2, bytes)  = content
	//   filesize (field 3, varint) = len(content)
	unixfs := make([]byte, 0, 16+len(data))
	unixfs = appendVarintField(unixfs, 1, 2)            // Type = File
	unixfs = appendBytesField(unixfs, 2, data)          // Data
	unixfs = appendVarintField(unixfs, 3, uint64(len(data))) // filesize

	// dag-pb PBNode:
	//   Data (field 1, bytes) = unixfs
	//   Links (field 2) omitted for a leaf file
	return appendBytesField(nil, 1, unixfs)
}

func appendVarintField(buf []byte, fieldNum int, v uint64) []byte {
	buf = appendUvarint(buf, uint64(fieldNum<<3)|0) // wire type 0
	return appendUvarint(buf, v)
}

func appendBytesField(buf []byte, fieldNum int, data []byte) []byte {
	buf = appendUvarint(buf, uint64(fieldNum<<3)|2) // wire type 2
	buf = appendUvarint(buf, uint64(len(data)))
	return append(buf, data...)
}

func appendUvarint(buf []byte, x uint64) []byte {
	for x >= 0x80 {
		buf = append(buf, byte(x)|0x80)
		x >>= 7
	}
	return append(buf, byte(x))
}
