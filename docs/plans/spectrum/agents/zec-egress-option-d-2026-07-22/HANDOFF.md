# HANDOFF — Option D ZEC egress

**Decision:** `DESIGN-DECISIONS-ZEC-EGRESS-OPTION-D-ACCEPTED-2026-07-22.md` — **LOCKED**.

## Data flow

```text
G3 SettleReceiptV0 (cm_out, amount, dest seal)
  → EgressBurnPublic + proof
  → CW BridgeEgressBurn (Terp / cw-headstash) | pure_record_lab residual
  → EgressBurnEvidenceV0
  → lab_pay_zec_after_burn | prod LC mint
  → ZecEgressReceiptV0
```

## Cross-track

| From | To | Payload |
|------|-----|---------|
| G3 | PURE/CW | cm_out[0], delta_out, asset_out, dest binding |
| G4 | all | sealed 32B + dest_display + dest_kind |
| PURE | CW | validate + instance encoding sketch |
| CW | ZAKURA | burn evidence required (`burn_evidence` attr / `EgressBurnEvidenceV0`) |
| ZAKURA | HARNESS | zec_txid + amount |
| HARNESS | UI/docs | dual receipts labeled |

## CW surface (landed)

| Item | Value |
|------|--------|
| Contract | **cw-headstash** (not private-dex) |
| Msg | `ExecuteMsg::BridgeEgressBurn { statement, proof }` |
| Query | `QueryMsg::IsEgressSpent { nullifier }` |
| ν domain | `egress-nf-v0` → storage `egress:nf-v0:{hex}` |
| Dual-path | `mock_verify` / cfg(test) lab; `zk-api` + `BridgeCfg.egress_zkid` prod |
| Evidence attr | `burn_evidence` (base64 JSON `EgressBurnEvidenceV0`) |

## Status

| Track | Status |
|-------|--------|
| PURE-EGRESS | **implemented** — see `STATUS-IMPL-PURE-EGRESS.md` |
| CW-EGRESS | **implemented** — see `STATUS-IMPL-CW-EGRESS.md` (multitest green) |
| ZAKURA-PAY | **implemented** — see `STATUS-IMPL-ZAKURA-PAY.md` (lab pay gated on burn evidence; mock + refuse green) |
| HARNESS-D | **implemented** — see `STATUS-IMPL-HARNESS-D.md` (`CORRIDOR_ZEC_EGRESS_D=1`, dual receipts, just target) |

## ZAKURA-PAY surface (for HARNESS-D)

```text
lab_pay_zec_after_burn(&EgressBurnEvidenceV0, &SealedDestV0) → ZecEgressReceiptV0
```

| Item | Value |
|------|--------|
| Module | `zk-test-press::harness::lab_pay_zec` |
| Types SSOT | `private_dex_seams` (`EgressBurnEvidenceV0`, `ZecEgressReceiptV0`, `lab_receipt_after_burn`) |
| Seal | G4 `SealedDestV0` / golden miner `tmJym…` → `8b5cac11…` |
| Mock mode | `lab_inventory_pay_simulated` + txid prefix same label (RPC down / wallet RPC missing) |
| Live mode | `lab_inventory_pay` when `sendtoaddress` / `z_sendmany` returns txid |
| Fail-closed | value 0, dest_commitment ≠ seal, empty proof_mode / zero ν / zero cm |
| HARNESS bridge | `egress_d::lab_pay_zec_after_burn` delegates to host module |

## HARNESS-D surface

| Item | Value |
|------|--------|
| Env | `CORRIDOR_ZEC_EGRESS_D=1` (+ settle) |
| Module | `zk-test-press::harness::egress_d` |
| Binary stage | `corridor_ict_funded` `[6/8]` |
| just | `demo-corridor-ict-egress-d` / `demo-corridor-ict-egress-d-mint-only` |
| Burn | try CW on headstash → else `pure_record_lab` |
| Artifacts | `/tmp/corridor-egress-burn-evidence.json`, `/tmp/corridor-zec-egress-receipt.json` |
