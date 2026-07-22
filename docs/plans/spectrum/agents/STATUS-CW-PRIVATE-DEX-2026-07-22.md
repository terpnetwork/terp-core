# STATUS: cw-private-dex (private settle + proof_instance_verify)

| Field | Value |
|-------|-------|
| **Date** | 2026-07-22 |
| **Package** | `crates/headstash/contracts/cw-private-dex` |
| **Workspace** | `crates/headstash` member |
| **Tests** | `cargo test -p cw-private-dex` → **11 passed** |

## Intent

Mirror pure `private_dex_seams` (`apply_swap_action`) into a CosmWasm contract, with proof acceptance powered by the CosmWasm fork API:

```text
deps.api.proof_instance_verify(zkid, proof, instances)
```

Contract **wiring** extends the in-tree **`crates/dex`** fork of [astroport-core](https://github.com/astroport-fi/astroport-core) (pair swap / simulation / pause), not a greenfield msg surface.

## Design map

| `crates/dex` pair | `cw-private-dex` |
|-------------------|------------------|
| `ExecuteMsg::Swap` | `SettleSwap { statement, proof }` |
| Bank/CW20 offer | Proven note spend (nullifiers) |
| `compute_swap` | `quote_exact_in` (γ/γ_den seam SSOT) |
| `assert_max_spread` | `min_out` + oracle bounds |
| Ask transfer out | `cm_out_*` attributes |
| `Simulation` | `QuoteExactIn` |
| `PoolPaused` | `PoolStatus::Paused` |

No hard dependency on the `astroport` crate (version graph / guest size); designs are referenced and extended.

## Dual-path verify

| Mode | Gate | Status |
|------|------|--------|
| mock_verify | `Config.mock_verify \|\| cfg!(test)` | **wired + tested** |
| `proof_instance_verify` | feature `zk-api` → `cosmwasm-std/zk` | **wired** (host export required) |
| fail-closed | prod without zk-api | **wired** |

Default guest build omits `zk` (stock wasmd floor), same as BridgeMintNote.

## Honest residual

- No Halo2 swap circuit yet — production proofs need a registered zkid + circuit.
- Virtual reserves only (not transparent LP / factory / incentives from `crates/dex`).
- Identity coupling (mint → swap note) still Phase A/B from e2e gap synthesis.
- Not continuous BTC→ZEC e2e; this is the **chain settle seam** for private swap.

## Verify

```bash
cd crates/headstash && cargo test -p cw-private-dex
```
