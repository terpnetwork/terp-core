# Team roster — connect private swap design-prep

**Mode:** design review / impl-ready packs (not large implementation)  
**Pack:** `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/`  
**Execution:** Grok subagents (not Hermes workers)  
**Spawned:** 2026-07-22

| Track | Gap | Prompt | DESIGN file | Grok subagent_id |
|-------|-----|--------|-------------|------------------|
| IDENTITY-CLAIM | G1 | `PROMPT-IDENTITY-CLAIM.md` | `DESIGN-IDENTITY-CLAIM.md` | `019f8b72-ad0f-7451-9d24-60b67403b1f9` |
| NOTE-SWAP-SPEND | G2 | `PROMPT-NOTE-SWAP-SPEND.md` | `DESIGN-NOTE-SWAP-SPEND.md` | `019f8b72-ad0f-7451-9d24-60c33ab3361d` |
| HARNESS-SETTLE | G3 | `PROMPT-HARNESS-SETTLE.md` | `DESIGN-HARNESS-SETTLE.md` | `019f8b72-ad10-7821-b69c-cc89d4603f79` |
| DEST-SEAL | G4 | `PROMPT-DEST-SEAL.md` | `DESIGN-DEST-SEAL.md` | `019f8b72-ad11-7bb0-a587-4ddde85648cb` |

**All write HANDOFF sections into** `HANDOFF.md`.

## Implementation order after designs land

1. G1 + G4  
2. G2 pure note-coupled swap  
3. G3 harness + CW `SettleSwap`  
4. Follow-on: post_swap_action / ZEC egress (not this epic)
