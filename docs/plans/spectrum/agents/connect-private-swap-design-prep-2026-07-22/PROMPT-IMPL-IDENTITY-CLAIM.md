# PROMPT — IMPLEMENT G1 IDENTITY-CLAIM

Workspace: `/Users/returniflost/abstract/terp-core`

## Read first (mandatory)

1. `docs/plans/spectrum/agents/connect-private-swap-design-prep-2026-07-22/IMPL-ORCHESTRATION.md`
2. `HANDOFF.md` § G1
3. `DESIGN-IDENTITY-CLAIM.md` (full)

## Mission

**Implement** continuous deposit → `BridgeMintClaimPublic` end-to-end enough for harness to mint without silent happy fixture as the only path.

### Required code

1. Pure `deposit_nullifier_v0` + `claim_from_deposit_watch` per HANDOFF (preferred home: `crates/headstash/test-press/src/harness/claim_from_deposit.rs` and re-export).
2. Observation `vout` support if missing (`DepositObservation` / reporter / serde default policy per design).
3. Unit tests: happy map, fail-closed missing txid/amount/dest/vout, intent mismatch.
4. Optional but preferred: `GET /corridor/claim-inputs/:intent_id` hint-only on hash-market (if cheap).
5. Wire `corridor_ict_funded` or helper to **prefer** claim_from_deposit when obs env present; happy fixture only if `CORRIDOR_ALLOW_HAPPY_FIXTURE=1`.

### Acceptance

- `cargo test -p zk-test-press --lib claim_from_deposit` (or equivalent) green
- Document commands in STATUS

### Out of scope

Swap settle (G3), pure swap spend math (G2), Zakura golden generation (G4), live ZEC, SP1.

## Write

`STATUS-IMPL-IDENTITY-CLAIM.md` with: what landed, paths, test evidence, residual.

Update HANDOFF G1 status → implemented when green.
