package types

import (
	"encoding/binary"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/address"
)

const (
	// ModuleName is the name of the contract module
	ModuleName = "wasm"

	// StoreKey is the string store representation
	StoreKey = ModuleName

	// TStoreKey is the string transient store representation
	TStoreKey = "transient_" + ModuleName

	// QuerierRoute is the querier route for the wasm module
	QuerierRoute = ModuleName

	// RouterKey is the msg router key for the wasm module
	RouterKey = ModuleName
)

var (
	CodeKeyPrefix                                  = []byte{0x01}
	ContractKeyPrefix                              = []byte{0x02}
	ContractStorePrefix                            = []byte{0x03}
	SequenceKeyPrefix                              = []byte{0x04}
	ContractCodeHistoryElementPrefix               = []byte{0x05}
	ContractByCodeIDAndCreatedSecondaryIndexPrefix = []byte{0x06}
	PinnedCodeIndexPrefix                          = []byte{0x07}
	TXCounterPrefix                                = []byte{0x08}
	ContractsByCreatorPrefix                       = []byte{0x09}
	ParamsKey                                      = []byte{0x10}
	AsyncAckKeyPrefix                              = []byte{0x11}
	// VkParamKeyPrefix stores VkParamInfo metadata (checksums + auth), never raw param bytes.
	VkParamKeyPrefix = []byte{0x12}
	// VkKeyPrefix reserved for future standalone vk metadata by vk_id.
	VkKeyPrefix = []byte{0x13}
	// VkParamBytesPrefix stores raw param bytes for internal reconstruction only.
	// These must never be returned from public query endpoints.
	VkParamBytesPrefix = []byte{0x14}

	// CircuitInfoKeyPrefix / CircuitKeyPrefix store CircuitInfo metadata by zk_id
	// (includes the 72-byte CircuitHash key for Path A CircuitInfo queries — pure KV, no recompute).
	CircuitInfoKeyPrefix = []byte{0x16}
	CircuitKeyPrefix     = []byte{0x16}
	// CircuitBytesPrefix stores the canonical monolithic circuit blob [params|cs|vk|footer]
	// for state sync, genesis export, and cold-path WasmQuery::Circuit / cache repopulation.
	// Proof hot path must not need this; Path A uses CircuitHash + wasmvm cache only.
	CircuitBytesPrefix        = []byte{0x19}
	CircuitsByCreatorPrefix   = []byte{0x18}
	PinnedCircuitsIndexPrefix = []byte{0x07}
	// CircuitDepositeePrefix maps depositor AccAddress -> paid_until unix seconds.
	// Presence of an unexpired row is an additional CircuitUploadAccess path
	// (allowlisted / Everybody / gov still skip payment).
	CircuitDepositeePrefix = []byte{0x1A}
	// CircuitDepositExpiryPrefix is paid_until BE || length-prefixed addr for range GC.
	CircuitDepositExpiryPrefix = []byte{0x1B}
	// CircuitDepositGCPrefix marks a depositor whose circuits still need blob prune.
	CircuitDepositGCPrefix = []byte{0x1C}
	// CircuitByCreatorIDPrefix maps creator → zk_id for bounded GC (not the unused 0x18 layout).
	CircuitByCreatorIDPrefix = []byte{0x1D}
	// CircuitEpochInfoPrefix is Osmosis-shaped EpochInfo JSON for circuit val-pool settle.
	CircuitEpochInfoPrefix = []byte{0x1E}

	KeySequenceCircuitID  = append(SequenceKeyPrefix, []byte("lastPlonkishCircuit")...)
	KeySequenceVkParamID  = append(SequenceKeyPrefix, []byte("lastVkParamId")...)
	KeySequenceCodeID     = append(SequenceKeyPrefix, []byte("lastCodeId")...)
	KeySequenceInstanceID = append(SequenceKeyPrefix, []byte("lastContractId")...)
)

// GetVkParamId constructs the key for VkParamInfo metadata (not raw bytes).
func GetVkParamId(vkParamId uint64) []byte {
	vkParamIDBz := sdk.Uint64ToBigEndian(vkParamId)
	return append(VkParamKeyPrefix, vkParamIDBz...)
}

// GetVkParamBytesKey constructs the key for raw param bytes (internal only).
func GetVkParamBytesKey(vkParamId uint64) []byte {
	vkParamIDBz := sdk.Uint64ToBigEndian(vkParamId)
	return append(VkParamBytesPrefix, vkParamIDBz...)
}

// GetVkId constructs the key for retrieving the ID for a Circuits Verifying Key bytes
func GetVkId(vkId uint64) []byte {
	vkIDBz := sdk.Uint64ToBigEndian(vkId)
	return append(VkKeyPrefix, vkIDBz...)
}

// GetCodeKey constructs the key for retrieving the ID for the WASM code
func GetCodeKey(codeID uint64) []byte {
	contractIDBz := sdk.Uint64ToBigEndian(codeID)
	return append(CodeKeyPrefix, contractIDBz...)
}

// GetCircuitKey constructs the key for CircuitInfo metadata by zk_id.
func GetCircuitKey(zkId uint64) []byte {
	circuitIdBz := sdk.Uint64ToBigEndian(zkId)
	return append(CircuitKeyPrefix, circuitIdBz...)
}

// GetCircuitInfoKey is an alias of GetCircuitKey (metadata lives under 0x16|zk_id).
func GetCircuitInfoKey(zkId uint64) []byte {
	return GetCircuitKey(zkId)
}

// GetCircuitBytesKey constructs the key for the canonical raw circuit blob by zk_id.
func GetCircuitBytesKey(zkId uint64) []byte {
	circuitIdBz := sdk.Uint64ToBigEndian(zkId)
	return append(CircuitBytesPrefix, circuitIdBz...)
}

// GetCircuitDepositExpiryKey is relative to CircuitDepositExpiryPrefix: until_be || len-prefixed addr.
func GetCircuitDepositExpiryKey(until uint64, addr sdk.AccAddress) []byte {
	ap := address.MustLengthPrefix(addr)
	r := make([]byte, 8+len(ap))
	copy(r[0:8], sdk.Uint64ToBigEndian(until))
	copy(r[8:], ap)
	return r
}

func ParseCircuitDepositExpiryKey(key []byte) (until uint64, addr sdk.AccAddress, ok bool) {
	if len(key) < 9 {
		return 0, nil, false
	}
	until = sdk.BigEndianToUint64(key[:8])
	n := int(key[8])
	if n <= 0 || len(key) < 9+n {
		return 0, nil, false
	}
	return until, sdk.AccAddress(key[9 : 9+n]), true
}

func GetCircuitDepositGCKey(addr sdk.AccAddress) []byte {
	return address.MustLengthPrefix(addr)
}

func ParseCircuitDepositGCKey(key []byte) (sdk.AccAddress, bool) {
	if len(key) < 1 {
		return nil, false
	}
	n := int(key[0])
	if n <= 0 || len(key) < 1+n {
		return nil, false
	}
	return sdk.AccAddress(key[1 : 1+n]), true
}

func GetCircuitByCreatorIDPrefix(creator sdk.AccAddress) []byte {
	return append(CircuitByCreatorIDPrefix, address.MustLengthPrefix(creator)...)
}

func GetCircuitByCreatorIDKey(creator sdk.AccAddress, zkID uint64) []byte {
	return append(GetCircuitByCreatorIDPrefix(creator), sdk.Uint64ToBigEndian(zkID)...)
}

// GetContractAddressKey returns the key for the WASM contract instance
func GetContractAddressKey(addr sdk.AccAddress) []byte {
	return append(ContractKeyPrefix, addr...)
}

// GetContractsByCreatorPrefix returns the contracts by creator prefix for the WASM contract instance
func GetContractsByCreatorPrefix(addr sdk.AccAddress) []byte {
	bz := address.MustLengthPrefix(addr)
	return append(ContractsByCreatorPrefix, bz...)
}

// GetContractsByCreatorPrefix returns the contracts by creator prefix for the WASM contract instance
func GetCircuitsByCreatorPrefix(addr sdk.AccAddress) []byte {
	bz := address.MustLengthPrefix(addr)
	return append(CircuitsByCreatorPrefix, bz...)
}

// GetContractStorePrefix returns the store prefix for the WASM contract instance
func GetContractStorePrefix(addr sdk.AccAddress) []byte {
	return append(ContractStorePrefix, addr...)
}

// GetAsyncPacketKey returns the key for a packet that is acknowledged asynchronously
func GetAsyncPacketKey(destChannel string, sequence uint64) []byte {
	// key is a concatenation of length-prefixed destination channel and sequence
	channel := []byte(destChannel)
	channelLen := make([]byte, 4)
	binary.BigEndian.PutUint32(channelLen, uint32(len(channel)))
	seq := make([]byte, 8)
	binary.BigEndian.PutUint64(seq, sequence)

	return append(append(channelLen, channel...), seq...)
}

// GetAsyncAckStorePrefix returns the store prefix for packets that are acknowledged asynchronously
func GetAsyncAckStorePrefix(portID string) []byte {
	return append(AsyncAckKeyPrefix, portID...)
}

// GetContractByCreatedSecondaryIndexKey returns the key for the secondary index:
// `<prefix><codeID><created/last-migrated><contractAddr>`
func GetContractByCreatedSecondaryIndexKey(contractAddr sdk.AccAddress, c ContractCodeHistoryEntry) []byte {
	prefix := GetContractByCodeIDSecondaryIndexPrefix(c.CodeID)
	prefixLen := len(prefix)
	contractAddrLen := len(contractAddr)
	r := make([]byte, prefixLen+AbsoluteTxPositionLen+contractAddrLen)
	copy(r[0:], prefix)
	copy(r[prefixLen:], c.Updated.Bytes())
	copy(r[prefixLen+AbsoluteTxPositionLen:], contractAddr)
	return r
}

// GetContractByCodeIDSecondaryIndexPrefix returns the prefix for the secondary index: `<prefix><codeID>`
func GetContractByCodeIDSecondaryIndexPrefix(codeID uint64) []byte {
	prefixLen := len(ContractByCodeIDAndCreatedSecondaryIndexPrefix)
	const codeIDLen = 8
	r := make([]byte, prefixLen+codeIDLen)
	copy(r[0:], ContractByCodeIDAndCreatedSecondaryIndexPrefix)
	copy(r[prefixLen:], sdk.Uint64ToBigEndian(codeID))
	return r
}

// GetContractByCreatorSecondaryIndexKey returns the key for the second index: `<prefix><creatorAddress length><created time><creatorAddress><contractAddr>`
func GetContractByCreatorSecondaryIndexKey(bz, position []byte, contractAddr sdk.AccAddress) []byte {
	prefixBytes := GetContractsByCreatorPrefix(bz)
	lenPrefixBytes := len(prefixBytes)
	r := make([]byte, lenPrefixBytes+AbsoluteTxPositionLen+len(contractAddr))

	copy(r[:lenPrefixBytes], prefixBytes)
	copy(r[lenPrefixBytes:lenPrefixBytes+AbsoluteTxPositionLen], position)
	copy(r[lenPrefixBytes+AbsoluteTxPositionLen:], contractAddr)

	return r
}

// GetContractByCreatorSecondaryIndexKey returns the key for the second index: `<prefix><creatorAddress length><created time><creatorAddress><contractAddr>`
func GetCircuitByCreatorSecondaryIndexKey(bz, position []byte, contractAddr sdk.AccAddress) []byte {
	prefixBytes := GetCircuitsByCreatorPrefix(bz)
	lenPrefixBytes := len(prefixBytes)
	r := make([]byte, lenPrefixBytes+AbsoluteTxPositionLen+len(contractAddr))

	copy(r[:lenPrefixBytes], prefixBytes)
	copy(r[lenPrefixBytes:lenPrefixBytes+AbsoluteTxPositionLen], position)
	copy(r[lenPrefixBytes+AbsoluteTxPositionLen:], contractAddr)

	return r
}

// GetContractCodeHistoryElementKey returns the key for a contract code history entry: `<prefix><contractAddr><position>`
func GetContractCodeHistoryElementKey(contractAddr sdk.AccAddress, pos uint64) []byte {
	prefix := GetContractCodeHistoryElementPrefix(contractAddr)
	prefixLen := len(prefix)
	r := make([]byte, prefixLen+8)
	copy(r[0:], prefix)
	copy(r[prefixLen:], sdk.Uint64ToBigEndian(pos))
	return r
}

// GetContractCodeHistoryElementPrefix returns the key prefix for a contract code history entry: `<prefix><contractAddr>`
func GetContractCodeHistoryElementPrefix(contractAddr sdk.AccAddress) []byte {
	prefixLen := len(ContractCodeHistoryElementPrefix)
	contractAddrLen := len(contractAddr)
	r := make([]byte, prefixLen+contractAddrLen)
	copy(r[0:], ContractCodeHistoryElementPrefix)
	copy(r[prefixLen:], contractAddr)
	return r
}

// GetPinnedCodeIndexPrefix returns the key prefix for a code id pinned into the wasmvm cache
func GetPinnedCodeIndexPrefix(codeID uint64) []byte {
	prefixLen := len(PinnedCodeIndexPrefix)
	r := make([]byte, prefixLen+8)
	copy(r[0:], PinnedCodeIndexPrefix)
	copy(r[prefixLen:], sdk.Uint64ToBigEndian(codeID))
	return r
}

// GetPinnedCodeIndexPrefix returns the key prefix for a code id pinned into the wasmvm cache
func GetPinnedCircuitIndexPrefix(zkID uint64) []byte {
	prefixLen := len(PinnedCircuitsIndexPrefix)
	r := make([]byte, prefixLen+8)
	copy(r[0:], PinnedCircuitsIndexPrefix)
	copy(r[prefixLen:], sdk.Uint64ToBigEndian(zkID))
	return r
}

// ParsePinnedCodeIndex converts the serialized code ID back.
func ParsePinnedCodeIndex(s []byte) uint64 {
	return sdk.BigEndianToUint64(s)
}

// ParsePinnedCircuitIndex converts the serialized code ID back.
func ParsePinnedCircuitIndex(s []byte) uint64 {
	return sdk.BigEndianToUint64(s)
}
