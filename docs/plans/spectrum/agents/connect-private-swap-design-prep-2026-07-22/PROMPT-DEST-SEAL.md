# PROMPT — DESIGN track DEST-SEAL (G4)

Read first:
- `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/ORCHESTRATION.md`
- `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/PROMPT-COMMON.md`
- `docs/plans/spectrum/agents/btc-terp-zec-full-e2e-prep-2026-07-22/STATUS-GAP-ZAKURA.md`
- `docs/plans/spectrum/agents/final-sprint-2026-07-22/STATUS-ZAKURA-DEST.md`
- Zakura golden / preauth helpers used by UI and harness (`dest_owner_binding`)
- `docs/plans/spectrum/e2e/corridor-ict-funded.sh` (watch dest placeholders)

**Your gap:** **G4 — Dest seal continuous: golden/live `dest_owner_binding` on funded path**

**Owns:**
- Replace funded-path placeholder dest (`"b"*64` etc.) with golden primary binding
- Optional live: `validateaddress` / RPC when Zakura up; skip-clean when not
- Equality asserts end-to-end: watch dest == claim dest == (later) swap owner_binding narrative
- UI/offline paste path remains valid; funded path must not invent dest

**Does not own:** BridgeMint claim builder body (G1 consumes dest), swap math (G2), SettleSwap execute (G3), live ZEC broadcast (residual Phase F).

**Write:**
1. `DESIGN-DEST-SEAL.md`
2. Append `## G4 DEST-SEAL` to `HANDOFF.md`

**Freeze at minimum:**
- SSOT source for golden binding (file/env/just target)
- Watch open field name + width (32-byte hex)
- Fail-closed: empty/placeholder dest rejected on product funded path
