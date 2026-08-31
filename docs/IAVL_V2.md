# IAVL v2 and Terp

This document is a map, not a claim that Terp is powered by IAVL v2.

**Terp today commits IAVL v1.2.x** (forked at `./crates/cosmos/iavl`) through Cosmos SDK **store/v2** (`github.com/cosmos/cosmos-sdk/store/v2 v2.0.0`). Store/v2 is a **store module major**, not IAVL v2. Its `iavl` package wraps `github.com/cosmos/iavl` v1 (`NewMutableTree` / `LoadStoreWithOpts`).

IAVL v2 is a different Go module (`github.com/cosmos/iavl/v2`), SQLite-backed, on `origin/release/v2.0.x`. It is not the live `CommitMultiStore`. Switching it in would change on-disk layout, ICS23 proofs, and the app hash.

## How Terp constructs IAVL today

1. `cmd/terpd/cmd/root.go` `newApp` is registered with SDK `server.AddCommands` (not Terp's `server/start.go` fork). The SDK opener creates `data/application.*`. `newApp` calls `app.NewTerpApp` with SDK `server.DefaultBaseappOptions` (`SetIAVLCacheSize`, `SetIAVLDisableFastNode`, `SetIAVLSyncPruning`, pruning, snapshots).
2. `app/app.go` `NewTerpApp` → `baseapp.NewBaseApp` → `store.NewCommitMultiStore` → `rootmulti.NewStore` on that DB.
3. Keepers `GenerateKeys` register KV store keys. `NewTerpApp` mounts them as `StoreTypeIAVL`:
   - `app.MountKVStores(app.keys)` → `BaseApp.MountKVStores` → `cms.MountStoreWithDB(key, StoreTypeIAVL, nil)`.
4. `LoadLatestVersion` (when `loadLatest`) runs `DefaultStoreLoader` → `rootmulti.Store.LoadLatestVersion` → `loadVersion` → `loadCommitStoreFromParams`.
5. For `StoreTypeIAVL`, store/v2 prefixes the app DB (`s/k:<name>/`) and calls `iavl.LoadStoreWithOpts` → **`iavl.NewMutableTree`** (module `github.com/cosmos/iavl`, replaced to `./crates/cosmos/iavl`).

File:line (this tree / SDK v0.54.3 / store/v2 v2.0.0):

| Step | Location |
|---|---|
| App constructor | `app/app.go` `NewTerpApp` (~308), `MountKVStores` (~453), `LoadLatestVersion` (~526) |
| Store keys | `app/keepers/keys.go` `GenerateKeys` (~37) |
| BaseApp CMS | `github.com/cosmos/cosmos-sdk@v0.54.3/baseapp/baseapp.go` `NewBaseApp` (~180), `MountKVStores` (~302), `LoadLatestVersion` (~350) |
| CMS factory | `github.com/cosmos/cosmos-sdk/store/v2@v2.0.0/store.go` `NewCommitMultiStore` (~13) |
| Load IAVL | `.../store/v2@v2.0.0/rootmulti/store.go` `loadCommitStoreFromParams` (~1015), `LoadStoreWithOpts` (~1030) |
| Mutable tree | `.../store/v2@v2.0.0/iavl/store.go` `LoadStoreWithOpts` (~55–61) `iavl.NewMutableTree` |
| IAVL flags | `github.com/cosmos/cosmos-sdk@v0.54.3/server/util.go` `DefaultBaseappOptions` (~568); CLI flags in SDK `server/start.go`. Terp `server/start.go` is a leftover fork, not used by `terpd`. |
| Application DB | SDK `server.AddCommands` DB opener: `data/application.*` |

`go.mod`: `replace github.com/cosmos/iavl => ./crates/cosmos/iavl` (Poseidon/BLAKE3-capable v1.2.x). Default hasher is still **SHA-256** (`DefaultOptions` nil hasher). `HasherOptionForStore` is **not** passed from unpatched `rootmulti.loadCommitStoreFromParams`; see `app/iavlhash/PATCH.md`. Dual BLAKE3 stores (`bank_b3`, …) are an upgrade sketch, not IAVL v2.

## What “powered by IAVL v2” actually requires

IAVL v2 (`module github.com/cosmos/iavl/v2`) is not a drop-in for store/v2’s `iavl.Tree` / `CommitKVStore`.

v2 **has**: `Tree` Get/Set/Remove/SaveVersion/Hash/Version/DeleteVersionsTo/LoadVersion/Iterator; `MultiTree` MountTree/LoadVersion/SaveVersion; SQLite files per store (`changelog.sqlite`, `tree.sqlite`); migrate CLI `migrate/v0` (application.db → sqlite, hash-checked against v1 `WorkingHash`); IAVL-v2 snapshots (`SaveSnapshot` / `LoadSnapshot` / ingest).

v2 **does not** implement store/v2 `iavl.Tree` (`store/v2/iavl/tree.go`):

| Needed for SDK SC | IAVL v2 today |
|---|---|
| `WorkingHash()` | missing (hash is computed inside `SaveVersion` / `computeHash`) |
| `GetImmutable(version)` | missing (historical query / proofs / export) |
| `GetVersioned` | missing (query `/key` at height) |
| `VersionExists` / `AvailableVersions` | missing |
| `SetInitialVersion` | missing (new chain / added stores) |
| `LoadVersionForOverwriting` | missing (rollback / `RollbackToVersion`) |
| `TraverseStateChanges` | missing (state listening) |
| `Iterator(..., ascending) (idb.Iterator, error)` | different iterator (`inclusive` bool; not `github.com/cosmos/iavl/db.Iterator`) |
| ICS23 `GetMembershipProof` / `GetNonMembershipProof` | **no proofs package** |
| Fast node | N/A (SQLite latest-leaf option instead) |
| cosmos-db `application.db` prefix layout | **SQLite directories**, not `s/k:<store>/` in LevelDB/Pebble |

Also missing for a honest `CommitKVStore` adapter:

- **ICS23 / IBC.** IAVL v2 hashes SHA-256 only (`node._hash` / `hashPool` = `sha256.New`). No `proof_ics23.go`. Hub/Juno `IavlSpec` proofs would not be produced.
- **App hash.** `MultiTree.Hash` concatenates store root hashes then SHA-256; SDK `CommitInfo` hashes `StoreInfo` protobufs. Using MultiTree.Hash as ABCI `AppHash` would disagree with Comet.
- **Snapshots / state-sync.** SDK snapshotter streams IAVL v1 `Exporter` nodes. v2 has a different snapshot format.
- **Pruning.** `DeleteVersionsTo` posts prune signals to SQLite writers; not wired to store/v2 pruning manager / `iavl-sync-pruning`.
- **Historical RPC.** `CacheMultiStoreWithVersion` calls `GetImmutable`.
- **Hasher policy.** Terp v1 fork can BLAKE3/Poseidon per store. This v2 worktree is SHA-256; `feat/blake3-native-v2` is the hashing worktree and must not be assumed complete.
- **CGO.** Backend is `github.com/bvinc/go-sqlite-lite` (CGO libsqlite3), not cosmos-db.

A CommitKVStore adapter would therefore need: Tree method wrappers, ICS23 (or a new proof spec + counterparty clients), historical load, rollback, snapshot export/import, pruning, and a **rootmulti replacement** (or IAVLX-style CMS) because the bytes are not in `application.db`.

## Blockers vs SDK IAVLX

SDK 0.54 **store/v2** is what Terp already uses. It still loads IAVL **v1**.

SDK 0.54 upgrade docs (and the later “next” upgrade guide) describe **IAVLX** as the upcoming WAL-based SC engine, *inspired by memIAVL and unreleased IAVL v2*. On the tagged `cosmos-sdk@v0.54.3` module used here:

- There is **no** `github.com/cosmos/cosmos-sdk/iavlx` package.
- `github.com/cosmos/cosmos-sdk/iavl/internal` is **not** IAVL v2 and **not** a working IAVLX: mem-node / changeset scaffolding; `Changeset.Resolve` is `not implemented`.
- Official wording: IAVLX is experimental; **migrate-from-v1 code is not yet available**; do not run in production.

IAVLX, if/when it ships as `github.com/cosmos/cosmos-sdk/iavlx`, is intended to implement `store/v2/types.CommitMultiStore` with its own WAL/checkpoint files, claiming hash compatibility with IAVL v1. That is a **different** on-disk format from both Terp’s current `application.db` and IAVL v2 SQLite.

Do not equate: store/v2 ≠ IAVL v2 ≠ IAVLX.

## Experimental support in this repo

- Package `app/iavlv2` can open a v2 `Tree` / `MultiTree` against a SQLite directory. **Nothing in `NewTerpApp` / `BaseApp` imports it.**
- `go.mod` requires `github.com/cosmos/iavl/v2` (pseudo-version of `origin/release/v2.0.x`). Local hashing worktree (gitignored):

```
replace github.com/cosmos/iavl/v2 => ./crates/cosmos/iavl/.worktrees/blake3-native-v2
```

`crates/cosmos/iavl/.worktrees/` is gitignored. Do not land that replace on the default branch until the tree is a tracked checkout or a published commit. `feat/blake3-native-v2` currently points at the same commit as `origin/release/v2.0.x` until hashing lands.

## Staged path (no fantasy)

1. **Support (this step):** depend on `github.com/cosmos/iavl/v2`; experiment package + sqlite round-trip test. Live CMS stays IAVL v1. App hash unchanged.
2. **Adapter (not started):** implement store/v2 `iavl.Tree` + `CommitKVStore` on v2 `Tree`, including ICS23 **or** an explicit proof-break upgrade. Decide hasher (SHA-256 vs Terp BLAKE3). Do not mount this in `NewTerpApp`.
3. **Layout:** SQLite per store key under e.g. `$HOME/.terpd/data/iavl-v2/<store>/`, plus a commit-info story compatible with `s/latest` / `s/<version>` (v2 migrate copies that metadata into sqlite; SDK rootmulti still expects it in application.db).
4. **Migrate:**
   - **v2 `migrate` CLI** (`migrate/v0 all`): offline, latest version only, exports v1 pre-order nodes into sqlite, panics if v2 root ≠ v1 `WorkingHash`. That check **fails** if Terp trees are BLAKE3 while v2 hashes SHA-256, and it does not migrate historical versions.
   - **Export/import at an upgrade height:** halt, export IAVL v1, ingest v2 snapshots, start a binary whose CMS is the adapter. Same hash-equality constraint. Coordinated upgrade.
   - **SDK IAVLX:** wait for migrate-from-v1; likely the path the SDK will support. Not a Terp-only adapter to cosmos/iavl/v2.
5. **Proofs / IBC:** keep `ibc` (and transfer/ICA/hooks) on SHA-256 IavlSpec until a client spec exists for the new engine. Same constraint as `app/iavlhash`.
6. **Cutover:** only after adapter + migrate + proof story + testnet soak. Never silently change `Commit()` hash.

### What not to do

- Do not point `rootmulti.loadCommitStoreFromParams` at IAVL v2.
- Do not treat store/v2 or `iavl/internal` as IAVL v2.
- Do not assume migrate CLI preserves history or Terp hasher policy.
- Do not modify the IAVL v2 worktree from Terp app wiring (hashing is a separate branch).
