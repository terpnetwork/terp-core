# STATUS — IMPL G2 NOTE-SWAP-SPEND

| Field | Value |
|-------|--------|
| **Track** | IMPL-NOTE-SWAP-SPEND (G2) |
| **Date** | 2026-07-22 |
| **Result** | **Green** — mint SEAM → `SwapActionV0` product path; no synthetic `NoteIn` on W5 / product |
| **Out of scope (honored)** | Daemon `SettleSwap` (G3), claim builder (G1), dest golden (G4) |

## Delivered

### Pure product APIs (`compose_seams`)

| Name | Role |
|------|------|
| `MintSpendEvidence` | Carrier: `SeamNoteOutV0` + `bridge_nullifier` + optional chain coords + `path_position` |
| `MintSpendEvidence::from_seam_note` / `from_note_out_sketch` | DEX-consumable gates (`rcm_flag=1`) |
| `CorridorSwapSpendParams` | Product params; **required** `oracle_mid` + `oracle_params.require_oracle` |
| `seam_note_out_to_swap_action` | Normative builder → `SwapActionV0` |
| `seam_note_out_to_swap_openings` | Openings-only (tests) |
| `mint_evidence_to_swap_action` | Harness entry |
| `swap_action_public_to_statement` → `SwapStatementPublicView` | G3 field map (pure host DTO; no CW dep; omits `now_height`) |
| `run_product_path_burn_to_swap_oracle_zec` | Product pure E2E: oracle + registered sim-ZEC `asset_out` + apply |

SSOT spend compose remains `private_dex_seams::build_swap_action_from_seam_notes` / `apply_swap_action`.

### Harness W5

`cashapp_zec_corridor::run_oracle_bound_swap` now:

1. `MintSpendEvidence::from_note_out_sketch(mint_note)`
2. Register mint `asset_id` + intent `asset_out_id` (sim-ZEC)
3. `CorridorSwapSpendParams` with oracle required
4. `mint_evidence_to_swap_action` → `apply_swap_action`
5. Receipt `note_cm_public_hex` = **spent** SEAM `cm_public` (abstract-leaf recompute)

**Removed** synthetic `NoteIn { nullifier: u64 }` + legacy `apply_swap` on the happy product path.

### Re-exports

`harness/compose_l0.rs` re-exports G2 builders + `assert_product_path_burn_to_swap_oracle_zec`.

## Tests (evidence)

| ID | Command / assertion | Result |
|----|---------------------|--------|
| T1 | `cd docs/plans/spectrum/fixtures/private_dex_seams && cargo test` | **23 passed** |
| T2 | `cd docs/plans/spectrum/fixtures/compose_seams && cargo test product_path_burn_to_swap_sketch` | **passed** (15 total compose tests green) |
| T3 | `product_path_burn_to_swap_oracle_zec` — openings.cm/rcm == mint; ZEC asset_out | **passed** |
| T4 | pool ν == `synthetic_pool_spend_nf` ∧ ≠ bridge lineage | **passed** |
| T5 | missing rcm / wrong asset / `require_oracle=false` | **passed** |
| T6 | `oracle_mint_note` → `ErrOracleDisabledMint` | **passed** |
| T7 | `cargo test -p zk-test-press --lib cashapp_zec --features 'interface,l0-seams'` | **7 passed**, 1 ignored (live LC) |
| T8 pure half | statement view 32B widths | **passed** in compose tests |

G3 owns CW `swap_action_public_to_cw` (`harness/swap_statement_cw.rs`); pure map lives in compose.

## Paths touched

| Path | Change |
|------|--------|
| `docs/plans/spectrum/fixtures/compose_seams/src/lib.rs` | G2 types, builders, product oracle+ZEC path, tests |
| `crates/headstash/test-press/src/harness/cashapp_zec_corridor.rs` | W5 SEAM spend path |
| `crates/headstash/test-press/src/harness/compose_l0.rs` | Re-export + oracle_zec assert |
| `…/STATUS-IMPL-NOTE-SWAP-SPEND.md` | this file |
| `…/HANDOFF.md` | G2 status → implemented |

## Residual

- Pure `Pool` still enum-oriented host layout; statement carries 32B registry ids (G3 wires CW pool with Binary assets).
- G3 `SettleSwap` / Daemon settle not wired here.
- Dual `intent_allows_swap` (fixture vs harness) remains P2 cleanup (S-G7).
- Film scripts (`corridor-ict-funded`) may still need mint-evidence threading when Daemon path lands openings end-to-end (G1/G3).
- G3 `MintEvidenceV0` (JSON artifact) is complementary to pure `MintSpendEvidence`; conversion helper optional for later.

## Non-claims

- No Halo2 prove.
- No on-chain pool state after pure apply alone.
- No live ZEC egress.
- Did not amend D1–D7 freezes.
