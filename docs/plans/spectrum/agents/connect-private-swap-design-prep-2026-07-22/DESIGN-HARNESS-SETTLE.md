# DESIGN-HARNESS-SETTLE

## 0. Track charter

| Field | Value |
|-------|--------|
| **Goal (one sentence)** | Wire funded ict harness so post-mint path deploys/calls `cw-private-dex` `SettleSwap` with a G2-derived `SwapStatementPublic` + lab proof, fail-closed on missing mint evidence, and emits settle receipt fields. |
| **Closes gap ID** | **G3** (H-G2 / S-G1 harness half; Phase E) |
| **Depends on handoffs** | **G2** `SwapActionV0` / openings → public statement fields; **G1** mint evidence continuous with deposit (preferred; fixture mint OK for settle lab if labeled); pool asset ids + oracle mid from corridor policy |
| **Produces handoffs** | Daemon call sequence; env/just sketch; `SettleReceiptV0` artifact shape; fail-closed policy; soft-skip ban for mint/settle |

---

## 1. Current code reality (cite paths)

| Surface | Status | Path / command |
|---------|--------|----------------|
| Funded shell (observe + mint + pure film) | **Green shape** | `docs/plans/spectrum/e2e/corridor-ict-funded.sh` → `just demo-corridor-ict` |
| Chain mint binary | **Green (fixture claim)** | `crates/headstash/test-press/src/bin/corridor_ict_funded.rs` |
| Headstash suite only | **No private-dex** | `PrivateBridgeSuite` uploads **cw-headstash only** (`upload_and_instantiate_mint`) — `suites/private_bridge.rs` |
| Pure W0–W7 after mint | **Film only** | `harness::run_cashapp_zec_corridor_w0_w7`; independent of mint note |
| `apply_swap_fixture` stub | **Explicit TBD** | `private_bridge.rs`: `"CW DEX TBD"` |
| `cw-private-dex` contract | **Exists + unit-tested** | `crates/headstash/contracts/cw-private-dex` — `SettleSwap`, `CreatePool`, mock_verify dual-path |
| Contract multitest settle | **Green** | `cargo test -p cw-private-dex` (reserves + nullifier + double-spend) |
| WASM prepare for dex | **Missing** | `prepare-corridor-ict-wasm.sh` only produces `cw_headstash.wasm` |
| Daemon upload of dex | **Missing** | No `cw_orch` interface module for private-dex yet |
| Soft-skip mint | **Fail-closed** | shell: `\|\| fail "corridor_ict_funded (chain mint) failed — no silent skip"` |
| Soft-skip settle | **N/A (not wired)** | Pure film can be skipped via `CORRIDOR_SKIP_SWAP_FILM` — **must not** become settle soft-skip |
| Skip/IBC post_swap Action | **Out of scope** | Follow-on after G3 solid |

**Gap statement (honest):** today green = observe + fixture `BridgeMintNote` + pure film. **No** on-chain private settle. G3 freezes how harness closes that seam under **mock_verify lab**.

---

## 2. Target interface (freeze)

### 2.1 Normative types (implementers)

Design against **G2 statement shape** even if G2 pure builders are not coded yet. CW field SSOT is contract `msg.rs`.

```rust
// === From cw-private-dex (already in tree) ===
// crates/headstash/contracts/cw-private-dex/src/msg.rs

pub struct SwapStatementPublic {
    pub pool_id: u64,
    pub asset_in: Binary,      // 32-byte asset id
    pub asset_out: Binary,     // 32-byte asset id
    pub root: Binary,          // 32-byte membership root
    pub nullifiers: Vec<Binary>, // pool-spend ν (32 bytes each)
    pub cm_out: Vec<Binary>,   // note_out [, change]
    pub delta_r_in: Uint128,
    pub delta_r_out: Uint128,
    pub min_out: Uint128,
    pub gamma: u64,
    pub gamma_den: u64,
    pub r_in_before: Uint128,
    pub r_out_before: Uint128,
    pub oracle_mid: Option<OracleMid>,
    pub oracle_params: Option<OracleBoundParams>,
}

// ExecuteMsg::SettleSwap { statement, proof: Binary }  // proof non-empty under mock_verify
// ExecuteMsg::CreatePool { asset_a, asset_b, r_a, r_b, gamma, gamma_den }
// QueryMsg::{ Pool, IsNullifierSpent, QuoteExactIn, Config }
```

```rust
// === G2 → G3 pure→CW map (freeze) ===
// Pure SSOT: private_dex_seams::SwapActionPublic (+ optional SwapActionV0 witness for client-side only)

/// Map pure public half → CosmWasm statement. Witness NEVER on chain.
fn swap_action_public_to_cw(p: &SwapActionPublic) -> SwapStatementPublic {
    SwapStatementPublic {
        pool_id: p.pool_id,
        asset_in: Binary::from(p.asset_in.to_vec()),
        asset_out: Binary::from(p.asset_out.to_vec()),
        root: Binary::from(p.root.to_vec()),
        nullifiers: p.nullifiers.iter().map(|n| Binary::from(n.to_vec())).collect(),
        cm_out: p.cm_out.iter().map(|c| Binary::from(c.to_vec())).collect(),
        delta_r_in: Uint128::new(p.delta_r_in),
        delta_r_out: Uint128::new(p.delta_r_out),
        min_out: Uint128::new(p.min_out),
        gamma: p.gamma,
        gamma_den: p.gamma_den,
        r_in_before: Uint128::new(p.r_in_before),
        r_out_before: Uint128::new(p.r_out_before),
        oracle_mid: p.oracle_mid.as_ref().map(|m| OracleMid {
            pair_key: m.pair_key.clone(),
            mid: Uint128::new(m.mid),
            observed_height: m.observed_height,
        }),
        oracle_params: p.oracle_params.as_ref().map(|q| OracleBoundParams {
            max_age_blocks: q.max_age_blocks,
            max_slippage_bps: q.max_slippage_bps,
            require_oracle: q.require_oracle,
        }),
    }
    // Drop pure `now_height` — contract uses `env.block.height` for oracle age.
}

/// Lab proof under mock_verify (honest label — not Halo2).
fn lab_mock_swap_proof() -> Binary {
    Binary::from(b"corridor-ict-mock-swap-proof-v0".as_slice())
}
```

```rust
// === Mint evidence harness requires before settle (G1/G2 produce; G3 gates) ===

/// Minimal evidence packet written after BridgeMintNote (file or in-process).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MintEvidenceV0 {
    pub profile: String,                 // "ict_local_funded"
    pub chain_id: String,
    pub headstash_contract: String,
    /// Bridge *ingress* nullifier (IsBridgeMinted) — NOT pool-spend ν.
    pub bridge_nullifier_hex: String,    // 32-byte hex
    pub cm_public_hex: String,           // mint note commitment
    pub value_u64: u64,
    pub asset_id_hex: String,            // 32-byte terp/asset id
    /// Client-held openings required for G2 spend (rcm never on chain).
    pub rcm_hex: Option<String>,
    pub owner_binding_hex: Option<String>,
    pub mock_verify_bridge: bool,
    pub mint_tx_hash: Option<String>,
    pub intent_id: Option<String>,
}

/// G2 handoff into settle stage (design freeze — field-complete).
#[derive(Clone, Debug)]
pub struct SwapSpendHandoffV0 {
    pub mint: MintEvidenceV0,
    /// Public statement ready for CW (or pure SwapActionPublic pre-map).
    pub statement: SwapStatementPublic,
    /// Pool-spend nullifiers must be derivable from mint openings (G2 invariant).
    pub pool_nullifiers_hex: Vec<String>,
    /// Lab: non-empty mock proof. Prod: real proof bytes (out of P0).
    pub proof: Binary,
    pub proof_mode: ProofModeLabel, // MockVerifyLab | ZkApi (only lab in G3 P0)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProofModeLabel {
    /// Config.mock_verify=true on private-dex; non-empty proof accepted after host seams.
    MockVerifyLab,
    /// mock_verify=false + zk-api guest + registered zkid — residual, not funded default.
    ZkApi,
}

/// Post-settle automation / host receipt (write JSON artifact).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SettleReceiptV0 {
    pub profile: String,                 // "ict_local_funded"
    pub stage: String,                   // "chain_settle_swap"
    pub status: String,                  // "complete" | fail paths exit non-zero
    pub chain_id: String,
    pub headstash_contract: String,
    pub private_dex_contract: String,
    pub pool_id: u64,
    pub delta_r_in: String,              // decimal string of Uint128
    pub delta_r_out: String,
    pub r_in_after: String,
    pub r_out_after: String,
    pub nullifiers_hex: Vec<String>,     // pool-spend νs marked spent
    pub cm_out_hex: Vec<String>,
    pub bridge_nullifier_hex: String,    // mint identity continuity
    pub mint_cm_public_hex: String,
    pub proof_mode: String,              // "mock_verify_lab" | "zk_api"
    pub mock_verify_dex: bool,
    pub intent_id: Option<String>,
    pub settle_tx_hash: Option<String>,
    /// Explicit honesty fields
    pub halo2_swap: bool,                // always false in G3
    pub skip_ibc_post_swap: bool,        // always false / out of scope
}
```

### 2.2 Wire format / env vars / just sketch

| Env | Default | Meaning |
|-----|---------|---------|
| `CORRIDOR_MOCK_VERIFY` | `true` | Shared bridge **and** private-dex mock_verify on funded deploy (labeled) |
| `CORRIDOR_CHAIN_SETTLE` | `1` when settle profile | Enable G3 path: deploy dex + `SettleSwap` after mint |
| `CORRIDOR_SKIP_SWAP_FILM` | off | Skip **pure** W0–W7 only; **does not** skip chain settle when `CORRIDOR_CHAIN_SETTLE=1` |
| `CORRIDOR_ALLOW_SETTLE_WITHOUT_MINT` | forbidden / unset | **Must not** exist as success path; if set for experiments → hard FAIL in funded profile |
| `CORRIDOR_SETTLE_RECEIPT_PATH` | `/tmp/corridor-settle-receipt.json` | Write `SettleReceiptV0` |
| `CORRIDOR_MINT_EVIDENCE_PATH` | `/tmp/corridor-mint-evidence.json` | Write/read `MintEvidenceV0` |
| `KEEP_CHAIN` | off | Leave ict containers for post-hoc queries |
| Existing ict image/mnemonic vars | unchanged | `CORRIDOR_ICT_IMAGE`, `_TAG`, `_MNEMONIC` |

**just sketch (impl later):**

```just
# Prepare both wasm artifacts (headstash + private-dex, mock_verify guest / no zk-api)
prepare-corridor-ict-wasm-settle:
    # extends prepare-corridor-ict-wasm.sh → also build cw_private_dex.wasm
    # DEST: crates/headstash/artifacts/cw_private_dex.wasm

# Funded observe + mint + chain SettleSwap (mock_verify lab). Pure film residual.
demo-corridor-ict-settle:
    CORRIDOR_CHAIN_SETTLE=1 bash docs/plans/spectrum/e2e/corridor-ict-funded.sh

# Dev residual: mint-only + settle without regtest (still chain mint+settle required)
demo-corridor-ict-settle-mint-only:
    SKIP_REGTEST=1 CORRIDOR_ALLOW_MINT_ONLY=1 CORRIDOR_CHAIN_SETTLE=1 \
      bash docs/plans/spectrum/e2e/corridor-ict-funded.sh
```

**Default policy:** `demo-corridor-ict` may keep pure film until settle lands; once `demo-corridor-ict-settle` is green, STATUS labels settle as the multi-net swap criterion. Pure film remains available as **labeled residual** (`CORRIDOR_SKIP_SWAP_FILM` irrelevant to settle; settle failure always FAIL).

### 2.3 Daemon / cw-orch call sequence (normative)

After Terp is up and sender funded (existing steps 1–2 of `corridor_ict_funded`):

```text
[3] Upload + instantiate cw-headstash (existing)
[4] Configure bridge + BridgeMintNote (existing fail-closed)
    └─► write MintEvidenceV0 (contract, bridge ν, cm_public, value, asset, rcm/openings if client-held)
    └─► assert IsBridgeMinted(bridge_ν)=true

[5] Upload + instantiate cw-private-dex
    InstantiateMsg {
      mock_verify: CORRIDOR_MOCK_VERIFY,  // lab true
      zkid: None,                         // no circuit yet
      allowed_root: Some(lab_root_bin),   // match G2 statement.root
    }
    └─► FAIL if wasm missing (no silent skip)

[6] Owner CreatePool
    asset_a = mint asset_id (BTC/SEAM hub view)
    asset_b = corridor ZEC asset id (G2 registry)
    r_a, r_b = lab virtual reserves (e.g. 1_000_000 / 2_000_000 — same spirit as multitest)
    gamma=997, gamma_den=1000
    └─► record pool_id (first pool → 1 with next_pool_id start)

[7] Optional QuoteExactIn(pool_id, asset_in, delta_in) for preflight Δ_out
    └─► statement.delta_r_out MUST equal host quote (contract rechecks)

[8] Build SwapSpendHandoffV0 via G2 API
    seam openings from MintEvidence (NOT synthetic NoteIn)
    └─► FAIL closed if rcm/openings missing, cm mismatch, or value=0
    └─► map SwapActionPublic → SwapStatementPublic
    └─► proof = lab_mock_swap_proof() when proof_mode=MockVerifyLab
    └─► require statement.nullifiers non-empty; pool ν ≠ bridge ν (G2 invariant)

[9] Execute SettleSwap { statement, proof }
    └─► FAIL closed on any contract error (no film fallback as green)

[10] Post-settle asserts (all required)
     a. Query Pool { pool_id }:
          r_in_after == r_in_before + delta_r_in
          r_out_after == r_out_before - delta_r_out
     b. for each ν in statement.nullifiers:
          IsNullifierSpent { nullifier } == true
     c. Response attributes contain action=settle_swap, pool_id, delta_*, cm_out_*
     d. Double-settle same ν → reject (NullifierExists)

[11] Write SettleReceiptV0 → CORRIDOR_SETTLE_RECEIPT_PATH
     Export PRIVATE_DEX_CONTRACT / HEADSTASH_CONTRACT for shell automation if needed

[12] Pure W0–W7 film
     - When CORRIDOR_CHAIN_SETTLE=1: default SKIP pure film OR run as labeled residual only
       (must not be the sole success criterion)
     - When settle off: existing film behavior

[13] Evidence log + stop chain (unless KEEP_CHAIN)
```

**Shell (`corridor-ict-funded.sh`) delta sketch:**

1. Preflight: prepare **both** wasms when `CORRIDOR_CHAIN_SETTLE=1`.
2. Invoke `corridor_ict_funded` (binary owns Daemon sequence).
3. On binary failure → existing `fail "… no silent skip"` (covers mint **and** settle).
4. Optional: assert receipt file exists + `status=complete` + `proof_mode=mock_verify_lab`.
5. Automation film may read settle receipt fields (contract, pool_id, cm_out) instead of pure-only labels.

---

## 3. File touch list (implementation order)

| Order | Path | Change |
|-------|------|--------|
| 1 | `crates/headstash/contracts/cw-private-dex/src/interface.rs` | New: `#[cw_orch::interface]` + `Uploadable` wasm path `cw_private_dex` (mirror headstash) |
| 2 | `crates/headstash/contracts/cw-private-dex/src/lib.rs` | `pub mod interface` (feature/gate as headstash if needed) |
| 3 | `docs/plans/spectrum/e2e/prepare-corridor-ict-wasm.sh` | Also build/opt `cw_private_dex.wasm` → `artifacts/` |
| 4 | `crates/headstash/test-press/src/suites/private_dex.rs` (new) **or** extend `private_bridge.rs` | Suite: upload/instantiate, create_pool, settle_swap, query helpers |
| 5 | `crates/headstash/test-press/src/harness/mint_evidence.rs` (new) | `MintEvidenceV0` / `SettleReceiptV0` serde + write/read |
| 6 | `crates/headstash/test-press/src/harness/swap_statement_cw.rs` (new) | `swap_action_public_to_cw` + lab proof helper; depends G2 pure builders |
| 7 | `crates/headstash/test-press/src/bin/corridor_ict_funded.rs` | Stages [5]–[11]; gate on `CORRIDOR_CHAIN_SETTLE`; fail-closed |
| 8 | `docs/plans/spectrum/e2e/corridor-ict-funded.sh` | Preflight dual wasm; export receipt path; assert receipt when settle on |
| 9 | `crates/headstash/justfile` | `prepare-corridor-ict-wasm-settle`, `demo-corridor-ict-settle` (+ mint-only residual) |
| 10 | `crates/headstash/test-press/Cargo.toml` | Depend on `cw-private-dex` (path) for interface types if not already |
| 11 | Optional L1 Mock test | `cargo test -p zk-test-press … settle_after_mint_mock` multitest before Daemon |

**Do not touch in G3:** Halo2 circuit, Skip/IBC post_swap Action, ZEC egress, D1–D7 freezes, `mock_verify=false` as default.

---

## 4. Acceptance tests (must be green to call done)

| ID | Layer | Command or assertion |
|----|-------|----------------------|
| **T1** | Unit (existing) | `cd crates/headstash && cargo test -p cw-private-dex` — settle mock_verify, double-spend, curve mismatch |
| **T2** | Pure map | Unit: pure `SwapActionPublic` fixture → `swap_action_public_to_cw` field equality (pool_id, Δ, ν, cm_out, assets) |
| **T3** | L1 Mock | Mint happy → CreatePool → SettleSwap from G2 handoff → Pool reserves + IsNullifierSpent |
| **T4** | Fail-closed openings | Mint evidence without rcm/openings → settle stage **Err**, exit ≠ 0 (no pure film greenwash) |
| **T5** | Fail-closed empty proof | mock_verify lab + empty proof → ProofRejected |
| **T6** | Fail-closed missing wasm | No `cw_private_dex.wasm` → binary FAIL (mirror headstash) |
| **T7** | Daemon / funded | `CORRIDOR_CHAIN_SETTLE=1 just demo-corridor-ict-settle` (or mint-only residual) exit 0; receipt `status=complete`, `proof_mode=mock_verify_lab` |
| **T8** | Soft-skip ban | Intentionally break settle → shell exit 1; must **not** print `OK ict_local_funded` |
| **T9** | Attribute / receipt | Receipt includes `private_dex_contract`, `pool_id`, `delta_r_in/out`, `cm_out_hex[]`, `nullifiers_hex[]`, `mint_cm_public_hex` |
| **T10** | Label honesty | Log/print contains `mock_verify` for dex; no claim of Halo2 or Skip Action |

---

## 5. Fail-closed rules

| Condition | Expected error / exit |
|-----------|------------------------|
| `cw_private_dex.wasm` missing when settle on | Binary `ERROR` / exit 1 before chain work completes |
| Bridge mint fails or `IsBridgeMinted=false` | Existing FAIL closed; **never** proceed to settle |
| Mint evidence missing openings (rcm / owner / cm) required by G2 | `FAIL closed: mint openings missing — cannot build SwapStatement` exit 1 |
| G2 builder returns synthetic NoteIn when SEAM present | Reject / assert panic in product path (G2 invariant; harness refuses handoff) |
| `statement.nullifiers` empty | Contract `BadAmount` → harness FAIL |
| Pool-spend ν equals bridge ingress ν | G2 / validate_swap_action domain error → FAIL (do not submit) |
| `delta_r_out` ≠ host `QuoteExactIn` | Contract `CurveMismatch` → FAIL |
| Empty proof under mock_verify | Contract `ProofRejected` → FAIL |
| `mock_verify=false` without zk-api guest | Contract `ZkApiUnavailable` → FAIL (correct; do not soft-skip) |
| Double settle same ν | `NullifierExists` → expected on replay test; primary settle must still have succeeded |
| Settle execute error | Binary exit 1; shell `fail "… no silent skip"` |
| `CORRIDOR_SKIP_SWAP_FILM=1` with settle on | Allowed for pure film only; settle still required |
| Silent fallback pure film as “OK” after settle fail | **Forbidden** |

---

## 6. Cross-track contracts

| Sibling | What G3 needs from them | What G3 promises |
|---------|-------------------------|------------------|
| **G1 IDENTITY-CLAIM** | Prefer deposit-coupled claim; at minimum mint evidence with cm/value/asset; fixture mint OK for settle lab if `MintEvidenceV0` still filled | Consumes evidence; does not invent claim fields |
| **G2 NOTE-SWAP-SPEND** | `SwapActionV0` / public statement from **mint** openings; pool ν domain ≠ bridge ν; oracle bound on product path; `asset_out` = ZEC registry id | Maps public → `SwapStatementPublic`; submits `SettleSwap`; never rebuilds synthetic NoteIn in settle path |
| **G4 DEST-SEAL** | Dest binding integrity on mint claim (upstream); optional out_owner for `cm_out` | Passes through `cm_out` / dest-related receipt fields; no dest crypto |
| **UI / automation** | — | Receipt JSON fields for host PUT (contract, pool, Δ, cm_out, proof_mode label) |
| **DOCS** | — | Honest: mock_verify lab settle ≠ Tier-0; ≠ Halo2; ≠ Skip/IBC Action |

---

## 7. Explicit non-claims / residual after this track

- **Not** Halo2 swap circuit / real `proof_instance_verify` as funded default.
- **Not** Skip / IBC-hooks / `post_swap` Action wiring (follow-on after settle solid).
- **Not** live ZEC egress or mainnet money.
- **Not** continuous observe→claim alone (G1); settle can lab-run on fixture mint if evidence+openings present and labeled.
- **Not** transparent bank/CW20 swap via `crates/dex` pair (reference only).
- **Not** LP / factory / incentives; virtual reserves only.
- **Not** amending D1–D7 freezes.
- **Residual:** dual pure film noise (H-G4) until settle becomes default green; `KEEP_CHAIN` for post-query; automation may still need receipt plumbing into hash-market PUT (H-G7 partial — G3 writes file; host wiring optional same PR).

---

## 8. Ready-for-impl checklist

- [x] Types named and field-complete (`SwapStatementPublic` SSOT; `MintEvidenceV0`; `SwapSpendHandoffV0`; `SettleReceiptV0`)
- [x] Touch list has owners (file paths)
- [x] Tests named (T1–T10)
- [x] HANDOFF section updated (`## G3 HARNESS-SETTLE`)
- [x] Soft-skip policy: mint/settle failure = FAIL
- [x] mock_verify lab labeled; zk-api residual
- [x] Skip/IBC post_swap Action marked out of scope

---

## Appendix A — Contract event attributes (parse targets)

From `execute_settle_swap` (`contract.rs`):

| Attribute | Source |
|-----------|--------|
| `action` | `"settle_swap"` |
| `pool_id` | statement |
| `delta_r_in` / `delta_r_out` | statement |
| `nullifier_count` / `cm_out_count` | lengths |
| `cm_out_{i}` | each commitment Binary string |

Harness should prefer **queries** (Pool, IsNullifierSpent) as SSOT; attributes for log/debug.

## Appendix B — Proof mode labels (print / receipt)

```text
proof_mode=mock_verify_lab   # CORRIDOR_MOCK_VERIFY=true (default funded)
proof_mode=zk_api            # only if mock_verify=false AND zk-api wasm AND zkid set
halo2_swap=false             # always in this epic
```

## Appendix C — Target stage graph (G3)

```text
corridor-ict-funded.sh  (CORRIDOR_CHAIN_SETTLE=1)
  │
  ├─[BTC] observe ──► (G1 later couples claim)
  │
  └─ corridor_ict_funded
        BridgeMintNote ──► MintEvidenceV0
              │
              ▼
        cw-private-dex instantiate + CreatePool
              │
              ▼
        G2 openings → SwapStatementPublic + lab proof
              │
              ▼
        SettleSwap ──► queries + SettleReceiptV0
              │
              ▼
        pure film residual (optional) / automation reads receipt
```
