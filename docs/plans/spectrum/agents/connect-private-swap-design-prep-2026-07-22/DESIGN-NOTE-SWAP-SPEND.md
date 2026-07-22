# DESIGN-NOTE-SWAP-SPEND

## 0. Track charter

| Field | Value |
|-------|--------|
| **Goal (one sentence)** | Freeze the pure-first map from a real BridgeMint / SEAM note (openings present) into `SwapActionV0` spend openings + public statement fields for G3 — **no synthetic `NoteIn`**. |
| **Closes gap ID** | **G2** (synthesis Phase D; STATUS-GAP-SWAP S-G2/S-G3 + product D1/D2 pure slice) |
| **Depends on handoffs** | **G1** mint evidence (`SeamNoteOutV0` or hinge `NoteOutSketch` + rcm/cm/value/asset/owner_binding/nullifier_lineage); **G4** `dest_owner_binding` as out_owner policy input (preauth dest already on note) |
| **Produces handoffs** | Normative builders; `MintSpendEvidence` carrier; `SwapActionV0` public ↔ `SwapStatementPublic` field map for **G3**; product-path oracle + ZEC `asset_out` rules |

---

## 1. Current code reality (cite paths)

| Surface | Status | Path / command |
|---------|--------|----------------|
| **SEAM sketch → SwapAction** | **Green pure** | `docs/plans/spectrum/fixtures/private_dex_seams/src/lib.rs` — `SeamNoteSketch`, `SpendNoteOpening`, `build_swap_action_from_seam_notes`, `spend_opening_from_seam_sketch`, `synthetic_pool_spend_nf`, `apply_swap_action`, `validate_swap_action`. `cd …/private_dex_seams && cargo test` |
| **SeamNoteOut → sketch → action** | **Green pure** | `docs/plans/spectrum/fixtures/compose_seams/src/lib.rs` — `seam_note_out_to_sketch`, `sketch_swap_action_from_seam_notes`, `sketch_to_seam_note_out`, `run_product_path_burn_to_swap_sketch`. `cd …/compose_seams && cargo test product_path` |
| **DEX consumability** | **Green pure** | `docs/plans/spectrum/fixtures/seam_note_out/src/lib.rs` — `is_dex_consumable`, `to_dex_spend_inputs` (`rcm_flag=1`, non-zero rcm/cm/asset) |
| **Hinge mint sketch** | **Green pure** | `docs/plans/spectrum/fixtures/bridge_auth_seams` — `NoteOutSketch` (+ `rcm`/`rcm_flag` when set); `to_seam_bytes` 382B |
| **W5 corridor harness** | **Green film / wrong spend shape** | `crates/headstash/test-press/src/harness/cashapp_zec_corridor.rs` — `run_oracle_bound_swap` builds synthetic `NoteIn { AssetId::AssetB, nullifier: u64 }` and calls legacy `apply_swap` — **does not** spend mint SEAM openings (S-G3) |
| **Product path oracle / ZEC id** | **Gap (S-G5/S-G6)** | `run_product_path_burn_to_swap_sketch` sets `oracle_mid/params: None`; `asset_out = asset_id_hub()` not corridor ZEC registry id |
| **cw-private-dex statement** | **Exists; not harness-wired** | `crates/headstash/contracts/cw-private-dex/src/msg.rs` — `SwapStatementPublic` + `SettleSwap`; instances: `instances.rs::encode_swap_instances`. `cargo test -p cw-private-dex` |
| **Halo2 swap** | **Absent (non-goal)** | No circuit; pure / mock_verify only |

### Identity today (broken for product)

```text
G1/mint → SeamNoteOut / NoteOutSketch (cm, rcm, asset, value, owner, ν_lineage)
                ✗ not threaded into W5
W5 → NoteIn { enum asset, value, u64 nullifier } → apply_swap  (synthetic)

compose product path:
  mint SEAM(+rcm) → sketch_swap_action_from_seam_notes → apply_swap_action  ✓ structure
  but oracle_mid = None, asset_out = hub  ✗ product corridor properties
```

---

## 2. Target interface (freeze)

### 2.1 Normative conversion pipeline (pure, no CW rewrite)

```text
MintSpendEvidence / SeamNoteOutV0 / NoteOutSketch(+rcm)
        │
        ▼  (1) to full SeamNoteOutV0 if needed
        │     sketch_to_seam_note_out / sketch_to_seam_note_out_from_hinge
        │     require is_dex_consumable
        ▼  (2) SeamNoteSketch
        │     seam_note_out_to_sketch(n, path_position)
        ▼  (3) SpendNoteOpening(s)
        │     spend_opening_from_seam_sketch  [or via builder]
        ▼  (4) SwapActionV0
              build_swap_action_from_seam_notes / sketch_swap_action_from_seam_notes
        ▼  (5) pure apply OR G3 public extract
              apply_swap_action  |  swap_action_public_to_statement
```

**Reuse first.** Do not invent a parallel spend stack. Normative names below are thin product wrappers over existing ROUND2/ROUND3 APIs.

### 2.2 Types / APIs (normative for implementers)

```rust
// --- Existing SSOT (do not duplicate fields) ---
// private_dex_seams:
//   SeamNoteSketch, SpendNoteOpening, SwapActionPublic, SwapActionWitness,
//   SwapActionV0, SwapFromSeamParams, AssetRegistryView,
//   build_swap_action_from_seam_notes, spend_opening_from_seam_sketch,
//   synthetic_pool_spend_nf, apply_swap_action, validate_swap_action
// compose_seams:
//   seam_note_out_to_sketch, sketch_swap_action_from_seam_notes,
//   sketch_to_seam_note_out(_from_hinge)
// seam_note_out:
//   SeamNoteOutV0, is_dex_consumable, to_dex_spend_inputs

/// Inter-stage mint → spend carrier (host / harness; not a CW msg).
/// G1 emits this (or equivalent fields); G2 consumes it; G3 cites spent cm + νs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MintSpendEvidence {
    /// Full SEAM note when available (preferred; 382B layout).
    pub note: SeamNoteOutV0,
    /// Bridge / claim ingress ν (equals note.nullifier_lineage for bridge mint).
    pub bridge_nullifier: [u8; 32],
    /// Optional chain mint coords (Daemon / cw-headstash); pure path may leave None.
    pub chain_mint_tx: Option<String>,
    pub contract_addr: Option<String>,
    /// Stub membership position for pure narrative (tree crypto later).
    pub path_position: u64,
}

impl MintSpendEvidence {
    /// Build from a DEX-consumable SEAM note (G1 pure or decode-from-bytes).
    pub fn from_seam_note(note: SeamNoteOutV0, path_position: u64) -> Result<Self, /* ErrNotDexConsumable */> {
        // require is_dex_consumable(&note)
        // bridge_nullifier = note.nullifier_lineage
        unimplemented!("impl phase")
    }

    /// Build from hinge sketch that already carries rcm (rcm_flag=1).
    pub fn from_note_out_sketch(sketch: &NoteOutSketch, path_position: u64) -> Result<Self, /* … */> {
        // sketch_to_seam_note_out_from_hinge(sketch)? → from_seam_note
        unimplemented!("impl phase")
    }
}

/// Product params for corridor BTC-side note → ZEC-side note swap.
/// Extends SwapFromSeamParams policy; does not replace pool math fields.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CorridorSwapSpendParams {
    pub pool_id: u64,
    /// Must equal mint note.asset_id (registry-active).
    pub asset_in: [u8; 32],
    /// Corridor ZEC / sim-ZEC **registry** id (NOT AssetId::Hub enum unless that id is registered as ZEC).
    pub asset_out: [u8; 32],
    pub r_in_before: u128,
    pub r_out_before: u128,
    pub gamma: u64,
    pub gamma_den: u64,
    pub min_out: u128,
    pub root: [u8; 32],
    /// Default: full note value (no change). Partial spend needs change_rcm.
    pub delta_in: Option<u128>,
    /// ZEC-side owner: preauth dest / note.owner_binding (G4 golden dest).
    pub out_owner: [u8; 32],
    pub out_rcm: [u8; 32],
    pub change_rcm: Option<[u8; 32]>,
    pub now_height: u64,
    /// **Required on product path** (bound_only).
    pub oracle_mid: OracleMid,
    pub oracle_params: OracleBoundParams,
}

/// Normative product builder: minted SEAM → full SwapActionV0 (openings + public).
///
/// Equivalent to:
///   assert is_dex_consumable
///   sketch = seam_note_out_to_sketch(note, path_position)
///   require oracle_params.require_oracle == true
///   require registry registered(asset_in, asset_out)
///   build_swap_action_from_seam_notes(&[sketch], &swap_from_seam_params, registry)
///
/// Name frozen for implementers / G3 docs. Implementation may be a thin alias of
/// `sketch_swap_action_from_seam_notes` after mapping CorridorSwapSpendParams → SwapFromSeamParams.
pub fn seam_note_out_to_swap_action(
    note: &SeamNoteOutV0,
    params: &CorridorSwapSpendParams,
    registry: &impl AssetRegistryView,
    path_position: u64,
) -> Result<SwapActionV0, ComposeError /* or SwapActionError */>;

/// Openings-only view (witness half) — useful for tests asserting no synthetic NoteIn.
pub fn seam_note_out_to_swap_openings(
    note: &SeamNoteOutV0,
    path_position: u64,
) -> Result<SpendNoteOpening, SwapActionError> {
    // spend_opening_from_seam_sketch(&seam_note_out_to_sketch(note, path_position))
    unimplemented!("impl phase — one-liner over existing")
}

/// Evidence + params → action (harness entry).
pub fn mint_evidence_to_swap_action(
    evidence: &MintSpendEvidence,
    params: &CorridorSwapSpendParams,
    registry: &impl AssetRegistryView,
) -> Result<SwapActionV0, ComposeError> {
    // seam_note_out_to_swap_action(&evidence.note, params, registry, evidence.path_position)
    unimplemented!("impl phase")
}
```

### 2.3 Field map: SEAM / mint → openings → public

| Source (`SeamNoteOutV0` / mint) | `SeamNoteSketch` | `SpendNoteOpening` | Role |
|--------------------------------|------------------|--------------------|------|
| `asset_id` | `asset_id` | `asset_id` | Must = `params.asset_in` |
| `value` | `value` | `value` | Sum → conservation / `delta_in` |
| `cm_public` | `cm_public` | `cm_public` | Membership / ν derivation input |
| `owner_binding` | `owner_binding` | `owner_binding` | Dest seal continuity |
| `rcm` (+ `rcm_flag=1`) | `rcm` / `rcm_flag` | `rcm` | DEX-consumable; pool ν |
| `nullifier_lineage` | `nullifier_lineage` | `ingress_nullifier_lineage` | **≠** pool-spend ν |
| `nullifier_domain` / `origin` | same | (not on opening) | Bridge domain checks |
| `cm_encoding` | `cm_encoding` | — | Must ≠ unspecified; product prefer abstract leaf 0x03 when recompute |
| (host) `path_position` | `path_position` | `path_position` | Stub membership |

**Pool-spend nullifier (derived, never host u64 invent):**

```text
pool_ν = synthetic_pool_spend_nf(cm_public, rcm) = H("pool-nf-v0" ‖ cm ‖ rcm)
assert pool_ν ≠ ingress_nullifier_lineage
assert pool_ν ≠ bridge mint ν (same as lineage for bridge origin)
```

**Forbidden on product path:**

```rust
// DELETE / do not call on funded identity path
NoteIn { asset_id: AssetId::AssetB, value, nullifier: 0xC0 + amount }
apply_swap(&mut pool, &mut state, &notes_in, &SwapPublic { … })  // legacy u64 ν path
```

Use **`apply_swap_action`** with the built `SwapActionV0` instead.

### 2.4 Public statement fields for G3 (`SwapStatementPublic`)

Pure `SwapActionPublic` → CW `SwapStatementPublic` (field-complete map).  
Witness (`SwapActionWitness`) **never** goes on-chain; client-only.

| `SwapActionPublic` (pure) | `SwapStatementPublic` (cw-private-dex) | Notes |
|---------------------------|----------------------------------------|--------|
| `pool_id: u64` | `pool_id: u64` | identical |
| `asset_in: [u8;32]` | `asset_in: Binary` (32B) | registry id bytes |
| `asset_out: [u8;32]` | `asset_out: Binary` (32B) | **corridor ZEC id** |
| `root: [u8;32]` | `root: Binary` | allowed_root window on contract |
| `nullifiers: Vec<[u8;32]>` | `nullifiers: Vec<Binary>` | pool-spend νs only |
| `cm_out: Vec<[u8;32]>` | `cm_out: Vec<Binary>` | note_out (+ change) |
| `delta_r_in: u128` | `delta_r_in: Uint128` | |
| `delta_r_out: u128` | `delta_r_out: Uint128` | host recompute must match |
| `min_out: u128` | `min_out: Uint128` | intent floor |
| `gamma` / `gamma_den` | same | must match pool |
| `r_in_before` / `r_out_before` | `Uint128` | must match pool orient |
| `oracle_mid: Option<OracleMid>` | `Option<msg::OracleMid>` | pair_key ↔ market; mid scale 1e18 |
| `oracle_params: Option<…>` | `Option<msg::OracleBoundParams>` | product: `Some`, `require_oracle: true` |
| `now_height: u64` | **not on statement** | CW uses `env.block.height` for oracle freshness (contract.rs settle) |

```rust
/// G3 helper (pure or harness): extract settle packet from action.
pub fn swap_action_public_to_statement(
    p: &SwapActionPublic,
) -> /* cw_private_dex::msg::SwapStatementPublic or host DTO */ {
    // Binary::from(asset_in.to_vec()), etc.
    // Drop now_height; oracle staleness on chain = block height.
}
```

**Instances encoding (G3 verify path):** `encode_swap_instances(statement)` in  
`crates/headstash/contracts/cw-private-dex/src/instances.rs` — domain tag `SWAP_INSTANCE_LABEL`; witness excluded. G2 guarantees statement fields are consistent with openings via `validate_swap_action` before handoff.

### 2.5 Product-path policy freezes

| Rule | Freeze |
|------|--------|
| **Spend identity** | Spend **the** mint note’s cm/rcm/value/asset — never a parallel synthetic note |
| **Oracle** | Product path **requires** `oracle_params` with `require_oracle: true` + non-stale `oracle_mid`. Bounds only — `oracle_mint_note` / `oracle_update_reserves` remain hard-reject |
| **asset_out** | Registry-resolved corridor ZEC / sim-ZEC id (e.g. harness `hash_tag("sim-ZEC")` or registered label `"zec"`). **Not** silent fallback to `asset_id_hub()` unless hub **is** that registered ZEC id |
| **asset_in** | Mint note’s Terp asset id (tacit-mapped BTC/sim-BTC); must be registered + equal note.asset_id |
| **ν domain** | Pool-spend ν ≠ bridge ingress lineage (NE-4); enforced in `validate_swap_action` / product assert |
| **out_owner** | Defaults to preauth `dest_owner_binding` / mint `owner_binding` (G4 continuity); overrides only for explicit reject tests |
| **Proof** | G2 pure: no proof. G3: mock_verify proof blob OK; Halo2 out of scope |
| **Apply surface pure** | `apply_swap_action` only for SEAM path; legacy `apply_swap`+`NoteIn` retained for unit tests of curve math only, **not** corridor W5 |

### 2.6 Wire format / env / HTTP

| Item | Role |
|------|------|
| Mint evidence JSON (harness artifact) | Fields: `cm_public_hex`, `rcm_hex`, `asset_id_hex`, `value`, `owner_binding_hex`, `nullifier_lineage_hex`, `rcm_flag`, optional `chain_mint_tx`, `path_position` |
| Receipt “spent” fields (automation) | Must cite mint `cm_public` that was spent + pool `nullifiers` + `cm_out` (closes S-G2 film honesty) |
| Oracle mid | In-process for pure; optional Connect `GET /oracle/bounds?market_id=BTC-ZEC` for film — product pure tests inject mid; missing mid when `require_oracle` → fail closed |
| No new HTTP for G2 itself | G3 owns CW `SettleSwap` wire |

### 2.7 W5 replacement shape (harness; impl after design)

```text
// cashapp_zec_corridor.rs — target W5
let evidence = MintSpendEvidence::from_note_out_sketch(&mint_note, 0)
    // or from full SeamNoteOutV0 after sketch_to_seam_note_out
    ?;
// Ensure rcm present: if NoteOutSketch lacks rcm_flag=1, attach openings like compose
let params = CorridorSwapSpendParams {
    asset_in: evidence.note.asset_id,
    asset_out: intent.asset_out_id,  // sim-ZEC registry view
    oracle_mid: dex_oracle_mid_from_intent(...),  // required
    oracle_params: OracleBoundParams { require_oracle: true, ... },
    out_owner: intent.dest_owner_binding,
    min_out: intent.min_out_value as u128,
    // pool reserves, gamma, root, out_rcm, ...
    ...
};
let action = mint_evidence_to_swap_action(&evidence, &params, &registry)?;
let delta_out = apply_swap_action(&mut pool, &mut state, &action, asset_in_is_a)?;
// receipt: note_cm_public = evidence.note.cm_public; pool νs = action.public.nullifiers
```

Pool orientation: virtual pool must register **32-byte** asset_in / asset_out for CW; pure `Pool` today still uses enum `AssetId` — product pure may keep enum orientation **only as host layout** while statement carries 32-byte ids (compose already does this pattern: AssetB/Hub sides + 32-byte action assets). **Impl note:** when wiring CW, create pool with `Binary` asset ids = corridor BTC/ZEC registry ids (G3).

---

## 3. File touch list (implementation order)

| Order | Path | Change |
|-------|------|--------|
| 1 | `docs/plans/spectrum/fixtures/compose_seams/src/lib.rs` | Add `MintSpendEvidence`, `CorridorSwapSpendParams`, `seam_note_out_to_swap_action`, `seam_note_out_to_swap_openings`, `mint_evidence_to_swap_action`; product-path oracle+ZEC required variant of burn→swap |
| 2 | `docs/plans/spectrum/fixtures/private_dex_seams/src/lib.rs` | No large rewrite; optional re-export / doc alias only if needed. Keep `build_swap_action_from_seam_notes` SSOT |
| 3 | `docs/plans/spectrum/fixtures/compose_seams` tests | `product_path_burn_to_swap_oracle_zec` (or extend existing): oracle required; asset_out = registered ZEC id; assert pool ν ≠ bridge ν; openings.cm == mint cm |
| 4 | `crates/headstash/test-press/src/harness/cashapp_zec_corridor.rs` | Replace W5 `run_oracle_bound_swap` synthetic `NoteIn` with evidence → `SwapActionV0` → `apply_swap_action`; receipt cites mint cm + pool νs |
| 5 | `crates/headstash/test-press/src/harness/compose_l0.rs` | Re-export new product path if added |
| 6 | Host film scripts (thin) | Thread mint evidence into swap step when present (`corridor-ict-funded` / mint-after-observe) — label pure apply vs CW |
| 7 | G3 only | `swap_action_public_to_statement` + harness `SettleSwap` — **not** G2 code ownership |

**No** Halo2; **no** large `cw-private-dex` rewrite in G2.

---

## 4. Acceptance tests (must be green to call done)

| ID | Layer | Command or assertion |
|----|-------|----------------------|
| **T1** | pure | Existing green: `cd docs/plans/spectrum/fixtures/private_dex_seams && cargo test` |
| **T2** | pure | Existing green: `cd docs/plans/spectrum/fixtures/compose_seams && cargo test product_path_burn_to_swap_sketch` |
| **T3** | pure product | New: burn → mint SEAM → `seam_note_out_to_swap_action` with **oracle required** + **ZEC asset_out** → `apply_swap_action`; assert `action.witness.notes_in[0].cm_public == mint.cm_public` and `rcm` equal |
| **T4** | pure ν | For each opening: `public.nullifiers[i] == synthetic_pool_spend_nf(cm, rcm)` ∧ `≠ nullifier_lineage` ∧ `≠ bridge ν` |
| **T5** | pure reject | Missing rcm / `rcm_flag=0` → `ErrNotDexConsumable`; wrong asset_id → `ErrWrongAsset`; missing oracle when required → `ErrOracleMissing` |
| **T6** | pure reject | `oracle_mint_note` still `ErrOracleDisabledMint` (bound_only invariant) |
| **T7** | harness | `cargo test -p zk-test-press --lib cashapp_zec_w0_w7_happy_simulated --features 'interface,l0-seams'` after W5 rewrite: no `NoteIn` on happy path; receipt `note_cm_public_hex` matches spent mint |
| **T8** | (G3 collab) | Statement field map unit test: every `SwapActionPublic` field that exists on `SwapStatementPublic` round-trips widths (32B binaries) |

---

## 5. Fail-closed rules

| Condition | Expected error / exit |
|-----------|----------------------|
| Note not DEX-consumable (`rcm_flag≠1`, zero rcm/cm/asset, unspecified encoding) | `ErrNotDexConsumable` / `SeamError::NotDexConsumable` |
| Empty notes_in | `ErrBadAmount` / compose `SwapSketch("empty notes_in")` |
| `asset_in`/`asset_out` unregistered | `ErrUnregisteredAsset` |
| Note asset ≠ params.asset_in | `ErrWrongAsset` |
| `asset_in == asset_out` | `ErrWrongAsset` |
| Product path oracle_params None or `require_oracle` without mid | `ErrOracleMissing` |
| Stale mid / slippage | `ErrOracleStale` / `ErrOracleSlippage` |
| `delta_out < min_out` | `ErrMinOut` |
| Pool ν equals ingress lineage | `ErrNullifierDomain` |
| Double-spend same pool ν | `ErrNullifierExists` on apply |
| Conservation break (residual without change_rcm) | `ErrConservation` |
| Curve recompute ≠ public Δ_out | `ErrCurveMismatch` |
| Synthetic `NoteIn` used in corridor product tests | **Test fail** (lint / assert path does not call legacy apply_swap for W5) |

---

## 6. Cross-track contracts

| Sibling | What this track needs from them | What this track promises |
|---------|--------------------------------|--------------------------|
| **G1 IDENTITY-CLAIM** | Mint yields DEX-consumable openings: `cm_public`, non-zero `rcm`, `rcm_flag=1`, `asset_id`, `value`, `owner_binding`, `nullifier_lineage` (= bridge ν), preferably full `SeamNoteOutV0` or hinge sketch convertible via compose | Consumes `MintSpendEvidence`; never invents cm/rcm |
| **G3 HARNESS-SETTLE** | Pool created with same 32B asset ids; allowed_root matches action.root when set; mock_verify proof non-empty | `SwapActionV0.public` field-complete for `SwapStatementPublic`; `swap_action_public_to_statement` map; openings validated before settle |
| **G4 DEST-SEAL** | Stable `dest_owner_binding` for mint owner + swap out_owner policy | out_owner defaults to mint/intent dest; does not redefine crypto of binding |
| **Oracle / hash-market** | Mid as bounds source only | Never calls mint via oracle; product requires bound check |

### Frozen handoff values (for HANDOFF.md)

| Key | Value |
|-----|--------|
| Evidence type | `MintSpendEvidence { note: SeamNoteOutV0, bridge_nullifier, chain_mint_tx?, contract_addr?, path_position }` |
| Builder | `seam_note_out_to_swap_action` / `mint_evidence_to_swap_action` → `SwapActionV0` |
| Openings | `SpendNoteOpening` via `spend_opening_from_seam_sketch` |
| Pool ν | `synthetic_pool_spend_nf(cm, rcm)` domain `pool-nf-v0` |
| G3 statement | Map §2.4; omit pure-only `now_height` |
| Product oracle | `require_oracle: true` + mid + params on burn→swap product path |
| Product asset_out | Corridor ZEC registry id |

---

## 7. Explicit non-claims / residual after this track

- **Does not** wire `cw-private-dex::SettleSwap` (G3).
- **Does not** build `BridgeMintClaimPublic` from observe (G1).
- **Does not** define dest address crypto (G4).
- **Does not** claim on-chain pool state after pure apply alone.
- **Does not** live ZEC egress / Zakura broadcast.
- **Does not** Halo2 prove.
- **Does not** amend D1–D7 freezes.
- **Residual:** pure `Pool` still enum-oriented host layout until CW pool uses 32B ids end-to-end; dual `intent_allows_swap` (fixture vs harness) remains P2 cleanup (S-G7).

---

## 8. Ready-for-impl checklist

- [x] Types named and field-complete (`MintSpendEvidence`, `CorridorSwapSpendParams`, builders, G3 statement map)
- [x] Touch list has owners (file paths)
- [x] Tests named (T1–T8; not all written yet)
- [x] HANDOFF section updated (`## G2 NOTE-SWAP-SPEND`)
- [x] Pure seam path first; no Halo2; no large CW rewrite
- [x] Pool ν ≠ bridge ingress ν frozen
- [x] Oracle bound_only + required on product path frozen
- [x] No synthetic `NoteIn` on product / W5 target path
