# IAVL hasher: v6.3 / v6.4 (the cutover v6.1/v6.2 did not ship)

**Goal:** IAVL inner nodes **BLAKE3** for app state. Whether **IBC stores**
stay SHA-256 (hybrid) or also go BLAKE3 (full, 08-wasm `Blake3IavlSpec`) is
**not locked** until [`BENCH.md`](./BENCH.md) JSON exists. v6.1.0 / v6.2.0 did
**not** compile hasher at all. After v6.2, `b3-*` dest trees are gone. Do
**not** retag those ELFs. New plans: **`v6.3`** then **`v6.4`**.

Do **not** set IAVL `DefaultOptions` to BLAKE3 on a tree that still has
SHA-256 history. Dual-store copy still required (IBC stores too if full wins).

Morocco-1 07-tendermint clients of Terp are treated as **expired**. Restoring
IBC is governance either way. Full-BLAKE3 means those restores are **08-wasm
clients with `Blake3IavlSpec`**, not new 07-tendermint clients.

## Policy (must match `HasherOptionForStore(key.Name())` on the ELF)

**Provisional = hybrid** until Bench lock below is filled. Full-BLAKE3
replaces the IBC rows with BLAKE3 and drops `SHA256Stores`.

| Store name | v6.3.0 ELF (dual-store) | v6.4.0 ELF (after B) |
|------------|-------------------------|----------------------|
| `ibc`, `transfer`, `icahost`, `icacontroller`, `packetforwardmiddleware`, `hooks-for-ibc`, `08-wasm`, `capability` | SHA-256 | SHA-256 |
| Live migratable (`bank`, `staking`, `acc`, …) | **SHA-256** (existing history) | **BLAKE3** (keepers on dest data) |
| Dest `b3-<name>` | **BLAKE3** (new trees from KV copy) | not mounted (dropped after keepers moved) |

`app/iavl.AlgorithmName` must implement **that table**, not “everything
except IBC is blake3” while `bank` still has SHA-256 history.

## Why v6.1/v6.2 failed

Tagged `go.mod` had **no** `replace` for `github.com/cosmos/iavl` or
`github.com/cosmos/cosmos-sdk/store/v2` onto patched trees.
`HasherOptionForStore` never compiled. Dest copies were SHA-256. v6.2 dropped
them. Live names stayed SHA-256.

`scripts/release/curate_v61.sh` vendored the patch under **gitignored**
`crates/cosmos/{iavl,store-v2}`. Docker recurate never saw it.

## What must be on tag `v6.3.0` and `v6.4.0`

These replaces are **consensus**. They go in git. They are not gitignored.

```
replace github.com/cosmos/iavl => ./crates/cosmos/iavl
replace github.com/cosmos/cosmos-sdk/store/v2 => ./crates/cosmos/store-v2
```

`crates/cosmos/iavl` is IAVL v1 with `HasherOptionForStore`.
`crates/cosmos/store-v2` has `app/iavl/store-v2-hasher.patch` applied
(`LoadStoreWithOpts` appends `iavl.HasherOptionForStore(key.Name())`).

`curate_v63.sh` **fails** if either replace is missing or if
`HasherOptionForStore` is not in the vendored `store.go`.
`scripts/release/fresh-vm/releases/v6.3.0.sh` **fails** the recurate if the
cloned tag lacks those replaces.

IAVL v2 (`github.com/cosmos/iavl/v2`) stays unused by CommitMultiStore.

## Upgrade shape (same as v6.1 → v6.2 ops, opposite hasher outcome)

| Plan | Binary | StoreUpgrades | Handler |
|------|--------|---------------|---------|
| **v6.3** | `v6.3.0` | `Added: b3-*` (DestStores) | KV-copy migratable → dest. Dest loads BLAKE3. Live names still SHA-256. IBC untouched. Arms plan `v6.4` at apply+2. |
| **v6.4** | `v6.4.0` (`-tags v64`) | Drop **SHA-256 live** migratable names from CommitInfo after keepers read dest. **Do not** `Renamed` dest onto `bank` (IAVL: initialVersion vs existing history). | Keepers wired to dest trees (BLAKE3). IBC keys unchanged. |

Governance submits **only** `v6.3`. The v6.3 binary schedules `v6.4`.

## Confirm hasher (not Cosmovisor-only)

A pass is **all** of these after v6.4 (and the dest-side checks after v6.3):

1. **Roots differ:** same KV ingested SHA-256 vs BLAKE3 → different root
   (`app/iavlv2` already has this unit shape; CMS must show it on `bank` vs
   a SHA-256 control).
2. **Raw IAVL nodes:** dump inner-node hashes for `bank` (or `b3-bank` on
   v6.3). They must **not** match SHA-256 of the child pair. `ibc` nodes must
   still match SHA-256.
3. **Bank balance inclusion:** prove `balances/{addr}` against the bank IAVL
   root with the **BLAKE3** ICS-23 spec (or raw IAVL proof). Fail if a SHA-256
   verifier accepts it.
4. **IBC / 08-wasm inclusion:** prove a packet or client state against `ibc` /
   `08-wasm` with **SHA-256 ICS-23**. Fail if a BLAKE3 verifier accepts it.
   Hub/Juno light-client path stays valid.
5. **HashMerchant oracle:** dedicated source, Osmosis TWAP of BTC, attested
   into a HashRoot (sidecar + vote extensions). Query the confirmed root /
   price on Terp. This is **not** a substitute for (1)–(4).

Do not claim BLAKE3 from `AlgorithmName("bank")` alone. That string lied on
v6.1.0.

## Bench lock (performance only)

See [`BENCH.md`](./BENCH.md). ict-rs Docker + cw-orch gas: hybrid **H** vs
full BLAKE3 + 08-wasm **F**. Fill after `hasher_ibc_bench` JSON exists:

| Field | Value |
|-------|--------|
| JSON | `tests/benchmarks/hasher-ibc/hasher-ibc-three-*.json` + `TABLE.md` |
| Winner | **H (hybrid)** |
| Median RecvPacket gas H / F | TM hybrid B→C **186947**; 08-wasm A→C **189010**; sha256↔sha256 TM **187757** (aarch64, N=1) |
| Median round-trip ms H / F | not locked (N=1 wall time not a median) |

**Lock:** IBC stores stay SHA-256. Full-BLAKE3 IBC is rejected: native 07-tendermint ConnOpenTry fails `unexpected HashOp: 9`. 08-wasm RecvPacket is ~1% above TM, not a reason to drop `SHA256Stores`. Live non-IBC names stay SHA-256 on the v6.3 ELF; BLAKE3 is dest `b3-*` only until v6.4.
