# Upgrade Workflow

Current coordinated upgrade on this tree: **v6.3 then v6.4** (hasher dest copy
→ keepers on BLAKE3 dest). Cosmovisor directories are plan names, not git tags:

`~/.terpd/cosmovisor/upgrades/v6.3/bin/terpd`  
`~/.terpd/cosmovisor/upgrades/v6.4/bin/terpd`

Governance submits **only** `v6.3`. The v6.3 binary arms `v6.4` at apply+2.

v6.0 (`plan v6`, bulk_memory VM) already shipped. Those TSH scripts live in
`tests/tsh/upgrade/archive/v6.0/`. Do not use them as this gate.

## TLDR

1. Handler unit tests: `go test ./app/upgrades/v6_3/` and `-tags v64 ./app/upgrades/v6_4/`.
2. E2E: `make tsh-upgrade` (Cosmovisor dual-halt + dest-bank BLAKE3 proofs +
   CosmWasm guest survival + 08-wasm LC on a counterparty).
3. Curate bit-for-bit ELFs: [`networks/upgrades/v6.3/CURATE.md`](../../networks/upgrades/v6.3/CURATE.md).
   Do not upload, tag, or broadcast until asked.
4. Expedited proposal on testnet, then mainnet. Heights TBD.

## 1. Upgrade handler unit tests

- `app/upgrades/v6_3/` — dest `b3-*` Added, KV copy, refuse IBC stores, arm `v6.4`.
- `app/upgrades/v6_4/` (`-tags v64`) — keepers on dest, live SHA-256 names Deleted, empty Renamed.

## 2. E2E / tsh

| Target | Script | What it proves |
|--------|--------|----------------|
| `make tsh-upgrade` | `tests/tsh/upgrade/v63.sh` | Cosmovisor `v6.3` then `v6.4`; dest bank BLAKE3; `ibc` SHA-256; `cw_template` guest survives; 08-wasm LC VerifyMembership |
| `make tsh-upgrade-wasm` | same (`HASH_WASM=1`) | Same; fail if guest store/query/execute does not survive |
| `make tsh-upgrade-cv` | same | Cosmovisor is the dual-halt (not a separate v6 swap) |
| `make tsh-upgrade-v63` | `v63.sh` | Alias |
| `make tsh-upgrade-v6-archive` | `archive/v6.0/a.sh` | Historical 5.2 → plan `v6` only |

`a.sh` / `d.sh` / `e.sh` at the upgrade dir root **exec `v63.sh`**. The v6.0
bodies are under `archive/v6.0/`.

## 3. Prepare upgrade assets

See [`networks/upgrades/v6.3/CURATE.md`](../../networks/upgrades/v6.3/CURATE.md).

Libwasmvm dynamic libraries (glibc `.so`, Darwin dylib) and muslc archives
are built with **our** images `terpnetwork/zk-*-builder:4.0.0-zk`
(`ghcr.io/terpnetwork/zk-*-builder:4.0.0-zk`). Do **not** pull
`cosmwasm/libwasmvm-builder:0103-*`. Write-up:
[`crates/zk-wasmvm/docs/BUILDERS.md`](../../crates/zk-wasmvm/docs/BUILDERS.md).

```sh
(cd crates/zk-wasmvm/builders && make docker-images-4.0.0-zk)
make wasmvm-release-build
make wasmvm-verify
./scripts/release/curate_v63.sh
# then cut linux ELFs (muslc, two tags):
TAG=v6.3.0 PLATFORMS=linux/amd64,linux/arm64 ./scripts/release/fresh-vm/run.sh
TAG=v6.4.0 BUILD_TAGS=v64 PLATFORMS=linux/amd64,linux/arm64 ./scripts/release/fresh-vm/run.sh
PLAN=v6.3 make recurate-upgrade-binaries
PLAN=v6.4 make recurate-upgrade-binaries
make verify-upgrade-pack PLAN=v6.3
make verify-upgrade-pack PLAN=v6.4
```

Do not invent S3 checksums. `published: false` until linux tarballs are on
S3; then `CHECK_S3=1`. Pack identity is
`ARTIFACT_LOCK` ↔ `binaries.json` ↔ `cosmovisor.json` ↔ optional S3
`sha256sum.txt`.

## 4. Testnet then mainnet

Create proposal on testnet first. Confirm Cosmovisor auto-restart **twice**
(v6.3, then v6.4 two blocks later). Then mainnet expedited proposal for **v6.3
only**.
