# Team roster — IMPL wave (connect private swap)

**Mode:** full implementation of G1–G4 + META delta for shielded ZEC  
**Pack:** `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/`  
**Spawned:** 2026-07-22 (fresh agents; design freezes as plan SSOT)

| Track | Gap | Prompt | STATUS | Grok subagent_id |
|-------|-----|--------|--------|------------------|
| IMPL-DEST-SEAL | G4 | `PROMPT-IMPL-DEST-SEAL.md` | `STATUS-IMPL-DEST-SEAL.md` | `019f8b7a-0540-7af3-b4fa-5637f9d1c08c` |
| IMPL-IDENTITY-CLAIM | G1 | `PROMPT-IMPL-IDENTITY-CLAIM.md` | `STATUS-IMPL-IDENTITY-CLAIM.md` | `019f8b7a-0541-78c0-b605-9fd740e7620c` |
| IMPL-NOTE-SWAP-SPEND | G2 | `PROMPT-IMPL-NOTE-SWAP-SPEND.md` | `STATUS-IMPL-NOTE-SWAP-SPEND.md` | `019f8b7a-0544-7840-85ce-6b790e6830b3` |
| IMPL-HARNESS-SETTLE | G3 | `PROMPT-IMPL-HARNESS-SETTLE.md` | `STATUS-IMPL-HARNESS-SETTLE.md` | `019f8b7a-0544-7840-85ce-6b8c85d1e46c` |
| META-DELTA-ZEC | end-goal | `PROMPT-META-DELTA-SHIELDED-ZEC.md` | `STATUS-DELTA-SHIELDED-ZEC.md` | `019f8b7a-0544-7840-85ce-6b9640b97884` |

Design agents (prior wave) remain reference only; this wave is **fresh implementers** holding DESIGN+HANDOFF.

## Parent review notes (delegation)

IMPL prompts are reviewable at:
- `PROMPT-IMPL-DEST-SEAL.md`
- `PROMPT-IMPL-IDENTITY-CLAIM.md`
- `PROMPT-IMPL-NOTE-SWAP-SPEND.md`
- `PROMPT-IMPL-HARNESS-SETTLE.md`
- `PROMPT-META-DELTA-SHIELDED-ZEC.md`

**Session end-goal honesty:** G1–G4 = continuous identity + note-coupled swap + CW settle + dest seal. **“Send shielded ZEC”** still needs Phase F (live open/broadcast) — META track owns that delta matrix.
