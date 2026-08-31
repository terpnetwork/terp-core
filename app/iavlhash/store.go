// Package iavlhash documents Terp's per-store IAVL hash policy.
//
// cosmossdk.io/store must pass iavl.HasherOptionForStore(key.Name()) into
// LoadStoreWithOpts (see PATCH.md). This package does not import IAVL so
// terp-core can compile before go.mod tidy pulls the hasher deps.
package iavlhash

// SHA256Stores must stay in lockstep with github.com/cosmos/iavl SHA256Stores.
var SHA256Stores = map[string]struct{}{
	"ibc":                     {},
	"transfer":                {},
	"icahost":                 {},
	"icacontroller":           {},
	"packetfowardmiddleware":  {},
	"packetforwardmiddleware": {},
	"ibc-hooks":               {},
	"capability":              {},
}

// Dual-store names for the v6.1 upgrade.
// Names must not share a prefix with existing StoreKeys (SDK panics:
// bank vs bank_b3, acc vs acc_b3, staking vs staking_b3).
const (
	BankB3    = "b3-bank"
	StakingB3 = "b3-staking"
	AuthB3    = "b3-acc"
)

// DualStorePairs is src store → dest b3-* store for v6.1 (Upgrade A).
func DualStorePairs() [][2]string {
	return [][2]string{
		{"bank", BankB3},
		{"staking", StakingB3},
		{"acc", AuthB3},
	}
}

// AlgorithmName is "sha256" or "blake3".
func AlgorithmName(storeName string) string {
	if _, ok := SHA256Stores[storeName]; ok {
		return "sha256"
	}
	return "blake3"
}
