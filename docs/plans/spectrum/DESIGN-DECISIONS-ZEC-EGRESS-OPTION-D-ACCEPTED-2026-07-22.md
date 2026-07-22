# DESIGN DECISION — ZEC egress Option D (ACCEPTED)

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Status** | **ACCEPTED / LOCKED** |
| **Decision** | After private swap into ZEC-denominated SEAM on Terp, **only Option D** is the product egress path: **private bridge burn of Terp note → Zcash-side mint/pay to preauth dest**. |
| **Board** | `private-bridge-corridor` |
| **Human** | Explicit: “option d. no doubt whatsoever” — lock in repo + implement immediately |

---

## 1. Locked choice

```text
SettleSwap (cw-private-dex)
  → Terp SEAM note (asset = ZEC registry id, cm_out, owner_binding = dest seal)
  → BridgeEgressBurn (spend/burn under nullifier + conservation)
  → Zcash-side mint or inventory pay to sealed dest only
```

| Item | Locked value |
|------|----------------|
| **Egress class** | **D — private bridge** (not host-pay-as-product, not unshield→Skip as product) |
| **Ingress symmetry** | Same authentication loop as bridge mint (Domain B/C spirit): finality / membership / domain bind / one-shot ν / conservation |
| **Dest** | Preauth **G4** seal only — transparent **or** shielded UA both allowed as *receivers* |
| **Oracle** | Bounds only on swap; **never** authorizes egress mint/pay |
| **Lab** | `mock_verify` / inventory fund under **labeled** lab policy OK; structure must match D |
| **Non-product** | A (hold forever), B (host-pay **as sole product**), C (unshield→IBC as product) |

**Lab note:** Host/Zakura may *execute* the Zcash leg in lab (inventory send) **only** after a Terp burn/egress statement is recorded. That is **D with lab Zcash settle**, not Option B as product story.

---

## 2. Explicit rejections (product)

| Option | Status |
|--------|--------|
| A Hold-only as end-state | Intermediate only — not product complete |
| B Host pay without Terp burn evidence | **Rejected** as product (custody-only film) |
| C Unshield + Skip/IBC as product corridor | **Rejected** for Cash App → ZEC private corridor |
| Redirect dest after swap | **Rejected** — seal fixed at intent |

---

## 3. Normative pipeline (product)

```text
1. Intent seals dest_owner_binding (t-addr or UA)           [G4]
2. Deposit → BridgeMintNote (BTC SEAM)                     [G1]
3. Private swap → ZEC SEAM (cm_out, owner = seal)          [G2/G3]
4. BridgeEgressBurn:
     - spend ZEC SEAM (pool/egress ν domain ≠ swap pool ν ≠ bridge ingress ν)
     - public: value, asset_id, dest_commitment, burn/nullifier, proof
     - fail-closed if dest_commitment ≠ seal
5. Zcash leg (lab → prod):
     - lab: inventory pay / fund sealed dest after burn receipt
     - prod: LC-gated mint/pay + real membership (Phase G)
6. Receipt: Terp burn tx + Zcash txid/open proof at dest
```

---

## 4. SSOT documents

| Doc | Role |
|-----|------|
| **This file** | Accepted decision freeze |
| `agents/zec-egress-option-d-2026-07-22/DESIGN-ZEC-EGRESS-D.md` | Implementation design |
| `agents/zec-egress-option-d-2026-07-22/HANDOFF.md` | Cross-track interfaces |
| CLARITY bridge models § burn/mint + LC | Authentication checklist |
| SPEC-lc-hinge-private-bridge | LC hinge fields (prod residual) |

---

## 5. What “done” means (bars)

| Bar | Meaning |
|-----|---------|
| **D-structure green (this wave)** | Pure egress seams + Terp burn path + harness after settle + Zcash lab pay **gated by burn evidence** + dest seal equality |
| **Lab open** | Balance/txid at sealed dest after D pipeline (local/regtest) |
| **Production D** | `mock_verify=false`, LC membership, inventory/issuance conservation — **not** this wave’s exit |

---

## 6. Freeze authority

Do **not** re-litigate B vs C vs D for product corridor without a new ACCEPTED decision doc. Implementers implement **D**.
