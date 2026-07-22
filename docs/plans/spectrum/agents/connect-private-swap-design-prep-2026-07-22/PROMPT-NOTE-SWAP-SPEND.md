# PROMPT — DESIGN track NOTE-SWAP-SPEND (G2)

Read first:
- `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/ORCHESTRATION.md`
- `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/PROMPT-COMMON.md`
- `docs/plans/spectrum/agents/btc-terp-zec-full-e2e-prep-2026-07-22/STATUS-GAP-SWAP.md`
- `docs/plans/spectrum/agents/ROUND3-COMPOSE-SWAP.md`
- `docs/plans/spectrum/fixtures/private_dex_seams/src/lib.rs` (`build_swap_action_from_seam_notes`, `SwapActionV0`)
- `docs/plans/spectrum/fixtures/compose_seams`
- `crates/headstash/test-press/src/harness/cashapp_zec_corridor.rs` (W5 synthetic NoteIn)

**Your gap:** **G2 — Minted SEAM note → swap spend openings** (no synthetic `NoteIn`)

**Owns:**
- Map `SeamNoteOutV0` / BridgeMint note result → `SeamNoteSketch` / `SpendNoteOpening`
- Product path: spend **that** note into `SwapActionV0` / pure apply (then handoff to G3 for CW statement)
- Pool-spend ν domain ≠ bridge ingress ν (already pure — keep invariant)
- Oracle bound required on product path (bound_only)
- asset_out = corridor ZEC asset id registry view

**Does not own:** `cw-private-dex` execute wiring (G3), claim builder (G1), dest crypto (G4).

**Write:**
1. `DESIGN-NOTE-SWAP-SPEND.md`
2. Append `## G2 NOTE-SWAP-SPEND` to `HANDOFF.md`

**Freeze at minimum:**
- Function: `seam_note_out_to_swap_openings(...) → SwapActionV0` (or reuse existing builders)
- Public statement fields that G3 will put on `SwapStatementPublic`
- How mint evidence (cm, rcm, asset, value) is carried between stages
