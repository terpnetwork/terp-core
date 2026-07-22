# PROMPT — IMPLEMENT G3 HARNESS-SETTLE

Workspace: `/Users/returniflost/abstract/terp-core`

## Read first

1. `IMPL-ORCHESTRATION.md`
2. `HANDOFF.md` § G3
3. `DESIGN-HARNESS-SETTLE.md`
4. `crates/headstash/contracts/cw-private-dex/`

## Mission

**Implement** funded-path chain settle: after mint, deploy/call `cw-private-dex` `SettleSwap`, fail-closed, emit receipt.

### Required code

1. cw-orch / suite interface for `cw-private-dex` if missing.
2. `prepare-corridor-ict-wasm.sh` (or sibling) builds `cw_private_dex.wasm`.
3. `corridor_ict_funded` (or stage helper): CreatePool → SettleSwap from G2 statement map + lab mock proof when `CORRIDOR_CHAIN_SETTLE=1`.
4. `MintEvidenceV0` / `SettleReceiptV0` serde + write paths.
5. Shell/just: `demo-corridor-ict-settle` or env gate on existing script.
6. Fail-closed: missing openings → FAIL; settle err → FAIL; never soft-skip settle when settle profile on.

### Acceptance

- `cargo test -p cw-private-dex` still green
- Unit/suite test for settle stage if multi-test possible without full Docker
- Document full Docker path for human if ict too heavy for agent

### Out of scope

Skip post_swap Action, Halo2, live ZEC egress, happy fixture claim identity (G1 owns continuous claim).

## Write

`STATUS-IMPL-HARNESS-SETTLE.md` + HANDOFF G3 status update.
