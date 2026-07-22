# STATUS-IMPL-ZAKURA-PAY

| Field | Value |
|-------|--------|
| **Track** | ZAKURA-PAY (Option D lab Zcash leg) |
| **Date** | 2026-07-22 |
| **Result** | **Green** (offline mock + refuse gates; live RPC skip-clean; HARNESS `egress_d` wired) |
| **Locked** | Pay ZEC **only after** Terp burn evidence — **not** Option B host-pay product |

## Landed

- `lab_pay_zec_after_burn(evidence, sealed) → Result<ZecEgressReceiptV0>`
- Fail-closed: missing evidence fields, dest seal mismatch, value 0, placeholder dest
- Offline/RPC-down: synthetic `zec_txid` labeled `lab_inventory_pay_simulated:…`, mode `lab_inventory_pay_simulated`
- Live RPC: attempt transparent `sendtoaddress` (then `z_sendmany` for shielded); degrade labeled simulated if wallet RPC unavailable
- Types SSOT from PURE-EGRESS (`private_dex_seams`); receipt built via `lab_receipt_after_burn`
- HARNESS-D `egress_d::lab_pay_zec_after_burn` **delegates** to this host attach

## Paths

| Path | Role |
|------|------|
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/lab_pay_zec.rs` | Host lab pay + gates + tests |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/mod.rs` | Re-exports |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/egress_d.rs` | Calls host pay (no duplicate logic) |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/zakura_local.rs` | `SealedDestV0`, golden dest, RPC helpers |
| `/Users/returniflost/abstract/terp-core/docs/plans/spectrum/fixtures/private_dex_seams/src/egress.rs` | Pure types + `lab_receipt_after_burn` |
| `/Users/returniflost/abstract/terp-core/docs/plans/spectrum/e2e/zakura/golden-dest-binding.json` | Primary seal for mock accept |

## Tests

```bash
cargo test -p zk-test-press --lib lab_pay_zec --features 'interface,l0-seams' -- --nocapture
# → 6 passed; 0 failed

cargo test -p zk-test-press --lib egress_d --features 'interface,l0-seams' -- --nocapture
# → 6 passed; 0 failed (HARNESS join uses host pay)
```

| Case | Result |
|------|--------|
| `refuse_value_zero` | PASS |
| `refuse_dest_mismatch` | PASS |
| `refuse_missing_proof_mode_and_zero_nullifier` | PASS |
| `refuse_without_evidence_helper_gates` | PASS |
| `accept_mock_path_matching_seal` | PASS (golden `8b5cac11…` / `tmJym…`) |
| `lab_pay_live_rpc_skip_clean_when_available` | PASS (skipped clean — RPC down) |

## Residual

- Real inventory broadcast needs zcashd-compat wallet RPCs on funded Zakura stack
- Prod `lc_mint` out of scope this wave
- Full corridor binary/shell join remains HARNESS-D

## Honesty

**Option D lab inventory settle only.** Burn evidence mandatory. Simulated mode is explicitly labeled — never product host-pay without Terp burn.
