# PROMPT — IMPL P1 LAB ZEC pay + one-button

Workspace: `/Users/returniflost/abstract/terp-core`

Read:
- `ORCHESTRATION.md`
- `lab_pay_zec.rs`, `zakura_local.rs`, ict-rs `chain/zakura.rs`, Option D STATUS

## Mission (P1)

1. When Zakura RPC + wallet methods available: real send → receipt `mode=lab_inventory_pay` + real `zec_txid` (not only `*_simulated`).
2. Open/confirm helper: validateaddress / getbalance-style check at sealed dest when possible; skip-clean when not.
3. **One-button** `just demo-corridor-full-local` (or headstash justfile): prepare wasm → zakura up (best effort) → `demo-corridor-ict-egress-d` → print receipt paths + fail if dest mismatch / missing burn.

Burn evidence still mandatory (Option D). No product host-pay without burn.

Write `STATUS-IMPL-P1-LAB-ZEC.md`.

Prior track context: ZAKURA-PAY + DEST-SEAL + Option D.
