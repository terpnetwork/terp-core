# PROMPT — IMPL HARNESS-D

Read: ORCHESTRATION.md, DESIGN-ZEC-EGRESS-D.md, HANDOFF.md,  
G3 settle (`corridor_ict_funded`, SettleReceiptV0), pure/CW/Zakura handoffs.

**Implement** continuous Option D after settle:

1. Env `CORRIDOR_ZEC_EGRESS_D=1` (or always-on stage after settle when settle on)
2. From settle receipt / openings: build egress burn → call CW (or pure record if CW wasm missing, labeled residual) → lab_pay_zec_after_burn
3. Write `EgressBurnEvidenceV0` + `ZecEgressReceiptV0` artifacts
4. Fail-closed if dest ≠ G4 seal
5. just target sketch: `demo-corridor-ict-egress-d`
6. Document Docker path

Write `STATUS-IMPL-HARNESS-D.md`. Update HANDOFF.
