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
	"hooks-for-ibc":           {}, // ibchookstypes.StoreKey (not ModuleName)
	"08-wasm":                 {},
	"capability":              {},
}

// DestName is the Added dual-store tree for a live keeper name.
// Prefix form (b3-bank) — not a suffix (bank_b3): SDK panics if two keys share a prefix.
func DestName(src string) string {
	return "b3-" + src
}

// Dual-store aliases for the original three trees (tests / logs).
const (
	BankB3    = "b3-bank"
	StakingB3 = "b3-staking"
	AuthB3    = "b3-acc"
)

// MigratableStores is every live IAVL name Upgrade A copies into a b3-* dest.
// Not in this list: SHA256Stores (ICS-23), 08-wasm (IBC light client), leftover x/params,
// and upgrade (handler writes applied/armed plans into that store during A).
// bank is first so tests that treat snaps[0] as bank stay valid.
func MigratableStores() []string {
	return []string{
		"bank",
		"staking",
		"acc",
		"crisis",
		"mint",
		"distribution",
		"slashing",
		"gov",
		"consensus",
		"feegrant",
		"evidence",
		"authz",
		"wasm",
		"feeshare",
		"globalfee",
		"drip",
		"smartaccount",
		"tokenfactory",
		"hashmerchant",
		"cw-hooks",
	}
}

// DestStores is Added in v6.1 StoreUpgrades (same order as MigratableStores).
func DestStores() []string {
	src := MigratableStores()
	out := make([]string, len(src))
	for i, s := range src {
		out[i] = DestName(s)
	}
	return out
}

// DualStorePairs is src store → dest b3-* store for v6.1 (Upgrade A).
func DualStorePairs() [][2]string {
	src := MigratableStores()
	out := make([][2]string, len(src))
	for i, s := range src {
		out[i] = [2]string{s, DestName(s)}
	}
	return out
}

// AlgorithmName is "sha256" or "blake3".
func AlgorithmName(storeName string) string {
	if _, ok := SHA256Stores[storeName]; ok {
		return "sha256"
	}
	return "blake3"
}
