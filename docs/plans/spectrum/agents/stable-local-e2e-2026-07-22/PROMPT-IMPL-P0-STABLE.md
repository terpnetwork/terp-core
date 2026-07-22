# PROMPT — IMPL P0 STABLE continuous multi-net

Workspace: `/Users/returniflost/abstract/terp-core`

Read:
- `ORCHESTRATION.md` (this folder)
- Option D HANDOFF + G1–G4 HANDOFF
- `corridor-ict-funded.sh`, `corridor_ict_funded.rs`, claim_from_deposit, egress_d, mint_evidence, settle

## Mission

Make the path **stable, continuous, fully local multi-net** (P0 only):

1. **Full path** `just demo-corridor-ict-egress-d` works (regtest observe, not only mint-only residual). Fix fail-closed bugs.
2. **Single dest seal** end-to-end: watch → claim → mint openings → settle → burn → zec receipt same 32B hex. Kill `demo_zec_mint_seal_*` inventing different seals when G4 golden/env set.
3. **Deposit-backed mint default** when obs/claim-inputs available; happy fixture only if `CORRIDOR_ALLOW_HAPPY_FIXTURE=1`.
4. **Evidence glue**: one continuous handoff mint → settle spend openings (align MintEvidence / MintSpendEvidence).
5. **Wasm gate**: prepare asserts BridgeEgress + SettleSwap; fail if missing before Daemon.
6. **Zakura preflight**: start or reuse via shell and/or `ict-rs` feature `zakura` when Docker+bin available; label if soft-skip.

Write `STATUS-IMPL-P0-STABLE.md` with commands run and residuals.

Prior track context: HARNESS-SETTLE + IDENTITY + DEST-SEAL + HARNESS-D.
