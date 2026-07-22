# STATUS-DELTA — Full pipeline + send shielded ZEC vs G1–G4 wave

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Track** | META-DELTA-ZEC (refreshed post-IMPL) |
| **Epic** | `connect-private-swap-design-prep-2026-07-22` |
| **Session goal (human)** | Full pipeline integration so we can **send shielded ZEC** |
| **This wave bar** | Continuous local multi-net under `mock_verify` lab — **not** live ZEC send |

---

## 0. Evidence state (post-IMPL refresh)

| Artifact | Present? | Notes |
|----------|----------|-------|
| DESIGN freezes G1–G4 | **Yes** | |
| `STATUS-IMPL-DEST-SEAL.md` | **Yes** | G4 green (tests listed) |
| `STATUS-IMPL-IDENTITY-CLAIM.md` | **Yes** | G1 green (16+ claim_from_deposit tests) |
| `STATUS-IMPL-NOTE-SWAP-SPEND.md` | **Yes** | G2 green (W5 no synthetic NoteIn) |
| `STATUS-IMPL-HARNESS-SETTLE.md` | **Yes** | G3 green (suite + binary; Docker not agent-run) |
| HANDOFF G1–G4 | **Implemented** | |
| Full Docker `demo-corridor-ict-settle` | **Not agent-run** | Human path documented |
| Live ZEC broadcast / open | **No** | Phase F residual |

**First META draft was early** (wrote before IMPL STATUS landed). This refresh is authoritative for “after G1–G4 code.”

---

## 1. Pipeline stages table

| Stage | Required for shielded ZEC **send** | G1–G4 wave | Status **now** (post-IMPL) | Delta remaining |
|-------|------------------------------------|------------|----------------------------|-----------------|
| BTC deposit observe | yes | partial→G1 | **Green+** `vout` + claim-inputs API | Funded Docker still human-verify |
| Continuous mint claim | yes | G1 | **`claim_from_deposit_watch` + harness prefer-deposit** | Joint T12 regtest claim-inputs→mint end-to-end Docker |
| Dest seal preauth | yes | G4 | **Golden funded path; placeholder reject** | Equality on full Docker receipt |
| Private swap of mint note | yes | G2 | **W5 SEAM openings → `apply_swap_action`** | Align G2 evidence JSON ↔ G3 `MintEvidenceV0` in one continuous Docker run |
| On-chain settle | yes (product) | G3 | **`CORRIDOR_CHAIN_SETTLE` → CreatePool+SettleSwap+receipt** | Human Docker `just demo-corridor-ict-settle` |
| Post-swap Action / unshield | maybe | **no** | Absent | Skip-shaped Action follow-on if needed |
| Shielded ZEC **note out** (ZEC consensus) | **yes for send** | narrative only | Terp `cm_out` / ZEC **registry id** on statement — **not** Orchard/Zcash note | Durable ZEC-side construction |
| Live open / **broadcast** to dest | **yes for “send”** | **out of wave** | Pure W7 / binding film only | **Phase F ZEC-EGRESS** |
| `mock_verify=false` / LC | production | **no** | Lab mock default | Phase G |

```text
HUMAN END-GOAL:
  observe → continuous mint → note-coupled swap → settle → **send shielded ZEC to preauth dest**

G1–G4 CODE (landed):
  observe(+vout) → claim_from_deposit → dest seal → SEAM spend → CW SettleSwap (mock_verify)
  [no live ZEC broadcast]

PHASE F / OPTION D (LOCKED 2026-07-22):
  BridgeEgressBurn on Terp → Zcash mint/pay to preauth dest only
  See: DESIGN-DECISIONS-ZEC-EGRESS-OPTION-D-ACCEPTED-2026-07-22.md
  Epic: agents/zec-egress-option-d-2026-07-22/

PHASE G (production) — NON-CLAIM:
  real proofs + LC + mainnet
```

---

## 2. Definition of done — three bars

| Bar | Meaning | Verdict **now** |
|-----|---------|-----------------|
| **Continuous local multi-net** | Identity + note-coupled swap + CW settle + dest seal under local nets | **Code landed** (unit/suite green). **Docker full pipeline** still human verification residual. |
| **Lab shielded ZEC open/send** | Value **on ZEC network** at sealed dest | **NOT this wave** — Phase F residual |
| **Production send** | Mainnet + real proofs | **Non-claim** |

### What “send shielded ZEC” requires beyond G1–G4

1. ~~Preauth dest continuous~~ → **G4 landed**  
2. ~~Terp path spends real mint note~~ → **G1+G2 landed** (Docker continuous join residual)  
3. **ZEC-network** tx or lab fund+receive at sealed dest → **missing (Phase F)**  
4. Labels for mock/lab still disclosed → **yes when settle profile used**

**G1–G4 cannot close (3).** Claiming “we can send shielded ZEC” after this wave alone would be **overclaim**.

---

## 3. Minimal extra work for “lab send shielded ZEC”

| # | Work | Owner | Notes |
|---|------|-------|-------|
| 1 | Human: `just prepare-corridor-ict-wasm-settle` + `just demo-corridor-ict-settle` | ops | Prove G3 Docker path once |
| 2 | Continuous join: deposit env → claim ν on chain = observe; dest equality on receipt | HARNESS | T12 residual from G1 STATUS |
| 3 | **ZEC-EGRESS lab:** Zakura up + fund/receive or broadcast to golden dest | new track | F1/F2 |
| 4 | UI/poll only when F proves chain ZEC | UI | no mock “ZEC sent” |
| 5 | Optional: post_swap Action if product needs unshield→rail | follow-on | not required for lab fund+open |

---

## 4. Delegation prompt review (IMPL prompts)

| Prompt | Strength | Risk / fix |
|--------|----------|------------|
| `PROMPT-IMPL-DEST-SEAL` | Clear SSOT + fail-closed | Good. |
| `PROMPT-IMPL-IDENTITY-CLAIM` | Builder + harness preference | Race with G4: dest source — OK via golden file already present. |
| `PROMPT-IMPL-NOTE-SWAP-SPEND` | Kill synthetic NoteIn | Dual evidence types (`MintSpendEvidence` vs G3 `MintEvidenceV0`) — **align next**. |
| `PROMPT-IMPL-HARNESS-SETTLE` | Fail-closed settle | Docker not in agent scope — STATUS correctly labels. |
| `PROMPT-META-DELTA` | Honesty | Early write before IMPL — **this refresh** fixes. |

**Overclaim risk in prompts:** IMPL-ORCHESTRATION session goal line mentions “send shielded ZEC” — correct to pair with META bar table. Keep product claims at continuous multi-net until Phase F green.

---

## 5. Recommendation

| Gate | Status |
|------|--------|
| Design freezes + HANDOFF | **Complete** |
| G1–G4 implementation (unit/suite) | **Complete** (per STATUS-IMPL-*) |
| Full Docker continuous corridor + settle | **Human residual** |
| **Session can claim “pipeline integrated for Terp private path”** | **Yes (lab, mock_verify), pending Docker smoke** |
| **Session can claim “send shielded ZEC”** | **No** — spawn **ZEC-EGRESS** Phase F next |

**Next session / track:** `ZEC-EGRESS-LAB` — local open + optional broadcast to G4 sealed dest only; wire receipt so UI fails closed without chain ZEC proof.
