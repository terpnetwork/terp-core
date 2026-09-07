# store/v2 hasher patch (one call site)

Live CMS is `github.com/cosmos/cosmos-sdk/store/v2` (`go.mod` v2.0.0), **not** `cosmossdk.io/store`. `NewTerpApp` mounts IAVL through store/v2 `rootmulti` → `iavl.LoadStoreWithOpts`.

Patch `iavl/store.go` `LoadStoreWithOpts` so every store gets `HasherOptionForStore(key.Name())` (BLAKE3 except IBC SHA-256 stores). Diff: `store-v2-hasher.patch`. Apply via `scripts/release/curate_v61.sh` which vendors `crates/cosmos/store-v2` and:

```
replace github.com/cosmos/iavl => ./crates/cosmos/iavl
replace github.com/cosmos/cosmos-sdk/store/v2 => ./crates/cosmos/store-v2
```

Until that replace is in, dual-store `b3-*` trees still hash SHA-256. **Do not** change IAVL `DefaultOptions` to BLAKE3 — unpatched loaders would hash `ibc` with BLAKE3 and break Hub/Juno proofs.
