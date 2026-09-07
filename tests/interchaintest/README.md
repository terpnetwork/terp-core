# terp-e2e (ict-rs)

Rust binaries that replaced the Go `interchaintest` package. Sources live in
`crates/ict-rs/examples/` (plus a few module smokes in `src/bin/`).

```sh
# mock (no Docker)
cd tests/interchaintest
cargo run --bin basic
cargo run --bin tokenfactory   # ICT_MOCK=1 implied by mock runtime inside these bins

# docker (needs terpnetwork/terp-core:local)
cargo run --bin ibc
cargo run --bin polytone
```

From repo root: `make e2e` then `make e2e-basic`, `make e2e-ibc`, …

| Old Go test | Binary | ict-rs example |
|---|---|---|
| `TestBasicTerpStart` | `basic` | `integration_test.rs` |
| (chain boot) | `chain_start` | `basic_cosmos.rs` |
| `TestTerpGaiaIBCTransfer` | `ibc` | `ibc_transfer.rs` |
| `TestTerpIBCHooks` | `ibchooks` | `ibc_hooks.rs` |
| `TestPacketForwardMiddlewareRouter` | `pfm` | `pfm.rs` |
| `TestPolytoneOnTerp` | `polytone` | `polytone.rs` |
| `TestTerpStateSync` | `statesync` | `state_sync.rs` |
| `TestBasicTerpUpgrade` | `upgrade` | `cosmos_upgrade.rs` (`ICT_UPGRADE_NAME=v6.1` / `ICT_UPGRADE_WORKFLOWS=core,iavl`; snapshot IAVL v2 ingest is `make tsh-upgrade-v61`) |
| `TestTerpZkCosmwasmVm` | `zk` | `no_rick.rs` |
| `TestTerpTokenFactory` | `tokenfactory` | `src/bin/tokenfactory.rs` |
| `TestTerpFeeShare` | `feeshare` | `src/bin/feeshare.rs` |
| `TestTerpDrip` | `drip` | `src/bin/drip.rs` |
| `TestTerpClock` | `clock` | `src/bin/clock.rs` |
| (new) | `circuit_deposit` | `circuit_deposit.rs` |
| (new) | `circuit_runway_epoch` | 3-val Docker epoch settle (`make e2e-circuit-runway-docker`, image `terpnetwork/terp-core:local-zk`) |

Contract wasm for polytone/zk lives in `contracts/` and `circuits/` (copied from `artifacts/`).
