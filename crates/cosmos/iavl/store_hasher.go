package iavl

import (
	"os"
	"strings"

	"github.com/cosmos/iavl/hash"
)

// HasherMode selects per-store IAVL inner-node algorithm for lab / v6.3-dev.
// Production tags should pin a mode in code, not only env.
type HasherMode int

const (
	// HasherModeV63 is the morocco-1 upgrade default: IBC + live names SHA-256,
	// dest `b3-*` trees BLAKE3. Do not hash live `bank` with BLAKE3.
	HasherModeV63 HasherMode = iota
	// HasherModeHybrid is lab-only (fresh genesis): IBC SHA-256, all other stores BLAKE3.
	HasherModeHybrid
	HasherModeBLAKE3
	HasherModeSHA256
)

var hasherMode = HasherModeV63

func SetHasherMode(m HasherMode) { hasherMode = m }

func HasherModeFromEnv() HasherMode {
	return ParseHasherMode(os.Getenv("TERP_IAVL_HASHER"))
}

func ParseHasherMode(s string) HasherMode {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "blake3", "full", "a":
		return HasherModeBLAKE3
	case "sha256", "c":
		return HasherModeSHA256
	case "hybrid":
		return HasherModeHybrid
	default:
		return HasherModeV63
	}
}

// SHA256Stores: hybrid mode keeps these on SHA-256 (ICS-23 IavlSpec).
var SHA256Stores = map[string]struct{}{
	"ibc":                     {},
	"transfer":                {},
	"icahost":                 {},
	"icacontroller":           {},
	"packetfowardmiddleware":  {},
	"packetforwardmiddleware": {},
	"hooks-for-ibc":           {},
	"08-wasm":                 {},
	"capability":              {},
}

// IsSHA256Store reports whether storeName must keep SHA-256 IAVL hashing.
func IsSHA256Store(storeName string) bool {
	_, ok := SHA256Stores[storeName]
	return ok
}

// HasherForStore returns the hasher for a named KV store.
// IBC-facing stores get a nil hasher (legacy SHA-256 / ICS23 IavlSpec).
// All other stores get BLAKE3.
func HasherForStore(storeName string) hash.Hasher {
	switch hasherMode {
	case HasherModeBLAKE3:
		return hash.NewBLAKE3Hasher()
	case HasherModeSHA256:
		return nil
	case HasherModeHybrid:
		if IsSHA256Store(storeName) {
			return nil
		}
		return hash.NewBLAKE3Hasher()
	default: // HasherModeV63
		if IsSHA256Store(storeName) {
			return nil
		}
		if len(storeName) > 3 && storeName[:3] == "b3-" {
			return hash.NewBLAKE3Hasher()
		}
		return nil
	}
}

// HasherOptionForStore is passed to NewMutableTree / LoadStoreWithOpts.
func HasherOptionForStore(storeName string) Option {
	if h := HasherForStore(storeName); h != nil {
		return HasherOption(h)
	}
	return SHA256Option()
}

func StoreHashAlgorithm(storeName string) hash.HashAlgorithm {
	if HasherForStore(storeName) == nil {
		return hash.SHA256
	}
	return hash.BLAKE3
}
