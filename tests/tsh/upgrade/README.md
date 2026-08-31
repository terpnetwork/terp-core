# Upgrade From Latest Main-net state

Ensure live network data does not corrupt upgrade integrity.

```sh
sh a.sh
```

## D — existing CosmWasm guests across the v6 VM upgrade

Mirrors `b.sh` (local genesis + gov `software-upgrade` named `v6`) and proves a
contract stored on the **current** mainnet binary still **queries and executes**
after the new binary (metered `bulk_memory`) takes over.

```sh
# needs terp-mainnet on PATH (v5.x, no bulk_memory) and this tree installed as terpd
sh d.sh
```

Claim if it exits 0: updating the VM to support bulk memory does not brick
existing smart contracts from working.


## E — Cosmovisor auto-swap at v6

Mirrors `b.sh` but starts the node with **Cosmovisor**. Genesis binary is
`terp-mainnet`; `upgrades/v6/bin/terpd` is this tree. The process must stay up
across halt.

```sh
make tsh-upgrade-cv
# or: SKIP_INSTALL=1 sh e.sh
```

## v6.1 — morocco-1 snapshot, IAVL dual-store copy + IAVL v2 ingest

In-place testnet from a **pruned morocco-1 snapshot** (or statesync), halt on plan `v6.1`, new binary copies `bank`/`staking`/`acc` into `b3-bank` / `b3-staking` / `b3-acc` IAVL trees (names avoid SDK store-key prefix collision). IBC stores stay SHA-256. Then `iavl-v2.sh` runs IAVL v2 ingest tests (SHA-256 vs BLAKE3 roots must differ). CMS stays IAVL v1.

```sh
make tsh-upgrade-v61

STATE_SYNC=0 SNAPSHOT_PATH=/path/to/morocco-1-pruned.tar.lz4 \
  sh tests/tsh/upgrade/v61.sh

STATE_SYNC=1 sh tests/tsh/upgrade/v61.sh
```

Needs `terp-mainnet` on PATH (no `v6.1` handler) and this tree as `terpd`. See `crates/cosmos/iavl/docs/MAINNET_MIGRATION.md`.

## 120u-1 soak (plan v6.1)

Not TSH `c.sh`. Curate, compile, stage. Does not broadcast.

```sh
make curate-v61
make tsh-upgrade-120u-1
# SUBMIT=1 KEY=<key> only when asked
```

See `networks/upgrades/v6.1/WORKFLOW.md`.

ict-rs Docker upgrade (`make e2e-upgrade`) still defaults to plan `v6`. For v6.1:

```sh
ICT_UPGRADE_NAME=v6.1 cargo run --manifest-path tests/interchaintest/Cargo.toml --bin upgrade
```
