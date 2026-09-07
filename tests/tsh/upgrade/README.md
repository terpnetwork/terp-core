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

`make tsh-upgrade-v61` curls `pruned/snapshot.json` `latest` unless `SNAPSHOT_PATH` / `SNAPSHOT_URL` is set. Genesis is pulled separately (`GENESIS_URL` default: morocco-1 genesis). The tar is **`data/` + `wasm/` only**.

Start the in-place net with **`terpd-v6`**, not 5.2.0. A 5.2.0 load of a post-v6 pack dies (`expected 22911849 got 0`). After halt, this tree’s `terpd` applies plan `v6.1`. Then `query-all-params.sh` and `iavl-v2.sh`.

```sh
# PATH has terpd-v6 (v6) and terpd (this tree)
STATE_SYNC=0 sh tests/tsh/upgrade/v61.sh
# or pin the object:
STATE_SYNC=0 SNAPSHOT_URL='https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4' \
  sh tests/tsh/upgrade/v61.sh
```

Do not point at archive `22749033` or pruned `22807932` — those are pre-v6.

## v6.2 — Cosmovisor dual halt (A then B, 2 blocks)

`make tsh-upgrade-v62-cv`. Same snapshot pin. Cosmovisor genesis = `terpd-v6`, `upgrades/v6.1` = `terpd-v61` (`feat/6.1.0-dev`), `upgrades/v6.2` = this tree. v6.1 handler arms v6.2 at height+2 (`x/upgrade` keeps one plan). Dual-message proposal JSON is written for the operator tx; last `ScheduleUpgrade` would otherwise overwrite v6.1.

```sh
OLD_BIND=terpd-v6 V61_BIND=terpd-v61 SKIP_INSTALL=1 STATE_SYNC=0 \
  SNAPSHOT_URL='https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4' \
  make tsh-upgrade-v62-cv
```

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
