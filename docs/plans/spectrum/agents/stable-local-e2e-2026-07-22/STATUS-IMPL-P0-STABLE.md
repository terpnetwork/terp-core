# STATUS — IMPL-P0-STABLE (continuous multi-net)

| Field | Value |
|-------|--------|
| **Track** | IMPL-P0-STABLE |
| **Date** | 2026-07-22 |
| **Agent** | IMPL-P0-STABLE |
| **Result** | **Landed + Docker green once** (`just demo-corridor-ict-egress-d` + mint-only residual) |
| **Profile** | `ict_local_funded` · `mock_verify` lab · **no mainnet** |

## Mission (P0 checklist)

| # | Item | Status |
|---|------|--------|
| 1 | Full path `just demo-corridor-ict-egress-d` (regtest observe, not mint-only only) | **Green once** — regtest observe → claim-inputs → deposit mint → settle → CW burn → lab pay |
| 2 | Single dest seal e2e (kill `demo_zec_mint_seal_*` invent when G4/env set) | **Green** — `8b5cac11…` / `tmJym…` watch→mint→burn→zec |
| 3 | Deposit-backed mint default; happy only `CORRIDOR_ALLOW_HAPPY_FIXTURE=1` | **Green** — `mint_source=deposit_claim` on full + synthetic mint-only |
| 4 | Evidence glue mint → settle openings | **Green** — continuous assert + unit |
| 5 | Wasm gate BridgeEgress + SettleSwap before Daemon | **Green** — prepare gates + binary |
| 6 | Zakura preflight start/reuse; soft-skip labeled | **Green** — soft-skip WARN when no `ZAKURAD_BIN` |

## Changes (paths)

| Path | Change |
|------|--------|
| `crates/headstash/test-press/src/bin/corridor_ict_funded.rs` | `resolve_bridge_world` deposit default; dest pin on happy; wasm surface gates; mint↔settle dest continuity |
| `crates/headstash/test-press/src/harness/egress_d.rs` | `sealed_dest_for_option_d` refuse invent when G4 diverges; G4 match returns golden display |
| `crates/headstash/test-press/src/harness/swap_statement_cw.rs` | `assert_mint_handoff_continuous`; builder always glue-checks |
| `crates/headstash/test-press/src/harness/mod.rs` | re-export continuous handoff helpers |
| `docs/plans/spectrum/e2e/corridor-ict-funded.sh` | Zakura soft-skip; claim-inputs → `CORRIDOR_DEPOSIT_*`; HM/reporter rebuild if stale; vout recover; mint-only synthetic deposit; dual-receipt dest assert |
| `docs/plans/spectrum/e2e/prepare-corridor-ict-wasm.sh` | `has_egress_surface`; fail-closed BridgeEgress / SettleSwap gates |
| `docs/plans/spectrum/e2e/preflight-corridor-local.sh` | BridgeEgress / SettleSwap honesty for Option D |
| `crates/headstash/justfile` | mint-only residuals labeled (`ALLOW_MINT_ONLY` + synthetic deposit path) |

## Env (P0)

| Var | Role |
|-----|------|
| `CORRIDOR_INTENT_ID` + `CORRIDOR_DEPOSIT_TXID` + `CORRIDOR_DEPOSIT_VOUT` + `CORRIDOR_DEPOSIT_AMOUNT_SATS` + `CORRIDOR_DEST_OWNER_BINDING` | Deposit-backed mint |
| `CORRIDOR_REQUIRE_DEPOSIT_CLAIM=1` | Shell observe path; binary hard-fail without claim |
| `CORRIDOR_ALLOW_HAPPY_FIXTURE=1` | Mint-only residual hinge only |
| `CORRIDOR_CHAIN_SETTLE=1` / `CORRIDOR_ZEC_EGRESS_D=1` | Settle + Option D |
| `ZAKURAD_BIN` | Optional Zakura start; soft-skip if absent |
| `CORRIDOR_REQUIRE_ZAKURA_RPC=1` | Hard-fail if Zakura down |
| `FORCE_WASM_REBUILD=1` | If BridgeEgress / SettleSwap surfaces missing |

## Flow (intended green)

```text
preflight → Zakura soft-skip/reuse
  → prepare wasm (SettleSwap + BridgeEgress gates when D)
  → regtest fund + reporter → deposit_observed
  → GET claim-inputs → CORRIDOR_DEPOSIT_* + REQUIRE_DEPOSIT_CLAIM
  → corridor_ict_funded:
       mint_source=deposit_claim (ν terp-btc-deposit-nu-v0)
       MintEvidenceV0 → SwapSpendHandoff (assert continuous)
       SettleSwap → Option D burn → lab_pay
  → receipts: settle + burn + zec; dest seal equal throughout
```

Honesty labels unchanged: `mock_verify_lab`, `lab_mock_membership`, provisional deposit ν, ZEC pay often `lab_inventory_pay_simulated`.

## Commands run (agent)

```bash
cd crates/headstash

cargo test -p zk-test-press --lib --features 'interface,l0-seams' -- \
  claim_from_deposit swap_statement_cw egress_d mint_evidence
# → 28 passed (prior filter)

cargo test -p zk-test-press --lib --features 'interface,l0-seams' -- \
  sealed_dest mint_handoff_continuous
# → 3 passed
#   sealed_dest_for_option_d_matches_g4_golden
#   sealed_dest_refuse_invent_when_g4_diverges
#   mint_handoff_continuous_dest_and_cm

cargo check -p zk-test-press --bin corridor_ict_funded --features 'ict-daemon,l0-seams'
# → ok

just demo-corridor-ict-egress-d-mint-only
# → OK ict_local_funded; mint_source=deposit_claim (synthetic);
#   burn_surface=cw_bridge_egress_burn; dest=8b5cac11… / tmJym…

just demo-corridor-ict-egress-d
# → OK ict_local_funded; regtest observe; claim-inputs vout=1 amount=20000;
#   mint_source=deposit_claim; dest seal continuous; Option D dual receipts
```

| ID | Result |
|----|--------|
| Deposit claim pure (G1) | **green** (existing 16+) |
| Mint↔settle continuous glue | **green** |
| G4 seal match / refuse invent | **green** |
| Option D unit suite | **green** |
| Binary check | **green** |
| Mint-only Docker egress-d | **green** |
| Full Docker `just demo-corridor-ict-egress-d` | **green once** (this session) |
| 2× re-run | **residual** (not re-run second pass) |

## Docker path (human)

```sh
cd crates/headstash
just prepare-corridor-ict-wasm-settle
# or FORCE_WASM_REBUILD=1 if BridgeEgress missing
just preflight-corridor-local
just demo-corridor-ict-egress-d
# expect mint_source=deposit_claim; receipts under /tmp/corridor-*
# re-run once more for 2× bar

# mint-only residual (labeled synthetic deposit, not regtest observe):
just demo-corridor-ict-egress-d-mint-only
```

Inspect:

```sh
cat /tmp/corridor-mint-evidence.json
cat /tmp/corridor-settle-receipt.json
cat /tmp/corridor-egress-burn-evidence.json
cat /tmp/corridor-zec-egress-receipt.json
# dest_owner_binding_hex equal; dest_display must not be demo_zec_mint_seal_* when G4 set
```

## Residuals

1. **2× re-run** not measured (epic DoG “every time” still needs second host pass).
2. **Live Zakura wallet pay** (`lab_inventory_pay`) — host/`ZAKURAD_BIN` residual (P1); this session soft-skip → `lab_inventory_pay_simulated`.
3. **Stale hash-market/reporter** — script now rebuilds when `claim-inputs` missing / reporter older than server; operators with sticky old process must free port 19090.
4. **vout recover** from bitcoind if reporter omits vout (labeled); prefer rebuilt reporter posting `vout`.
5. **Mainnet / `mock_verify=false` / product LC mint** — out of scope.
6. P1 one-button / real open assert — parallel track.

## Non-claims

- No mainnet money.
- Simulated ZEC receipt ≠ product host-pay.
- Unit green ≠ “stable every time” until host Docker 2× logs pasted.
