# STATUS-IMPL-CW-EGRESS

| Field | Value |
|-------|--------|
| **Track** | CW-EGRESS (Option D) |
| **Date** | 2026-07-22 |
| **Result** | **Green** — `BridgeEgressBurn` on **cw-headstash** + multitest |
| **Choice** | Prefer **cw-headstash** (bridge router per CLARITY); not cw-private-dex post-settle |

## Landed

| Item | Status |
|------|--------|
| `ExecuteMsg::BridgeEgressBurn { statement, proof }` | done |
| Spent egress ν map `EGRESS_SPENT` key `egress:nf-v0:{hex}` | done |
| Burned-cm stub map `EGRESS_BURNED_CM` | done |
| Dest equality: `owner_binding == dest_commitment` fail-closed | done |
| Nullifier re-derive: `SHA256(egress-nf-v0 ‖ cm ‖ rcm)` | done |
| Dual-path mock_verify (mirror private-dex + bridge mint) | done |
| `encode_egress_instances` domain-separated (`egress-burn-instance-v0`) | done |
| Feature `zk-api` → `cosmwasm-std/zk`; fail-closed without mock | done |
| `QueryMsg::IsEgressSpent` | done |
| `BridgeCfg.egress_zkid: Option<u64>` (serde default) | done |
| Multitest: success / double-burn / dest mismatch / empty proof | **green** |
| Unit tests (11 egress) | **green** |
| Bridge mint e2e still green (6) | **green** |

## Dual-path proof

| Path | Gate | Behavior |
|------|------|----------|
| mock | `BridgeCfg.mock_verify \|\| cfg!(test)` | non-empty proof after structural gates → `proof_mode=mock_verify_lab` |
| host | feature `zk-api` + `!mock_verify` + `egress_zkid` | `api.proof_instance_verify(zkid, proof, instances)` → `zk_api` |
| fail-closed | otherwise | reject (`ZkApiUnavailable` / `ZkidMissing` / empty proof) |

## Paths

| Path | Role |
|------|------|
| `/Users/returniflost/abstract/terp-core/crates/headstash/contracts/cw-headstash/src/egress.rs` | Option D burn surface |
| `…/cw-headstash/src/msg.rs` | `BridgeEgressBurn`, `IsEgressSpent` |
| `…/cw-headstash/src/lib.rs` | wire execute/query + `pub mod egress` |
| `…/cw-headstash/src/bridge.rs` | `BridgeCfg.egress_zkid`, `pub(crate) require_hash32` |
| `…/cw-headstash/Cargo.toml` | `zk-api = ["cosmwasm-std/zk"]` |
| `…/cw-headstash/tests/test_egress_burn.rs` | multitest e2e |
| Decision SSOT | `docs/plans/spectrum/DESIGN-DECISIONS-ZEC-EGRESS-OPTION-D-ACCEPTED-2026-07-22.md` |
| Pure seams | `docs/plans/spectrum/fixtures/private_dex_seams/src/egress.rs` |

### Public API (cw-headstash egress)

- `EGRESS_NF_LABEL`, `EGRESS_INSTANCE_LABEL`
- `DestKind`, `EgressBurnStatement`, `EgressBurnEvidenceV0`
- `egress_nullifier`, `egress_spent_storage_key`, `encode_egress_instances`
- `validate_egress_burn_statement`, `verify_egress_proof`
- `execute_bridge_egress_burn`, `query_is_egress_spent`
- `happy_egress_statement`, `mock_egress_proof_bytes` (fixtures)

## Tests

```bash
cd crates/headstash
cargo test -p cw-headstash --lib egress
cargo test -p cw-headstash --test test_egress_burn
cargo test -p cw-headstash --test test_bridge_e2e
```

**Result (2026-07-22):**

| Suite | Result |
|-------|--------|
| `--lib egress` | **11 passed** |
| `--test test_egress_burn` | **6 passed** |
| `--test test_bridge_e2e` | **6 passed** (no regression) |

| Multitest | Covers |
|-----------|--------|
| `e2e_egress_burn_happy_path_is_spent` | burn success + `IsEgressSpent` + attrs |
| `e2e_egress_double_burn_same_nu_reject` | double egress ν |
| `e2e_egress_dest_mismatch_reject` | owner ≠ dest seal |
| `e2e_egress_empty_proof_under_mock_reject` | empty proof under mock_verify |
| `e2e_egress_transparent_dest_kind_ok` | Transparent dest kind metadata |
| `e2e_egress_nullifier_domain_is_egress_nf_v0` | domain formula fixture |

## Residual

- Zakura/lab pay gated on burn evidence (ZAKURA-PAY)
- Harness settle → burn → pay join (HARNESS-D)
- Production: `mock_verify=false`, real LC membership, Halo2 egress circuit, inventory conservation
- `cfg!(test)` still allows mock path even if `mock_verify=false` (same as private-dex / bridge mint)
- Optional: external sealed-dest query param beyond statement `owner_binding`

## Non-claims

- No Halo2 prove/verify on stock wasmd without `zk-api` feature
- No Zcash-side mint/pay in this track
- No pool-spend ν domain reuse (egress-nf-v0 only)
