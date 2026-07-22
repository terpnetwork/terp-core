# Epic — IMPLEMENT: connect private swaps → continuous pipeline

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Mode** | **Full implementation** of G1–G4 design freezes |
| **Design pack** | this folder (`DESIGN-*.md`, `HANDOFF.md`) |
| **Session goal (user)** | Complete pipeline integration so we can send **shielded ZEC** |
| **Honest bar this wave** | Continuous local multi-net: deposit identity → mint SEAM → note-coupled swap → CW settle + dest seal. **Shielded ZEC send** = Phase F residual unless ZEC-EGRESS track lands a lab open path |

## Implement tracks (fresh agents)

| Track | Gap | Prompt | STATUS out | Depends |
|-------|-----|--------|------------|---------|
| IMPL-DEST-SEAL | G4 | `PROMPT-IMPL-DEST-SEAL.md` | `STATUS-IMPL-DEST-SEAL.md` | none |
| IMPL-IDENTITY-CLAIM | G1 | `PROMPT-IMPL-IDENTITY-CLAIM.md` | `STATUS-IMPL-IDENTITY-CLAIM.md` | G4 dest SSOT (golden file already exists) |
| IMPL-NOTE-SWAP-SPEND | G2 | `PROMPT-IMPL-NOTE-SWAP-SPEND.md` | `STATUS-IMPL-NOTE-SWAP-SPEND.md` | G1 evidence shape (design frozen) |
| IMPL-HARNESS-SETTLE | G3 | `PROMPT-IMPL-HARNESS-SETTLE.md` | `STATUS-IMPL-HARNESS-SETTLE.md` | G1/G2 APIs as they land; use HANDOFF maps if siblings late |
| META-DELTA-ZEC | end-goal | `PROMPT-META-DELTA-SHIELDED-ZEC.md` | `STATUS-DELTA-SHIELDED-ZEC.md` | reads designs + impl STATUS |

## Parallelism

- G4, G1, G2 implement in **parallel** (interfaces frozen).
- G3 implements in **parallel** but must fail-closed if evidence missing; integrate when G1/G2 land.
- META writes delta doc for **shielded ZEC send** vs this wave.

## Shared rules

- Prefer in-tree: hash-market, headstash, private_dex_seams, compose_seams, cw-private-dex, test-press, corridor e2e scripts.
- Do **not** amend D1–D7 freezes.
- Label `mock_verify` lab; no mainnet claims.
- After code: run tests listed in your DESIGN acceptance section; write STATUS with evidence.
- Update `HANDOFF.md` status lines from “design freeze” → “implemented” when done.
