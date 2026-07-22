# STATUS-IMPL-HARNESS-D

| Field | Value |
|-------|--------|
| **Track** | HARNESS-D (Option D continuous corridor) |
| **Date** | 2026-07-22 |
| **Result** | **Landed** — settle → burn → lab pay → dual receipts under `CORRIDOR_ZEC_EGRESS_D=1` |
| **Agent** | IMPL HARNESS-D |

## Landed

| Item | Status |
|------|--------|
| Env `CORRIDOR_ZEC_EGRESS_D=1` (requires `CORRIDOR_CHAIN_SETTLE=1`) | done |
| After SettleSwap: openings → egress burn → lab pay → dual JSON receipts | done |
| CW `BridgeEgressBurn` attempt on deployed headstash | done (fallback pure) |
| Pure labeled residual `pure_record_lab` when CW wasm/msg fails | done |
| Fail-closed dest ≠ G4 / settle `note_out.owner_binding` | done |
| Fail-closed lab pay without burn evidence | done (via ZAKURA-PAY) |
| Artifacts `EgressBurnEvidenceV0` + `ZecEgressReceiptV0` | done |
| just `demo-corridor-ict-egress-d` (+ mint-only residual) | done |
| Shell assert dual receipts in `corridor-ict-funded.sh` | done |
| Unit tests `egress_d` | **green** |

## Paths

| Path | Role |
|------|------|
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/egress_d.rs` | Stage join: openings, pure burn, CW statement map, dual receipt JSON |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/lab_pay_zec.rs` | ZAKURA-PAY: `lab_pay_zec_after_burn` |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/bin/corridor_ict_funded.rs` | Stage `[6/8]` when `CORRIDOR_ZEC_EGRESS_D=1` |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/suites/private_bridge.rs` | `execute_bridge_egress_burn` / `query_is_egress_spent` |
| `/Users/returniflost/abstract/terp-core/crates/headstash/justfile` | `demo-corridor-ict-egress-d`, `demo-corridor-ict-egress-d-mint-only` |
| `/Users/returniflost/abstract/terp-core/docs/plans/spectrum/e2e/corridor-ict-funded.sh` | Export D env; assert dual receipts |
| Pure SSOT | `docs/plans/spectrum/fixtures/private_dex_seams/src/egress.rs` |
| CW SSOT | `crates/headstash/contracts/cw-headstash/src/egress.rs` |

### Env

| Var | Default | Meaning |
|-----|---------|---------|
| `CORRIDOR_ZEC_EGRESS_D` | off | Enable Option D after settle |
| `CORRIDOR_CHAIN_SETTLE` | off | Required by D (auto-forced in shell when D on) |
| `CORRIDOR_EGRESS_BURN_EVIDENCE_PATH` | `/tmp/corridor-egress-burn-evidence.json` | |
| `CORRIDOR_ZEC_EGRESS_RECEIPT_PATH` | `/tmp/corridor-zec-egress-receipt.json` | |

### Flow

```text
SettleSwap complete (SettleReceiptV0 + handoff note_out)
  → sealed_dest_for_option_d (G4 golden if match; else mint/settle continuity)
  → try CW BridgeEgressBurn (+ IsEgressSpent)
      else pure apply_egress_burn labeled pure_record_lab
  → lab_pay_zec_after_burn (fail-closed dest / evidence)
  → write EgressBurnEvidenceV0 + ZecEgressReceiptV0
```

Honesty labels:

- `burn_surface`: `cw_bridge_egress_burn` | `pure_record_lab`
- `proof_mode`: `mock_verify_lab`
- `mode`: `lab_inventory_pay_simulated` (or `lab_inventory_pay` if wallet RPC send lands)
- `egress_nf_label`: `egress-nf-v0`

## Tests

```bash
cd crates/headstash
cargo test -p zk-test-press --lib --features 'interface,l0-seams' -- egress_d lab_pay_zec
# → 12 passed (6 egress_d + 6 lab_pay_zec)

cargo check -p zk-test-press --bin corridor_ict_funded --features 'ict-daemon,l0-seams'
# → ok
```

| ID | Result |
|----|--------|
| `option_d_after_settle_happy_pure_labeled` | **green** |
| `dest_mismatch_fail_closed` | **green** |
| `lab_pay_refuses_empty_evidence` | **green** |
| `lab_pay_dest_mismatch_refuse` | **green** |
| ZAKURA-PAY refuse / mock accept | **green** (sibling) |
| Full Docker ict egress-d | **not run by agent** (path below) |

## Docker path (human)

Requires: Docker, `terpnetwork/terp-core:local-zk` (or env image/tag), binaryen ≥120 preferred for wasm-opt.

```sh
cd crates/headstash
just prepare-corridor-ict-wasm-settle
# mint + settle + Option D only (no regtest):
just demo-corridor-ict-egress-d-mint-only
# full observe + mint + settle + Option D:
just demo-corridor-ict-egress-d
# inspect:
cat /tmp/corridor-settle-receipt.json
cat /tmp/corridor-egress-burn-evidence.json
cat /tmp/corridor-zec-egress-receipt.json
# expect:
#   settle status=complete proof_mode=mock_verify_lab
#   burn status=complete egress_nf_label=egress-nf-v0 burn_surface=cw_* or pure_record_lab
#   zec status=complete mode=lab_inventory_pay_simulated (or lab_inventory_pay)
#   zec.burn_nullifier_hex == burn.nullifier_hex
#   zec.dest_owner_binding_hex == burn.dest_commitment_hex
```

## Residual

- Funded wasm must include `BridgeEgressBurn` for on-chain surface (else pure_record_lab residual — still fail-closed on dest)
- Fixture mint dest may ≠ golden G4; `sealed_dest_for_option_d` pins settle continuity
- Real Zcash inventory wallet fund (live `lab_inventory_pay`) when Zakura wallet RPCs available
- Halo2 egress proof / non-mock_verify product
- Deposit-prefer continuous dest from regtest watch into mint openings (G1 residual)
