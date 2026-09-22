# IAVL hasher: SHA-256 vs BLAKE3 (v6.1 / v6.2)

**Live CommitMultiStore does not switch to BLAKE3 in the published
`v6.1.0` / `v6.2.0` binaries.** Dual-store copy is real; the hasher option is
not compiled into those ELFs.

## What the upgrade actually does

| Plan | Handler | Live hasher after apply |
|------|---------|-------------------------|
| **v6.1** | KV-copy every migratable store → `b3-*` dest. IBC / 08-wasm / transfer / ICA **not** copied. | Dest trees exist in CommitInfo. **Node hashes stay SHA-256** (stock `iavl v1.2.8`). |
| **v6.2** | Keepers stay `bank` / `staking` / `acc`. Unmounted `b3-*` dests drop from CommitInfo. | Same live names as before v6.1. **Still SHA-256.** IBC unchanged. |

`app/iavlhash.AlgorithmName("bank")` *documents* `"blake3"`. That string is
not what `LoadStoreWithOpts` uses in the tagged binaries.

## Why BLAKE3 is not on the ELF

Tagged `go.mod` (`v6.1.0` = `612ebf3`, `v6.2.0` = `0c24074`):

- `github.com/cosmos/iavl v1.2.8` — **no** `HasherOptionForStore`, **no** BLAKE3
- `github.com/cosmos/cosmos-sdk/store/v2 v2.0.0` — **no** hasher patch
- `replace github.com/cosmos/iavl/v2 => permissionlessweb/iavl/v2` — **IAVL v2 / SQLite**, `go.mod` says *unused by CommitMultiStore*
- Comment: local IAVL v1 + patched store/v2 are applied by `scripts/release/curate_v61.sh` and live under **gitignored** `crates/cosmos/{iavl,store-v2}`

`curate_v61.sh` *would* `go mod edit -replace store/v2=./crates/cosmos/store-v2`.
That replace is **not** on the release tags. Stock module-cache `iavl@v1.2.8`
and `store/v2@v2.0.0` have zero `HasherOptionForStore` hits.

The patch that would wire it (`app/iavlhash/store-v2-hasher.patch`) appends
`iavl.HasherOptionForStore(key.Name())` in `LoadStoreWithOpts`. Without the
`go.mod` replace, Docker `make build-reproducible-*` never sees that file.

Do **not** flip IAVL `DefaultOptions` to BLAKE3: unpatched loaders would hash
`ibc` with BLAKE3 and break ICS-23 / Hub proofs.

## What TSH already proved

In-place testnet from pruned `morocco-1_23141180` + **proposal S3** linux/arm64
tarballs:

- v6.1 applied at 23141190, v6.2 at 23141192 (`plan.info` Cosmovisor JSON)
- `circuit_upload_access` = Nobody
- module params queries succeeded

That is **migration + Cosmovisor soundness**, not a hasher cutover. Trees
loaded because they remained SHA-256.

## What “actually swapping” would require

1. `replace github.com/cosmos/iavl => ./crates/cosmos/iavl` (BLAKE3 option)
2. `replace github.com/cosmos/cosmos-sdk/store/v2 => ./crates/cosmos/store-v2` (patch applied)
3. Hasher policy for **existing** names during dual-store: `bank` must stay
   SHA-256 until keepers remount onto `b3-bank` (or an in-tree migrate).
   Today `HasherOptionForStore("bank")` would select BLAKE3, which cannot
   load a SHA-256 IAVL history.
4. v6.2 must **not** drop `b3-*` unless keepers already read those trees.
5. Recurate ELFs and Cosmovisor packs; do not use the current S3 `v6.1.0` /
   `v6.2.0` hashes.

That is a consensus change. It is **not** what halt `23191300` will run.

The cutover sprint is [`../v6.3/SPRINT.md`](../v6.3/SPRINT.md) (plans **`v6.3`** then **`v7`**). Do not retag `v6.1.0` / `v6.2.0`.
