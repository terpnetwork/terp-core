module github.com/cosmos/iavl

go 1.23

toolchain go1.24.7

replace github.com/coinbase/kryptology => github.com/permissionlessweb/kryptology v0.0.0-20260120180623-bb95dcb5aeea

replace github.com/cosmos/ics23/go => ../../ics23/go

require (
	cosmossdk.io/log v1.3.1
	github.com/coinbase/kryptology v1.8.0
	github.com/cosmos/cosmos-db v1.0.0
	github.com/cosmos/ics23/go v0.10.0
	github.com/emicklei/dot v1.4.2
	github.com/golang/mock v1.6.0
	github.com/google/btree v1.1.2
	github.com/stretchr/testify v1.8.4
	github.com/zeebo/blake3 v0.2.4
	golang.org/x/crypto v0.31.0
	google.golang.org/protobuf v1.33.0
)

require (
	filippo.io/edwards25519 v1.0.0-rc.1 // indirect
	github.com/DataDog/zstd v1.4.5 // indirect
	github.com/HdrHistogram/hdrhistogram-go v1.1.2 // indirect
	github.com/bits-and-blooms/bitset v1.7.0 // indirect
	github.com/btcsuite/btcd v0.21.0-beta.0.20201114000516-e9c7a5ac6401 // indirect
	github.com/btcsuite/btcutil v1.0.2 // indirect
	github.com/bwesterb/go-ristretto v1.2.0 // indirect
	github.com/cespare/xxhash/v2 v2.1.2 // indirect
	github.com/cockroachdb/errors v1.8.1 // indirect
	github.com/cockroachdb/logtags v0.0.0-20190617123548-eb05cc24525f // indirect
	github.com/cockroachdb/pebble v0.0.0-20220817183557-09c6e030a677 // indirect
	github.com/cockroachdb/redact v1.0.8 // indirect
	github.com/cockroachdb/sentry-go v0.6.1-cockroachdb.2 // indirect
	github.com/consensys/bavard v0.1.13 // indirect
	github.com/consensys/gnark-crypto v0.13.0 // indirect
	github.com/cosmos/gogoproto v1.7.0 // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/fsnotify/fsnotify v1.5.4 // indirect
	github.com/gogo/protobuf v1.3.2 // indirect
	github.com/golang/snappy v0.0.4 // indirect
	github.com/google/go-cmp v0.6.0 // indirect
	github.com/klauspost/compress v1.15.9 // indirect
	github.com/klauspost/cpuid/v2 v2.0.12 // indirect
	github.com/kr/pretty v0.3.1 // indirect
	github.com/kr/text v0.2.0 // indirect
	github.com/linxGnu/grocksdb v1.7.15 // indirect
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/mmcloughlin/addchain v0.4.0 // indirect
	github.com/onsi/gomega v1.26.0 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/rogpeppe/go-internal v1.14.1 // indirect
	github.com/rs/zerolog v1.32.0 // indirect
	github.com/spf13/cast v1.5.1 // indirect
	github.com/syndtr/goleveldb v1.0.1-0.20210819022825-2ae1ddf74ef7 // indirect
	golang.org/x/exp v0.0.0-20220722155223-a9213eeb770e // indirect
	golang.org/x/sync v0.1.0 // indirect
	golang.org/x/sys v0.28.0 // indirect
	gonum.org/v1/gonum v0.11.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
	rsc.io/tmplfunc v0.0.3 // indirect
)

retract (
	// This version released breaking changes by mistake in a patch release.
	// Use v1.2.8 instead.
	v1.2.7
	v1.1.3
	[v1.1.0, v1.1.1]
	[v1.0.0, v1.0.2]
	// This version is not used by the Cosmos SDK and adds a maintenance burden.
	// Use v1.x.x instead.
	[v0.21.0, v0.21.2]
	v0.18.0
)
