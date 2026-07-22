# PROMPT — DESIGN track HARNESS-SETTLE (G3)

Read first:
- `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/ORCHESTRATION.md`
- `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/PROMPT-COMMON.md`
- `docs/plans/spectrum/agents/btc-terp-zec-full-e2e-prep-2026-07-22/STATUS-GAP-HARNESS.md`
- `docs/plans/spectrum/agents/STATUS-CW-PRIVATE-DEX-2026-07-22.md`
- `crates/headstash/contracts/cw-private-dex/` (msg, settle, mock_verify)
- `docs/plans/spectrum/e2e/corridor-ict-funded.sh`
- `crates/headstash/test-press/src/bin/corridor_ict_funded.rs`
- `crates/dex/contracts/pair` only as transparent reference (not to reimplement)

**Your gap:** **G3 — Wire funded harness → on-chain `SettleSwap`**

**Owns:**
- How corridor-ict / test-press deploys or uses `cw-private-dex`
- Build `SwapStatementPublic` + proof from G2 handoff (mock_verify lab)
- Fail-closed if mint evidence / openings missing
- Assert post-settle: reserves, nullifier spent, attributes
- Artifact/receipt fields for automation (contract, pool_id, Δ, cm_out)
- Honest labels: mock_verify vs zk-api

**Does not own:** claim_from_deposit (G1), pure SEAM→opening math (G2 design owns pure; harness may call it), dest golden (G4).

**Write:**
1. `DESIGN-HARNESS-SETTLE.md`
2. Append `## G3 HARNESS-SETTLE` to `HANDOFF.md`

**Freeze at minimum:**
- Env vars / just target sketch for “funded + settle”
- Daemon/cw-orch call sequence after mint
- Soft-skip policy: mint/settle failure = FAIL (no silent film green)
