# PROMPT — IMPLEMENT G2 NOTE-SWAP-SPEND

Workspace: `/Users/returniflost/abstract/terp-core`

## Read first

1. `IMPL-ORCHESTRATION.md`
2. `HANDOFF.md` § G2
3. `DESIGN-NOTE-SWAP-SPEND.md`

## Mission

**Implement** mint SEAM → `SwapActionV0` product path (no synthetic `NoteIn` on corridor product/W5).

### Required code

1. `MintSpendEvidence`, `CorridorSwapSpendParams` in `compose_seams` (or agreed home).
2. `seam_note_out_to_swap_action`, `seam_note_out_to_swap_openings`, `mint_evidence_to_swap_action` thin wrappers over existing private_dex_seams builders.
3. `swap_action_public_to_statement` helper mapping to CW `SwapStatementPublic` fields (can live in compose_seams or test-press for G3).
4. Update cashapp W5 / product path to spend real SEAM openings when evidence present.
5. Tests: mint sketch → apply_swap_action reserves + pool ν ≠ bridge ν; oracle required on product params.

### Acceptance

- `cargo test` on compose_seams / private_dex_seams / zk-test-press for new paths green

### Out of scope

Daemon SettleSwap (G3), claim builder (G1), dest golden (G4).

## Write

`STATUS-IMPL-NOTE-SWAP-SPEND.md` + HANDOFF G2 status update.
