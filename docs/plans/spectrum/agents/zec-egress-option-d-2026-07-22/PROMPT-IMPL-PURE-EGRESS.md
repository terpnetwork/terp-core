# PROMPT — IMPL PURE-EGRESS

Read: ORCHESTRATION.md, DESIGN-ZEC-EGRESS-D.md, HANDOFF.md, PROMPT-COMMON.md  
Also: `fixtures/private_dex_seams` for domain patterns.

**Implement** pure Option D seams (prefer new module in `docs/plans/spectrum/fixtures/private_dex_seams` or `compose_seams` or `test-press/harness/egress_d.rs`):

1. `EGRESS_NF_LABEL`, `egress_nullifier(cm, rcm)`
2. `EgressBurnPublic`, `DestKind`, `validate_egress_burn`, fail-closed dest mismatch
3. `apply_egress_burn` on a stub ν set
4. Builder from settle-like openings: cm, rcm, value, dest seal
5. Tests green

Write `STATUS-IMPL-PURE-EGRESS.md`. Update HANDOFF track status.
