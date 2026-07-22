# STATUS-IMPL-P1-LAB-ZEC

| Field | Value |
|-------|--------|
| **Track** | IMPL-P1-LAB-ZEC (stable-local-e2e) |
| **Date** | 2026-07-22 |
| **Agent** | IMPL-P1-LAB-ZEC |
| **Result** | **Landed** — real lab pay when wallet RPC present; open/confirm skip-clean; one-button `demo-corridor-full-local` |
| **Locked** | Option D burn evidence **mandatory**. No product host-pay without Terp burn. Simulated pay stays labeled. |

## Mission (from PROMPT)

1. When Zakura RPC + wallet methods available → real send → `mode=lab_inventory_pay` + real `zec_txid` (not only `*_simulated`)
2. Open/confirm helper: `validateaddress` / getbalance-style at sealed dest; skip-clean when not
3. One-button `just demo-corridor-full-local`: prepare wasm → Zakura up (best effort) → `demo-corridor-ict-egress-d` → print receipts; **fail** on dest mismatch / missing burn

## Landed

### 1. Real lab inventory pay (when wallet RPC)

| Item | Status |
|------|--------|
| `wallet_rpc_available` probe via `getbalance` | done |
| Live `sendtoaddress` / `z_sendmany` → `MODE_LAB_INVENTORY_PAY` | done (pre-existing path hardened) |
| Real txid classifier (`is_real_zec_txid`) — refuse simulated prefix as live | done |
| Soft `validateaddress` before send when RPC up | done |
| Degrade labeled `lab_inventory_pay_simulated` when wallet missing / send fails | done |
| Force simulated: `CORRIDOR_LAB_ZEC_FORCE_SIMULATED=1` | done |
| Burn gates still fail-closed (evidence, dest seal, value>0) | done |

**Honesty:** Zakura core is **not** a zcashd wallet. Without zcashd-compat residual (`getbalance` / `sendtoaddress`), mode stays `lab_inventory_pay_simulated`. Live `lab_inventory_pay` only when send RPC returns a non-synthetic txid.

### 2. Open/confirm at sealed dest

| Item | Status |
|------|--------|
| `confirm_open_at_sealed_dest` / `_with_cfg` | done |
| `validateaddress` when RPC up | done |
| `getbalance` / `getreceivedbyaddress` when wallet residual | done |
| Skip-clean labels: `skip_clean_no_rpc`, `rpc_validate_only`, `skip_clean_no_wallet_balance`, `rpc_open_confirm` | done |
| Wired after lab pay in `corridor_ict_funded` Option D stage | done |
| Attached on `run_option_d_after_settle` → `EgressDStageOutcome.open_confirm` | done |

Not a “ZEC received” product claim — balance/received may be empty until mine/index.

### 3. One-button full local

| Item | Status |
|------|--------|
| `docs/plans/spectrum/e2e/demo-corridor-full-local.sh` | done |
| `just demo-corridor-full-local` (headstash justfile) | done |
| Spectrum justfile forward | done |
| Prepare wasm (private-dex) → Zakura up best-effort → egress-d | done |
| Fail-closed: missing burn / zec / settle; dest_binding equality; ν continuity | done |
| Soft-skip only Zakura **start** (labeled `zakura_state=…`) | done |

## Paths

| Path | Role |
|------|------|
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/lab_pay_zec.rs` | Wallet probe, real/simulated pay, open/confirm |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/egress_d.rs` | Option D stage + `open_confirm` on outcome |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/harness/mod.rs` | Re-exports |
| `/Users/returniflost/abstract/terp-core/crates/headstash/test-press/src/bin/corridor_ict_funded.rs` | Live path logs wallet + open_confirm |
| `/Users/returniflost/abstract/terp-core/docs/plans/spectrum/e2e/demo-corridor-full-local.sh` | One-button shell |
| `/Users/returniflost/abstract/terp-core/crates/headstash/justfile` | `demo-corridor-full-local` |
| `/Users/returniflost/abstract/terp-core/docs/plans/spectrum/justfile` | Forward full-local + egress-d |

### Env

| Var | Default | Meaning |
|-----|---------|---------|
| `CORRIDOR_LAB_ZEC_FORCE_SIMULATED` | off | Force simulated even if wallet RPC up |
| `CORRIDOR_REQUIRE_ZAKURA_RPC` | off | Open/confirm hard-fail if RPC down |
| `CORRIDOR_ZEC_EGRESS_D` | required by full-local | Option D after settle |
| `ZAKURA_RPC` / `ZAKURAD_BIN` | 18232 / host bin | Zakura node |

## Tests (agent-run)

```bash
cd crates/headstash
cargo test -p zk-test-press --lib lab_pay_zec --features 'interface,l0-seams' -- --nocapture
# → 10 passed; 0 failed

cargo test -p zk-test-press --lib egress_d --features 'interface,l0-seams' -- --nocapture
# → 6 passed; 0 failed

cargo check -p zk-test-press --bin corridor_ict_funded --features 'ict-daemon,l0-seams'
# → ok
```

| Case | Result |
|------|--------|
| refuse value0 / dest mismatch / empty evidence | PASS |
| accept_mock_path_matching_seal (`*_simulated`) | PASS |
| lab_pay_live_rpc_skip_clean_when_available | PASS (skip-clean — RPC down this host) |
| open_confirm_skip_clean_when_rpc_down | PASS |
| open_confirm_live_skip_clean_when_available | PASS (skip — RPC down) |
| real_txid_classifier + wallet_probe_offline_false | PASS |
| option_d_after_settle_happy_pure_labeled (+ open_confirm) | PASS |
| Full Docker `just demo-corridor-full-local` | **not run by agent** (host Docker / image residual) |

## Operator path

```sh
cd crates/headstash
just prepare-corridor-ict-wasm-settle   # or rely on full-local
# optional: export ZAKURAD_BIN=… for live Zakura
just demo-corridor-full-local
# inspect:
cat /tmp/corridor-settle-receipt.json
cat /tmp/corridor-egress-burn-evidence.json
cat /tmp/corridor-zec-egress-receipt.json
# expect:
#   burn status=complete egress_nf_label=egress-nf-v0
#   zec mode=lab_inventory_pay_simulated | lab_inventory_pay
#   zec.dest_owner_binding_hex == burn.dest_commitment_hex
#   zec.burn_nullifier_hex == burn.nullifier_hex
```

## Residual

| Item | Notes |
|------|--------|
| Live `lab_inventory_pay` | Needs funded zcashd-compat wallet on Zakura stack (`sendtoaddress`) |
| Full multi-net Docker 2× re-run | Human/host; P0 observe/deposit continuity may still gate green path |
| Prod `lc_mint` | Out of scope |
| Open/confirm ≠ funds settled | Index/mine lag; validate-only is honest residual on Zakura core |

## Honesty

**Option D lab inventory settle only.** Burn evidence mandatory.  
`mode=lab_inventory_pay` only with real wallet send txid.  
`mode=lab_inventory_pay_simulated` is explicitly labeled — never product host-pay without Terp burn.
