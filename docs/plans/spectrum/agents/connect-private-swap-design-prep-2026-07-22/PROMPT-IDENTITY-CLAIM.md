# PROMPT — DESIGN track IDENTITY-CLAIM (G1)

Read first:
- `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/ORCHESTRATION.md`
- `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/PROMPT-COMMON.md`
- `docs/plans/spectrum/agents/btc-terp-zec-full-e2e-prep-2026-07-22/STATUS-GAP-OBSERVE.md`
- `docs/plans/spectrum/agents/btc-terp-zec-full-e2e-prep-2026-07-22/STATUS-GAP-MINT.md`
- `docs/plans/spectrum/agents/btc-terp-zec-full-e2e-prep-2026-07-22/STATUS-GAP-SYNTHESIS.md` § Phase A

**Your gap:** **G1 — Continuous deposit identity → `BridgeMintClaimPublic`**

**Owns:**
- Provisional nullifier rule (pure fn + domain tag)
- `claim_from_deposit_watch(obs, watch, policy) → BridgeMintClaimPublic` (or equivalent)
- Optional: GET claim-inputs shape for harness (API sketch)
- value ← amount; dest ← dest_owner_binding (from DEST-SEAL handoff)
- Lab flags / mock_verify still allowed; label them

**Does not own:** harness shell wiring (G3), swap spend (G2), Zakura RPC (G4 implementation) — only dest field **source** contract.

**Write:**
1. `DESIGN-IDENTITY-CLAIM.md`
2. Append `## G1 IDENTITY-CLAIM` to `HANDOFF.md`

**Freeze at minimum:**
- `nullifier = H(domain ‖ txid ‖ vout ‖ intent_id)` exact domain string
- Field map: observation JSON keys → claim fields
- Fail-closed if txid/amount/dest missing
