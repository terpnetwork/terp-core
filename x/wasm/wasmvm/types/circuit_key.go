package types

import "fmt"

// CircuitKeyLen is the wasmvm Path A circuit identity:
// param_file_key (36) || vk_file_key (36) from CircuitFooter::to_circuit_key.
// This is not a SHA-256 wasm checksum.
const CircuitKeyLen = 72

// CombinedStoreIDLen is store_code_with_circuit's FFI return:
// wasm checksum (32) || circuit key (72).
const CombinedStoreIDLen = ChecksumLen + CircuitKeyLen

// SplitCombinedStoreIDs parses a store_code_with_circuit return blob.
func SplitCombinedStoreIDs(combined []byte) (Checksum, []byte, error) {
	if len(combined) != CombinedStoreIDLen {
		return nil, nil, fmt.Errorf(
			"invalid combined store id length: expected %d (wasm %d + circuit %d), got %d",
			CombinedStoreIDLen, ChecksumLen, CircuitKeyLen, len(combined),
		)
	}
	code := Checksum(append([]byte(nil), combined[:ChecksumLen]...))
	circuit := append([]byte(nil), combined[ChecksumLen:]...)
	return code, circuit, nil
}
