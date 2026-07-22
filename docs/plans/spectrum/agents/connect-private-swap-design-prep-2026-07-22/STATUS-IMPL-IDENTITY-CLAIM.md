# STATUS — IMPL-IDENTITY-CLAIM (G1)

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Track** | G1 continuous deposit → `BridgeMintClaimPublic` |
| **Status** | **Implemented** (pure builder + hub + harness prefer-deposit) |
| **mock_verify** | Lab default; **labeled** in logs / policy (`lab_mock_membership`) |

## What landed

### Pure builder (SSOT)

| Item | Path |
|------|------|
| `TERP_BTC_DEPOSIT_NU_V0` / `deposit_nullifier_v0` | `crates/headstash/test-press/src/harness/claim_from_deposit.rs` |
| `claim_from_deposit_watch` | same |
| `CorridorLabMintPolicy::corridor_lab_default` | same (happy hinge roots; ν/value/dest from deposit) |
| `ClaimFromDepositError` fail-closed set | same |
| `try_claim_from_env` / `corridor_allow_happy_fixture` | same |
| Re-exports | `harness/mod.rs` |

**Nullifier (provisional, not Tacit burn ν):**

```text
SHA256(b"terp-btc-deposit-nu-v0" ‖ txid32 ‖ vout_be_u32 ‖ intent_id_utf8)
```

Amount is **not** in ν (binds via `value_u64` + `claim_id`). Domain C `domain_bind` is **not** Domain B `domain_binding` (D2).

### L1 world

| Item | Path |
|------|------|
| `BridgeL1World::from_deposit_claim` | `test-press/src/harness/bridge_l1.rs` |
| `corridor_ict_funded` prefer deposit env | `test-press/src/bin/corridor_ict_funded.rs` → `resolve_bridge_world` |

Fail-closed: incomplete deposit fields when `CORRIDOR_INTENT_ID` set without full env → exit ≠ 0 unless `CORRIDOR_ALLOW_HAPPY_FIXTURE=1`. Optional `CORRIDOR_REQUIRE_DEPOSIT_CLAIM=1` refuses silent happy.

### Hash-market observe plane

| Item | Path |
|------|------|
| `DepositObservation.vout: Option<u32>` | `tools/hash-market/src/corridor_deposits.rs` |
| Reporter posts `vout` from `AddressFunding` | `btc_index/reporter.rs` |
| `GET /corridor/claim-inputs/:intent_id` | `server.rs` + `DepositNotifyHub::claim_inputs` |
| `nullifier_preview_hex` + `hint_only: true` | same (preview domain `terp-btc-deposit-nu-v0`) |

## Test evidence

```bash
# pure G1 (from crates/headstash workspace)
cd crates/headstash
cargo test -p zk-test-press --lib claim_from_deposit -- --nocapture
# → 16 passed (T1–T10 + prefix/placeholder)

cargo test -p zk-test-press --lib bridge_l1
# → 2 passed

# hub + claim-inputs
cd crates/terp-rs/tools/hash-market
cargo test --lib corridor_deposits --features server
# → 12 passed (incl. claim_inputs_fields_ready_with_vout, incomplete_without_vout)
```

## Env hooks (G3 consume)

| Env | Role |
|-----|------|
| `CORRIDOR_INTENT_ID` | Intent identity |
| `CORRIDOR_DEPOSIT_TXID` | 64-hex txid |
| `CORRIDOR_DEPOSIT_VOUT` | u32 outpoint index |
| `CORRIDOR_DEPOSIT_AMOUNT_SATS` | amount → `value_u64` |
| `CORRIDOR_DEST_OWNER_BINDING` | G4 64-hex dest seal |
| `CORRIDOR_DEPOSIT_ADDR` | optional addr equality |
| `CORRIDOR_ALLOW_HAPPY_FIXTURE` | residual mint-only hinge |
| `CORRIDOR_REQUIRE_DEPOSIT_CLAIM` | hard fail without deposit env |
| `CORRIDOR_MOCK_VERIFY` | existing lab flag (labeled) |

## Residual (not this track)

- Funded e2e shell curl claim-inputs → mint with **deposit ν** on regtest (G3 joint T12)
- Swap spend openings (G2) / CW settle (G3)
- Production burn membership / `mock_verify=false` (D7)
- True Tacit BTC burn nullifier (replace provisional domain)
- Live ZEC egress
- Amending D1–D7 freezes

## Lab honesty labels

- `lab_mock_membership=true` → claim `in_burn_set`/`in_pool_root` self-asserted — **not** production IMT/LC
- `mock_verify=true` default on ict — **labeled** in binary logs
- Provisional ν domain string frozen: `terp-btc-deposit-nu-v0`
