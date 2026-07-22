# HANDOFF — Connect private swaps (design freeze)

**Epic:** `connect-private-swap-design-prep-2026-07-22`  
**Status:** Tracks append sections below. Implementers read this before coding.

## Cross-track data flow (target)

```text
DEST-SEAL ──dest_owner_binding──► IDENTITY-CLAIM ──BridgeMintClaimPublic──► mint evidence
                                                                              │
NOTE-SWAP-SPEND ◄── SeamNoteOut / openings ───────────────────────────────────┘
        │
        ▼ SwapActionV0 / SwapStatementPublic + openings
HARNESS-SETTLE ──► cw-private-dex SettleSwap ──► receipt (pool, ν, cm_out)
```

## G1 IDENTITY-CLAIM

| Field | Value |
|-------|--------|
| **Design** | `DESIGN-IDENTITY-CLAIM.md` (this folder) |
| **Gap** | G1 — continuous deposit identity → `BridgeMintClaimPublic` (Phase A / T1) |
| **Status** | **Implemented** — see `STATUS-IMPL-IDENTITY-CLAIM.md` |
| **Code** | `test-press/src/harness/claim_from_deposit.rs`; hub `vout` + `GET /corridor/claim-inputs/:intent_id`; `BridgeL1World::from_deposit_claim`; `corridor_ict_funded` prefer-deposit |
| **Tests** | `cargo test -p zk-test-press --lib claim_from_deposit` (16); `hash-market --lib corridor_deposits --features server` |

### Nullifier rule (normative, provisional)

```text
domain = b"terp-btc-deposit-nu-v0"    # exact bytes; label: provisional until Tacit burn ν
nullifier = SHA256(domain ‖ txid_bytes[32] ‖ vout_be_u32[4] ‖ intent_id_utf8)
```

| Input | Encoding |
|-------|----------|
| `txid` | hex-decode observation `txid` (optional `0x`) → 32 raw bytes; **no** post-decode endian reverse |
| `vout` | `u32` big-endian; **required** on continuous path |
| `intent_id` | UTF-8 as stored on watch/obs |

```rust
pub const TERP_BTC_DEPOSIT_NU_V0: &[u8] = b"terp-btc-deposit-nu-v0";
pub fn deposit_nullifier_v0(txid: &Hash32, vout: u32, intent_id: &str) -> Hash32;
```

Amount is **not** in ν (binds via `value_u64` + `claim_id`). Pure-film “ν = raw txid / hinge label” is **not** SSOT for chain deposit path.

### `claim_from_deposit_watch` (normative)

```rust
pub fn claim_from_deposit_watch(
    obs: &DepositObservationView,   // intent_id, txid, vout, amount_sats, addr, confs
    watch: &DepositWatchView,       // intent_id, addr, dest_owner_binding, min_amount_sats, domain_bind
    policy: &CorridorLabMintPolicy, // lab roots/flags/asset pins; lab_mock_membership labeled
) -> Result<BridgeMintClaimPublic, ClaimFromDepositError>;
```

**Maps:**

| From | To claim field |
|------|----------------|
| `deposit_nullifier_v0(txid, vout, intent_id)` | `nullifier` |
| `amount_sats * unit_scale` (default scale=1) | `value_u64` |
| decode G4 `dest_owner_binding` (64-hex → 32B) | `dest_commitment` **and** `burn_dest_commitment` (equal) |
| `derive_claim_id_with_dest(dest_domain, dest_cm, ν, tacit, value)` | `claim_id` |
| `derive_domain_binding(src, dst, lc, tacit, ν, height, burn_root)` | `domain_binding` (Domain B only) |
| policy lab pins | roots, height, asset tag, pool_domain, cm_public, rcm |
| `lab_mock_membership` | `in_burn_set` / `in_pool_root` / `spent_only=false` |

**Do not** put Domain C watch `domain_bind` into Domain B `domain_binding` (D2).

**Preferred home:** pure helper in `test-press` harness (`claim_from_deposit.rs`) and/or headstash bridge helpers; optional fixture twin for film parity. No CW schema rewrite.

### Field map (JSON keys → claim)

| Observation / watch JSON | Claim / builder |
|--------------------------|-----------------|
| `txid`, `vout`, `intent_id` | ν material |
| `amount_sats` | `value_u64` |
| `dest_owner_binding` (watch) | dest commitments |
| `btc_deposit_addr` | equality gate only (not on claim) |
| `domain_bind` | optional echo; **not** claim `domain_binding` |
| `confirmations` | optional builder min; contract K uses snapshot |
| `min_amount_sats` (watch) | amount floor gate |

### Fail-closed (builder)

| Condition | Error |
|-----------|--------|
| empty / bad `txid` | `MissingTxid` / `InvalidTxidHex` |
| missing vout when `require_vout` | `MissingVout` |
| `amount_sats == 0` | `MissingAmount` |
| amount < watch min | `AmountBelowWatchMin` |
| empty / bad dest hex | `MissingDest` / `InvalidDestHex` |
| intent or addr mismatch obs≠watch | `IntentMismatch` / `AddrMismatch` |

Harness deposit-backed bar: **no** silent `BridgeL1World::happy()` unless `CORRIDOR_ALLOW_HAPPY_FIXTURE` (residual mint-only).

### Optional claim-inputs API (hint-only)

```http
GET /corridor/claim-inputs/:intent_id
```

Returns watch + observation (+ `vout`), `identity_status` (`fields_ready` \| `incomplete_fields` \| `missing_*`), optional `nullifier_preview_hex`, `provisional_nullifier_domain: "terp-btc-deposit-nu-v0"`, `hint_only: true`. Not mint authority (D4).

### Lab labels

- `mock_verify` default true on ict — **label in logs**
- membership flags under lab policy — **not** production IMT/LC
- provisional ν domain — **not** Tacit burn ν

### Promises to siblings

- **→ G2:** note `value` / `owner_binding` / `nullifier_lineage` (= deposit ν) continuous with claim; client `rcm` for spend openings.
- **→ G3:** frozen builder + ν + fail-closed; claim-inputs shape + env hooks (`CORRIDOR_INTENT_ID`, `CORRIDOR_ALLOW_HAPPY_FIXTURE`, optional `CORRIDOR_DEPOSIT_VOUT`).
- **← G4:** sealed `dest_owner_binding` 64-hex; G1 copies bytes into dest fields only.
- **↛** harness execute, swap settle, live ZEC, `mock_verify=false`, mainnet.

## G2 NOTE-SWAP-SPEND

| Field | Value |
|-------|--------|
| **Design** | `DESIGN-NOTE-SWAP-SPEND.md` |
| **Gap** | G2 — minted SEAM → swap spend openings (no synthetic `NoteIn`) |
| **Status** | **Implemented** 2026-07-22 — see `STATUS-IMPL-NOTE-SWAP-SPEND.md` |

### Normative pipeline

```text
MintSpendEvidence / SeamNoteOutV0
  → seam_note_out_to_sketch
  → spend_opening_from_seam_sketch  (SpendNoteOpening)
  → build_swap_action_from_seam_notes / seam_note_out_to_swap_action
  → SwapActionV0 { public, witness }
  → pure: apply_swap_action  |  G3: swap_action_public_to_statement → SettleSwap
```

### Frozen types / functions

| Name | Role | Home (impl) |
|------|------|-------------|
| `MintSpendEvidence` | Inter-stage carrier: `note: SeamNoteOutV0`, `bridge_nullifier`, optional chain coords, `path_position` | `compose_seams` (new) |
| `CorridorSwapSpendParams` | Product params: registry `asset_in`/`asset_out` (ZEC id), **required** oracle mid+params, pool/reserves/min_out/out_owner | `compose_seams` (new) |
| `seam_note_out_to_swap_action(note, params, registry, path_position) → SwapActionV0` | Normative product builder | thin wrap of existing `sketch_swap_action_from_seam_notes` |
| `seam_note_out_to_swap_openings(note, path_position) → SpendNoteOpening` | Openings-only (tests) | wrap `spend_opening_from_seam_sketch` |
| `mint_evidence_to_swap_action(evidence, params, registry) → SwapActionV0` | Harness entry | wrap above |
| `build_swap_action_from_seam_notes` | SSOT compose (unchanged) | `private_dex_seams` |
| `synthetic_pool_spend_nf(cm, rcm)` | Pool ν = `H("pool-nf-v0"‖cm‖rcm)` ≠ ingress lineage | `private_dex_seams` |

### Mint evidence fields G1 must supply

| Field | Width / notes |
|-------|----------------|
| `cm_public` | 32B |
| `rcm` | 32B non-zero; `rcm_flag = 1` |
| `asset_id` | 32B Terp registry id (BTC/sim-BTC side) |
| `value` | u64 |
| `owner_binding` | 32B (dest seal / G4) |
| `nullifier_lineage` | 32B bridge ν |
| `cm_encoding` | ≠ unspecified; product prefer abstract leaf `0x03` when recomputed |

### G3 statement map (`SwapActionPublic` → `SwapStatementPublic`)

| Pure public | CW `SwapStatementPublic` |
|-------------|--------------------------|
| `pool_id` | `pool_id` |
| `asset_in` / `asset_out` `[u8;32]` | `Binary` 32B |
| `root` | `Binary` |
| `nullifiers` / `cm_out` | `Vec<Binary>` |
| `delta_r_in` / `delta_r_out` / `min_out` | `Uint128` |
| `gamma` / `gamma_den` | same |
| `r_in_before` / `r_out_before` | `Uint128` |
| `oracle_mid` / `oracle_params` | same optionals (**product: Some, require_oracle true**) |
| `now_height` | **omit** — CW uses `env.block.height` |

Witness (`notes_in`, `note_out`, `note_change`, `delta_in`) stays client-side.

### Product freezes

- **No** synthetic `NoteIn` / u64 nullifier on corridor W5 or product path — use `apply_swap_action`.
- **Oracle bound_only** + **required** on product burn→swap (`require_oracle: true`).
- **`asset_out`** = corridor ZEC / sim-ZEC **registry** id (not silent hub enum unless that id is ZEC).
- **Pool ν ≠ bridge ingress ν** (NE-4); enforced in `validate_swap_action`.

### What G3 may assume

1. Validated `SwapActionV0` with openings tied to mint cm/rcm.
2. `swap_action_public_to_statement` field map above is complete for `SettleSwap`.
3. Receipt/automation should cite spent mint `cm_public` + pool `nullifiers` + `cm_out`.

## G3 HARNESS-SETTLE

| Field | Value |
|-------|--------|
| **Design pack** | `DESIGN-HARNESS-SETTLE.md` |
| **Gap** | G3 — funded harness → on-chain `cw-private-dex` `SettleSwap` |
| **Status** | **Implemented 2026-07-22** — see `STATUS-IMPL-HARNESS-SETTLE.md` |
| **SSOT statement** | `cw_private_dex::msg::SwapStatementPublic` (map from pure `private_dex_seams::SwapActionPublic`) |

### Consumes (from G1 / G2)

| Input | Shape | Notes |
|-------|--------|-------|
| Mint evidence | `MintEvidenceV0` | `headstash_contract`, bridge ν, `cm_public`, value, asset_id, **client openings (rcm, owner_binding)** |
| Swap handoff | `SwapSpendHandoffV0` | G2-built public statement + non-empty lab proof; pool-spend ν ≠ bridge ingress ν |
| Asset orientation | 32-byte in/out | Pool `asset_a`/`asset_b` match statement; ZEC out = G2 registry id |

### Produces

| Output | Shape | Notes |
|--------|--------|-------|
| On-chain settle | `ExecuteMsg::SettleSwap { statement, proof }` | mock_verify lab default |
| Receipt artifact | `SettleReceiptV0` JSON | contract, pool_id, Δ_in/out, r_after, nullifiers, cm_out, proof_mode, mint cm continuity |
| Env / just | `CORRIDOR_CHAIN_SETTLE`, `demo-corridor-ict-settle` | dual wasm prepare |

### Daemon sequence (freeze)

```text
upload headstash → mint (fail-closed) → write MintEvidenceV0
→ upload private-dex (mock_verify from CORRIDOR_MOCK_VERIFY)
→ CreatePool → (optional QuoteExactIn)
→ G2 statement map → SettleSwap
→ assert Pool reserves + IsNullifierSpent + attrs
→ write SettleReceiptV0
```

### Fail-closed (non-negotiable)

- Missing mint openings / evidence → **FAIL** (no synthetic NoteIn settle)
- Settle or mint error → **FAIL** (no silent pure-film green)
- `CORRIDOR_SKIP_SWAP_FILM` skips pure film only — **never** skips settle when settle profile on
- Empty proof under mock_verify → reject

### Labels

| Mode | When |
|------|------|
| `mock_verify_lab` | Funded default (`CORRIDOR_MOCK_VERIFY=true`) |
| `zk_api` | Residual; not P0 green |
| Halo2 / Skip-IBC post_swap Action | **Out of scope** (follow-on) |

### Impl touch list (summary)

`cw-private-dex` cw-orch `interface` · prepare `cw_private_dex.wasm` · suite helpers · `corridor_ict_funded` stages · shell/just settle target · receipt serde

## G4 DEST-SEAL

| Field | Value |
|-------|--------|
| **Design** | `DESIGN-DEST-SEAL.md` (this folder) |
| **Gap** | G4 — golden/live `dest_owner_binding` on funded path (closes Z-G3 / Phase B4) |
| **Status** | **Implemented** 2026-07-22 — see `STATUS-IMPL-DEST-SEAL.md` |

### SSOT (normative)

| Item | Value |
|------|--------|
| **Golden file** | `docs/plans/spectrum/e2e/zakura/golden-dest-binding.json` |
| **Domain** | `terp-dest-binding-v0` |
| **Preimage** | `terp-dest-binding-v0|` ‖ `utf8_trim(dest_display)` → SHA-256 → 32 bytes |
| **Primary dest_display** | `tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV` |
| **Primary owner_binding_hex** | `8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b` |
| **Rust** | `zakura_local::primary_golden_dest` / `owner_binding_from_dest_display` / `REGTEST_MINER_*` |
| **Shell** | `docs/plans/spectrum/e2e/zakura/zakura-local.sh` `golden` \| `dest` |
| **UI** | `zakuraDest.ts` `DEST_BINDING_DOMAIN` + `GOLDEN_OWNER_BINDING_HEX` + `destOwnerBindingHex` |
| **Offline cert** | `cd crates/headstash && just demo-zakura-local-dest` |

### Watch / wire (for G1 consumers)

| Field | Spec |
|-------|------|
| **Name** | `dest_owner_binding` on `OpenWatchRequest` / `DepositWatch` |
| **Width** | **64** lowercase hex chars = **32 bytes** |
| **Authority** | Binding bytes are seal; `dest_display` is non-authoritative hint |

**G1 must set** `BridgeMintClaimPublic.dest_commitment` **and** `burn_dest_commitment` to the **same 32 bytes** as sealed `owner_binding` (decode watch hex → `[u8; 32]`). Do not re-hash or invent fixture dest.

**G2/G3:** mint/swap `owner_binding` and receipt `dest_owner_binding_hex` re-check against this seal (equality).

### Funded-path seal resolution (must not invent dest)

```text
1. ZAKURA_DEST_ADDR if set → digest (soft-validate + reject placeholder)
2. else primary golden (JSON / REGTEST_MINER_*)
3. optional: ZAKURA_RPC validateaddress → flags only (offline still valid)
```

Export for harness/script: `ZAKURA_DEST_DISPLAY`, `CORRIDOR_DEST_OWNER_BINDING` (64 hex), `CORRIDOR_DEST_SEAL_SOURCE`, `CORRIDOR_DEST_RPC_READY`.

### Fail-closed (product funded)

| Reject | Notes |
|--------|--------|
| Empty dest / empty binding | already partial in hash-market |
| Placeholder hex | `"b"*64`, all-zero, all-`a`/`c` fillers as **dest seal** |
| Width ≠ 64 hex | parse fail |
| Mismatch watch ≠ claim ≠ mint ≠ receipt | equality asserts |
| `CORRIDOR_REQUIRE_ZAKURA_RPC=1` + RPC down/invalid | optional hard live |

**Allowed:** offline golden / UI paste without live ZEC node. **Not required for exit:** live ZEC broadcast.

### Today vs target

| Surface | Today | Target |
|---------|-------|--------|
| `corridor-ict-funded.sh` watch | `"b"*64` | golden primary (or env digest) |
| `corridor_ict_funded` W0–W7 | `CorridorScenario::default()` synthetic | `primary_golden_dest().owner_binding` |
| Pure/UI offline | green golden | unchanged |

### Promises to siblings

- **→ G1:** sealed 32B ready before claim build; field name + width frozen.  
- **→ G2/G3:** single dest identity for owner_binding narrative.  
- **↛** live ZEC egress ownership (residual Phase F).

## Implementation order (after design lands)

1. G1 + G4 (can land same PR stack if interfaces frozen)  
2. G2 pure note-coupled swap  
3. G3 harness + CW settle  
4. Follow-on (not this epic): post_swap_action / Skip-shaped Action / ZEC egress  
