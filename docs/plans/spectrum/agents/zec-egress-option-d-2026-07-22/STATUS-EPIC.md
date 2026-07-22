# STATUS-EPIC — Option D ZEC egress (private bridge)

| Field | Value |
|-------|--------|
| **Date** | 2026-07-22 |
| **Decision** | **LOCKED** — `DESIGN-DECISIONS-ZEC-EGRESS-OPTION-D-ACCEPTED-2026-07-22.md` |
| **Pipeline** | SettleSwap → BridgeEgressBurn (Terp) → lab_pay_zec_after_burn (Zcash) → dual receipts |

## Tracks

| Track | Status | Evidence |
|-------|--------|----------|
| PURE-EGRESS | **Implemented** | `private_dex_seams` egress module; 35 crate tests incl. 12 egress |
| CW-EGRESS | **Implemented** | `cw-headstash` `BridgeEgressBurn`; 11 lib + 6 multitest |
| ZAKURA-PAY | **Implemented** | `lab_pay_zec_after_burn`; 6 tests; burn mandatory |
| HARNESS-D | **Implemented** | `CORRIDOR_ZEC_EGRESS_D=1`; just `demo-corridor-ict-egress-d*` |

## Honest residual

| Item | Notes |
|------|-------|
| Docker full multi-net | Human: `just demo-corridor-ict-egress-d` |
| Live Zcash wallet send | Default simulated; real when Zakura wallet RPC up |
| LC / mock_verify=false | Phase G production |
| Stale headstash wasm | CW burn falls back to pure_record_lab (labeled) |

## Product freeze

Option B/C **rejected** as product. Dest may be **transparent or shielded**; seal fixed at intent.
