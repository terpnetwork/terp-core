# v6.3.0 release notes

Governance plan **`v6.3`**. Binary tag **`v6.3.0`** (`dccfa94`).
Cosmovisor directory `upgrades/v6.3`. This binary does the dest copy and
then arms plan **`v6.4`**.

## What changed

- IAVL dest stores `b3-*` are copied with **BLAKE3** inner nodes. Live
  names stay on SHA-256 until v6.4. IBC and `08-wasm` stay SHA-256.
- No `StoreUpgrades.Renamed` of dest onto live store names.
- WasmVM is **4.0.0-zk** (Go import still `wasmvm/v3`). Host libs are built
  with `terpnetwork/zk-*-builder:4.0.0-zk`, not `cosmwasm/libwasmvm-builder:0103-*`.
- Builders are local compile images. They are not pushed to GHCR or
  `registry.terp.network`. The operator image is `registry.terp.network/terp-core:v6.3.0`.

## Cosmovisor info

When this binary applies, `plan.info` for **`v6.4`** is compact JSON with
the **published** v6.4.0 tarball sha256 values, not a bare URL. Cosmovisor
checks those checksums before it runs `upgrades/v6.4/bin/terpd`.

Gov `plan.info` for **`v6.3`** is the compact JSON in
[`cosmovisor.json`](./cosmovisor.json).

Published:

- https://s3.terp.network/releases/terp-core/v6.3.0/
- https://s3.terp.network/upgrades/v6.3/cosmovisor.json

Linux amd64 and arm64 only. Height is still TBD. Do not start until v6.2
has applied.

## Linux link

Cosmovisor ELFs are `LINK_STATICALLY=true`. The link uses `ld.bfd` and
`-static-pie` so the muslc wasmvm archive is inside the binary. Alpine's
default gold linker drops that archive. The **published** v6.3.0 and v6.4.0
tarballs were built before this flag. A recurate after the flag will not
match those sha256 values until you publish a new cut on purpose.

## How it was checked

morocco-1 pruned snapshot, in-place-testnet: halt `v6.3` then `v6.4` two
blocks later. Dest bank proofs are BLAKE3. IBC proofs stay SHA-256. An
08-wasm light client verified a dest-bank membership proof.
