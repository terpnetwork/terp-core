package types

import (
	storetypes "cosmossdk.io/store/types"
)

const (
	ModuleName = "hashmerchant"
	StoreKey   = "hashmerchant"
	RouterKey  = ModuleName
	QuerierRoute = ModuleName
)

var (
	// KeyPrefix* are the store key prefixes per ADR-001
	KeyPrefixRegisteredChains    = []byte{0x01}
	KeyPrefixRegisteredContracts = []byte{0x02}
	KeyPrefixEscrow              = []byte{0x03}
	KeyPrefixHashRoots           = []byte{0x04}
	KeyPrefixParams              = []byte{0x05}
	KeyPrefixPruneEpoch          = []byte{0x06}
)

// KeyRegisteredChain returns the store key for a registered chain.
func KeyRegisteredChain(chainUID string) []byte {
	return append(KeyPrefixRegisteredChains, []byte(chainUID)...)
}

// KeyRegisteredContract returns the store key for a registered contract.
func KeyRegisteredContract(contractAddr string) []byte {
	return append(KeyPrefixRegisteredContracts, []byte(contractAddr)...)
}

// KeyEscrow returns the store key for an escrow record.
func KeyEscrow(contractAddr string) []byte {
	return append(KeyPrefixEscrow, []byte(contractAddr)...)
}

// KeyHashRoot returns the store key for a hash root (chainUID + algo as composite key).
func KeyHashRoot(chainUID, algo string) []byte {
	k := append(KeyPrefixHashRoots, []byte(chainUID)...)
	k = append(k, []byte("|")...)
	k = append(k, []byte(algo)...)
	return k
}

// NewKVStoreKey wraps storetypes for convenience.
func NewKVStoreKey() *storetypes.KVStoreKey {
	return storetypes.NewKVStoreKey(StoreKey)
}
