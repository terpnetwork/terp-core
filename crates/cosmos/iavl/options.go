package iavl

import (
	"sync/atomic"

	"github.com/cosmos/iavl/hash"
)

// Statisc about db runtime state
type Statistics struct {
	// Each time GetNode operation hit cache
	cacheHitCnt uint64

	// Each time GetNode and GetFastNode operation miss cache
	cacheMissCnt uint64

	// Each time GetFastNode operation hit cache
	fastCacheHitCnt uint64

	// Each time GetFastNode operation miss cache
	fastCacheMissCnt uint64
}

func (stat *Statistics) IncCacheHitCnt() {
	if stat == nil {
		return
	}
	atomic.AddUint64(&stat.cacheHitCnt, 1)
}

func (stat *Statistics) IncCacheMissCnt() {
	if stat == nil {
		return
	}
	atomic.AddUint64(&stat.cacheMissCnt, 1)
}

func (stat *Statistics) IncFastCacheHitCnt() {
	if stat == nil {
		return
	}
	atomic.AddUint64(&stat.fastCacheHitCnt, 1)
}

func (stat *Statistics) IncFastCacheMissCnt() {
	if stat == nil {
		return
	}
	atomic.AddUint64(&stat.fastCacheMissCnt, 1)
}

func (stat *Statistics) GetCacheHitCnt() uint64 {
	return atomic.LoadUint64(&stat.cacheHitCnt)
}

func (stat *Statistics) GetCacheMissCnt() uint64 {
	return atomic.LoadUint64(&stat.cacheMissCnt)
}

func (stat *Statistics) GetFastCacheHitCnt() uint64 {
	return atomic.LoadUint64(&stat.fastCacheHitCnt)
}

func (stat *Statistics) GetFastCacheMissCnt() uint64 {
	return atomic.LoadUint64(&stat.fastCacheMissCnt)
}

func (stat *Statistics) Reset() {
	atomic.StoreUint64(&stat.cacheHitCnt, 0)
	atomic.StoreUint64(&stat.cacheMissCnt, 0)
	atomic.StoreUint64(&stat.fastCacheHitCnt, 0)
	atomic.StoreUint64(&stat.fastCacheMissCnt, 0)
}

// Options define tree options.
type Options struct {
	// Sync synchronously flushes all writes to storage, using e.g. the fsync syscall.
	// Disabling this significantly improves performance, but can lose data on e.g. power loss.
	Sync bool

	// InitialVersion specifies the initial version number. If any versions already exist below
	// this, an error is returned when loading the tree. Only used for the initial SaveVersion()
	// call.
	InitialVersion uint64

	// When Stat is not nil, statistical logic needs to be executed
	Stat *Statistics

	// Ethereum has found that commit of 100KB is optimal, ref ethereum/go-ethereum#15115
	FlushThreshold int

	// AsyncPruning is a flag to enable async pruning
	AsyncPruning bool

	// Hasher specifies the hash function to use. If nil, uses legacy SHA-256
	// (ICS23 IavlSpec). Apps should pass HasherOptionForStore(storeKey) so
	// IBC-facing stores stay SHA-256 and all other stores use BLAKE3.
	Hasher hash.Hasher

	// EnableTCT enables the Tiered Commitment Tree for parallel ZK-friendly state tracking.
	// When enabled, state changes are also tracked in a TCT structure alongside the main IAVL tree.
	// This provides efficient Poseidon-based proofs for ZK circuits.
	EnableTCT bool

	// TCTWitnessAll when true, keeps all commitments witnessed for proof generation.
	// When false (default), only explicitly witnessed keys can generate proofs.
	TCTWitnessAll bool

	// TCTAutoEndBlock when true, automatically ends TCT blocks at the threshold.
	TCTAutoEndBlock bool

	// TCTBlockThreshold is the number of commitments before auto-ending a TCT block.
	// Default is 10000.
	TCTBlockThreshold int
}

// DefaultOptions returns the default options for IAVL.
func DefaultOptions() Options {
	// Nil Hasher = SHA-256. Hybrid apps must pass HasherOptionForStore.
	return Options{FlushThreshold: 100000}
}

// SyncOption sets the Sync option.
func SyncOption(sync bool) Option {
	return func(opts *Options) {
		opts.Sync = sync
	}
}

// InitialVersionOption sets the initial version for the tree.
func InitialVersionOption(iv uint64) Option {
	return func(opts *Options) {
		opts.InitialVersion = iv
	}
}

// StatOption sets the Statistics for the tree.
func StatOption(stats *Statistics) Option {
	return func(opts *Options) {
		opts.Stat = stats
	}
}

// FlushThresholdOption sets the FlushThreshold for the batcher.
func FlushThresholdOption(ft int) Option {
	return func(opts *Options) {
		opts.FlushThreshold = ft
	}
}

// AsyncPruningOption sets the AsyncPruning for the tree.
func AsyncPruningOption(asyncPruning bool) Option {
	return func(opts *Options) {
		opts.AsyncPruning = asyncPruning
	}
}

// HasherOption sets the Hasher for the tree.
// If nil, the tree uses legacy SHA-256 hashing (ICS23 IavlSpec).
func HasherOption(h hash.Hasher) Option {
	return func(opts *Options) {
		opts.Hasher = h
	}
}

// SHA256Option restores legacy SHA-256 hashing.
// Required for ICS23 IavlSpec proofs, which only define SHA-256.
func SHA256Option() Option {
	return HasherOption(nil)
}

// EnableTCTOption enables the Tiered Commitment Tree for parallel ZK-friendly state tracking.
// When enabled, state changes are tracked in a TCT structure alongside the main IAVL tree.
func EnableTCTOption(enable bool) Option {
	return func(opts *Options) {
		opts.EnableTCT = enable
	}
}

// TCTWitnessAllOption sets whether all commitments should be witnessed for proof generation.
func TCTWitnessAllOption(witnessAll bool) Option {
	return func(opts *Options) {
		opts.TCTWitnessAll = witnessAll
	}
}

// TCTAutoEndBlockOption enables automatic block ending at the threshold.
func TCTAutoEndBlockOption(autoEnd bool, threshold int) Option {
	return func(opts *Options) {
		opts.TCTAutoEndBlock = autoEnd
		if threshold > 0 {
			opts.TCTBlockThreshold = threshold
		}
	}
}
