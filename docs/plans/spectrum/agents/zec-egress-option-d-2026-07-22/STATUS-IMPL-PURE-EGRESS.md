# STATUS-IMPL-PURE-EGRESS

## Landed

Option D pure egress seams in `private_dex_seams`:

| Item | Status |
|------|--------|
| `EGRESS_NF_LABEL` = `b"egress-nf-v0"` | done |
| `egress_nullifier(cm, rcm)` = `SHA256(egress-nf-v0 ‖ cm ‖ rcm)` | done |
| Domain sep vs `pool-nf-v0` and `terp-btc-deposit-nu-v0` | done (asserted) |
| `EgressBurnPublic`, `DestKind`, `EgressBurnWitness` | done |
| `EgressBurnEvidenceV0`, `ZecEgressReceiptV0` | done |
| `validate_egress_burn` fail-closed dest mismatch | done |
| `apply_egress_burn` on stub ν set (double-ν reject) | done |
| Builder `build_egress_burn_from_settle` / `SettleLikeOpening` | done |
| Lab receipt helper gated on burn evidence | done |
| Tests (12 egress + prior swap suite) | **green** |

## Paths

| Path | Role |
|------|------|
| `/Users/returniflost/abstract/terp-core/docs/plans/spectrum/fixtures/private_dex_seams/src/egress.rs` | Pure Option D types + validate/apply/builder |
| `/Users/returniflost/abstract/terp-core/docs/plans/spectrum/fixtures/private_dex_seams/src/lib.rs` | Re-exports egress API |
| Decision SSOT | `docs/plans/spectrum/DESIGN-DECISIONS-ZEC-EGRESS-OPTION-D-ACCEPTED-2026-07-22.md` |
| Design | `DESIGN-ZEC-EGRESS-D.md` (this agent folder) |

### Public API (re-exported)

- `EGRESS_NF_LABEL`, `DEPOSIT_NU_LABEL`
- `egress_nullifier`, `synthetic_deposit_nu`
- `DestKind`, `EgressBurnPublic`, `EgressBurnWitness`, `EgressBurnV0`
- `EgressBurnEvidenceV0`, `ZecEgressReceiptV0`, `EgressSeamState`, `SettleLikeOpening`
- `validate_egress_burn`, `apply_egress_burn`
- `build_egress_burn_from_settle`, `settle_opening_from_note_fields`
- `lab_receipt_after_burn`, `hex32`
- `EgressError`, `EgressResult`

## Tests

```bash
cd docs/plans/spectrum/fixtures/private_dex_seams && cargo test
```

**Result (2026-07-22):** `35 passed; 0 failed` (includes 12 `egress::tests::*`).

| Test | Covers |
|------|--------|
| `egress_nf_label_is_normative` | label SSOT |
| `egress_nullifier_domain_separated_from_pool_and_deposit` | ≠ pool / deposit ν |
| `build_and_validate_egress_burn_happy` | builder + validate |
| `dest_mismatch_fail_closed` | owner ≠ dest; redirect reject |
| `sealed_dest_external_mismatch_fail_closed` | G4 seal equality |
| `apply_egress_burn_records_nullifier_once` | apply + double egress |
| `value_zero_rejected` | value 0 |
| `bad_nullifier_rejected` | ν re-derive |
| `transparent_and_shielded_dest_kinds_ok` | both DestKind |
| `lab_receipt_requires_burn_evidence` | pay gated by evidence |
| `builder_from_settle_cm_rcm_value_dest` | settle-like openings |
| `hub_asset_still_builds_structurally` | pure asset id shape |

## Residual

- CW `BridgeEgressBurn` multitest (CW-EGRESS track)
- Zakura/lab pay RPC attach (ZAKURA-PAY)
- Harness settle → burn → pay join (HARNESS-D)
- Production: non-mock proof, real LC membership, inventory conservation
- No Halo2 egress circuit this wave (`mock_verify_lab` labeled)
