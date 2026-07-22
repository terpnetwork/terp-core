# PROMPT — IMPL ZAKURA-PAY (lab D leg)

Read: ORCHESTRATION.md, DESIGN-ZEC-EGRESS-D.md, HANDOFF.md,  
`zakura_local.rs`, golden dest, ACCEPTED decision (lab inventory pay **after burn only**).

**Implement** lab Zcash leg for Option D:

1. `lab_pay_zec_after_burn(evidence: &EgressBurnEvidenceV0, sealed: &SealedDestV0) → Result<ZecEgressReceiptV0>`
2. **Refuse** if evidence missing / dest mismatch / value 0
3. Offline/mock mode: record synthetic txid labeled `lab_inventory_pay_simulated` when RPC down
4. When Zakura RPC up: attempt real send/fund to sealed dest (t-addr path first; UA if easy) — skip-clean if unavailable
5. Tests: reject without evidence; accept mock path with matching seal

Write `STATUS-IMPL-ZAKURA-PAY.md`. Update HANDOFF.

This is **not** Option B product: burn evidence is mandatory.
