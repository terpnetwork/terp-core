//! Cross-crate pure L0 compose glue (Round 2–3 COMPOSE + G2 product path).
//!
//! Pipeline (no halo2 / no cosmwasm):
//! 1. [`authorize_bridge_mint`](bridge_auth_seams::authorize_bridge_mint) hinge
//! 2. Full [`SeamNoteOutV0`] with **rcm present** (`rcm_flag=1`) so
//!    [`is_dex_consumable`](seam_note_out::is_dex_consumable)
//! 3. Optional structural [`SwapActionV0`] sketch (no prove)
//! 4. **G2 product builders:** [`MintSpendEvidence`] → [`seam_note_out_to_swap_action`]
//!    / [`mint_evidence_to_swap_action`] (no synthetic `NoteIn`)
//! 5. **Product pure E2E:** [`run_product_path_burn_to_swap_sketch`] and
//!    oracle+ZEC [`run_product_path_burn_to_swap_oracle_zec`]
//!
//! Shared [`AssetRegistryView`]: in-memory map (tacit_id / denom / 32-byte
//! asset_id). Registry **never mints balances** — resolve only.
//!
//! **Single re-export surface** for harness / parent agents: hinge + SEAM +
//! swap apply/validate types (prefer this crate over path-importing the three
//! fixture crates separately for the product narrative).
//!
//! Product freeze: `cw-headstash` is the mint/router; this crate is pure
//! structural glue for harness / domain agents to re-export.

#![deny(unsafe_code)]

use std::collections::HashMap;

use bridge_auth_seams::{
    authorize_bridge_mint, terp_asset_id_from_tacit, AssetRegistry, BridgeMintClaim,
    BridgeMintError, MintedSet, NoteOutSketch, ReflectionSnapshot,
};
use private_dex_seams::{
    build_swap_action_from_seam_notes, AssetRegistryView as DexAssetRegistryView, SeamNoteSketch,
};
use seam_note_out::{
    is_dex_consumable, validate_seam_note_out_v0, SeamError, CM_ABSTRACT_LEAF_V0,
    DOMAIN_TAG_NOTE_OUT, VERSION_V0,
};

// Single import+re-export surface for product path consumers (C1–C4 + apply).
// These names are also used by compose APIs in this crate.
pub use private_dex_seams::{
    abstract_leaf_cm, apply_reserves, apply_swap_action, asset_id_hub,
    build_swap_action_from_seam_notes as dex_build_swap_action_from_seam_notes, implied_price,
    oracle_mint_note, quote_exact_in, spend_opening_from_seam_sketch, synthetic_pool_spend_nf,
    validate_swap_action, AssetId as DexPoolAssetId, AssetId32, AssetMap,
    AssetRegistryView as DexAssetRegistryViewTrait, OracleBoundParams, OracleMid, Pool, PoolStatus,
    SeamNoteSketch as DexSeamNoteSketch, SpendNoteOpening, SwapActionError, SwapActionPublic,
    SwapActionV0, SwapFromSeamParams, SwapSeamState, PRICE_SCALE,
};
pub use seam_note_out::{
    decrypt_note_out, encrypt_note_out, is_dex_consumable as seam_is_dex_consumable,
    note_addr_claim, note_addr_cm, note_addr_pk, persist_plan_from_seam_note,
    to_dex_spend_inputs, NoteEnvelope, NotePersistError, NotePersistPlan, SeamNoteOutV0,
    CLEARTEXT_LAYOUT_SEAM_NOTE_OUT_V0, NF_BRIDGE_BURN, ORIGIN_BRIDGE_MINT,
    SCHEME_XCHACHA20POLY1305,
};
pub use bridge_auth_seams::{
    authorize_bridge_mint as hinge_authorize_bridge_mint,
    authorize_bridge_mint_apply as hinge_authorize_bridge_mint_apply, BridgeMintClaim as HingeClaim,
    BridgeMintError as HingeBridgeMintError, BridgeMintPublic as HingeBridgeMintPublic,
    MintedSet as HingeMintedSet, NoteOutSketch as HingeNoteOutSketch,
    ReflectionSnapshot as HingeSnapshot, terp_asset_id_from_tacit as hinge_terp_asset_id_from_tacit,
};

// =============================================================================
// Types
// =============================================================================

pub type Hash32 = [u8; 32];

/// In-memory asset registry view (fixture SSOT for bridge + swap compose).
///
/// Maps foreign keys (Tacit id, CosmWasm denom) → Terp 32-byte `asset_id`.
/// **Never mints balances** — resolve / pin only (CLARITY §2.3).
#[derive(Clone, Debug, Default)]
pub struct AssetRegistryView {
    /// Tacit foreign asset id → Terp `asset_id`.
    by_tacit: HashMap<Hash32, Hash32>,
    /// Local denom string → Terp `asset_id`.
    by_denom: HashMap<String, Hash32>,
    /// Registered Terp asset ids (active set).
    assets: HashMap<Hash32, AssetRecord>,
}

/// Single registered asset row (logical internal registry seed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssetRecord {
    pub asset_id: Hash32,
    pub tacit_id: Option<Hash32>,
    pub denom: Option<String>,
    pub origin: AssetOrigin,
    pub status: AssetStatus,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssetOrigin {
    Native,
    TacitLane,
    Ibc,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssetStatus {
    Active,
    Paused,
    Frozen,
}

impl AssetRegistryView {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a cross-chain / local mapping. Does **not** credit any balance.
    pub fn register(&mut self, record: AssetRecord) {
        if let Some(t) = record.tacit_id {
            self.by_tacit.insert(t, record.asset_id);
        }
        if let Some(ref d) = record.denom {
            self.by_denom.insert(d.clone(), record.asset_id);
        }
        self.assets.insert(record.asset_id, record);
    }

    /// Resolve Terp asset id from a Tacit foreign id (active only).
    pub fn resolve_tacit(&self, tacit_id: &Hash32) -> Option<Hash32> {
        let id = self.by_tacit.get(tacit_id)?;
        let rec = self.assets.get(id)?;
        if rec.status == AssetStatus::Active {
            Some(*id)
        } else {
            None
        }
    }

    /// Resolve Terp asset id from a local denom (active only).
    pub fn resolve_denom(&self, denom: &str) -> Option<Hash32> {
        let id = self.by_denom.get(denom)?;
        let rec = self.assets.get(id)?;
        if rec.status == AssetStatus::Active {
            Some(*id)
        } else {
            None
        }
    }

    pub fn is_active(&self, asset_id: &Hash32) -> bool {
        self.assets
            .get(asset_id)
            .map(|r| r.status == AssetStatus::Active)
            .unwrap_or(false)
    }

    pub fn get(&self, asset_id: &Hash32) -> Option<&AssetRecord> {
        self.assets.get(asset_id)
    }

    /// Project into bridge hinge `AssetRegistry` (mapped set of Terp ids).
    pub fn to_bridge_registry(&self) -> AssetRegistry {
        let mut reg = AssetRegistry::new();
        for (id, rec) in &self.assets {
            if rec.status == AssetStatus::Active {
                reg.register(*id);
            }
        }
        reg
    }

    /// Project into SWAP `AssetMap` (registered 32-byte ids only).
    pub fn to_dex_asset_map(&self) -> private_dex_seams::AssetMap {
        let mut m = private_dex_seams::AssetMap::new();
        for (id, rec) in &self.assets {
            if rec.status == AssetStatus::Active {
                if let Some(ref d) = rec.denom {
                    m.register_labeled(d.clone(), *id);
                } else {
                    m.register(*id);
                }
            }
        }
        m
    }
}

/// SWAP trait: active Terp ids are registered for spend/swap paths.
impl DexAssetRegistryView for AssetRegistryView {
    fn is_registered(&self, asset_id: &Hash32) -> bool {
        self.is_active(asset_id)
    }
}

/// Openings attached at compose time so the note is DEX-consumable.
///
/// Round-2 hinge may already emit `rcm` / `rcm_flag` on [`NoteOutSketch`].
/// Compose still accepts explicit openings (and may recompute abstract `cm`)
/// so swap legs share a single opening source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteOpenings {
    /// Pedersen / abstract leaf blinding (non-zero for rcm_flag=1).
    pub rcm: Hash32,
    /// When true, recompute `cm_public` via `abstract_leaf_cm` and set
    /// `cm_encoding = ABSTRACT_LEAF_V0` so SwapAction openings match.
    pub recompute_abstract_cm: bool,
}

impl NoteOpenings {
    pub fn with_rcm(rcm: Hash32) -> Self {
        Self {
            rcm,
            recompute_abstract_cm: true,
        }
    }
}

/// Compose-layer errors (wrap hinge + seam + registry).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ComposeError {
    /// Hinge / authorize_bridge_mint reject (includes H-1 spent-only).
    Bridge(BridgeMintError),
    /// SEAM layout / validation reject.
    Seam(SeamError),
    /// Asset not active in [`AssetRegistryView`] (compose SSOT).
    UnregisteredAsset,
    /// Openings missing or zero rcm when DEX path required.
    MissingOpenings,
    /// Swap sketch structural failure (bad amounts / orientation).
    SwapSketch(&'static str),
    /// Dex compose reject (registry / consumability / curve).
    Swap(SwapActionError),
}

impl From<BridgeMintError> for ComposeError {
    fn from(e: BridgeMintError) -> Self {
        ComposeError::Bridge(e)
    }
}

impl From<SeamError> for ComposeError {
    fn from(e: SeamError) -> Self {
        ComposeError::Seam(e)
    }
}

impl From<SwapActionError> for ComposeError {
    fn from(e: SwapActionError) -> Self {
        ComposeError::Swap(e)
    }
}

// =============================================================================
// Sketch → full SEAM-NOTE-OUT
// =============================================================================

/// Convert hinge [`NoteOutSketch`] + openings → full [`SeamNoteOutV0`].
///
/// Rcm resolution: non-zero `openings.rcm` wins; else sketch `rcm` when
/// `rcm_flag == 1` (ROUND2-BRIDGE may already emit openings on the sketch).
pub fn sketch_to_seam_note_out(
    sketch: &NoteOutSketch,
    openings: &NoteOpenings,
) -> Result<SeamNoteOutV0, ComposeError> {
    let rcm = if openings.rcm != [0u8; 32] {
        openings.rcm
    } else if sketch.rcm_flag == 1 && sketch.rcm != [0u8; 32] {
        sketch.rcm
    } else {
        return Err(ComposeError::MissingOpenings);
    };

    let mut n = SeamNoteOutV0 {
        version: VERSION_V0,
        domain_tag: DOMAIN_TAG_NOTE_OUT,
        origin: sketch.origin,
        asset_id: sketch.asset_id,
        value: sketch.value,
        owner_binding: sketch.owner_binding,
        cm_public: sketch.cm_public,
        cm_encoding: sketch.cm_encoding,
        nullifier_lineage: sketch.nullifier_lineage,
        nullifier_domain: sketch.nullifier_domain,
        provenance_anchor: sketch.provenance_anchor,
        claim_id: sketch.claim_id,
        source_chain_tag_hash: sketch.source_chain_tag_hash,
        rcm,
        rcm_flag: 1,
        memo: sketch.memo,
        memo_flag: sketch.memo_flag,
        pool_domain: sketch.pool_domain,
    };

    if openings.recompute_abstract_cm {
        n.cm_encoding = CM_ABSTRACT_LEAF_V0;
        n.cm_public = abstract_leaf_cm(&n.asset_id, n.value, &n.owner_binding, &n.rcm);
    }

    validate_seam_note_out_v0(&n)?;
    Ok(n)
}

/// Convert hinge sketch that already carries rcm → full note without extra openings.
///
/// Uses zero openings (prefer sketch rcm) and recompute abstract cm for swap path.
pub fn sketch_to_seam_note_out_from_hinge(
    sketch: &NoteOutSketch,
) -> Result<SeamNoteOutV0, ComposeError> {
    sketch_to_seam_note_out(
        sketch,
        &NoteOpenings {
            rcm: [0u8; 32], // force sketch.rcm path
            recompute_abstract_cm: true,
        },
    )
}

// =============================================================================
// Bridge mint → SEAM-NOTE-OUT compose
// =============================================================================

/// Full L0 compose: hinge authorize → full note with rcm → DEX-consumable check.
///
/// 1. Require claim's Terp asset (via `terp_asset_id_from_tacit` or raw tacit)
///    to be **active** in [`AssetRegistryView`].
/// 2. Project view → bridge `AssetRegistry` and call [`authorize_bridge_mint`].
/// 3. Attach openings → [`SeamNoteOutV0`] with `rcm_flag=1`.
/// 4. Assert [`is_dex_consumable`].
///
/// Compose **never bypasses** hinge gates (H-1 spent-only still rejects).
pub fn authorize_bridge_mint_to_seam_note_out(
    snapshot: &ReflectionSnapshot,
    claim: &BridgeMintClaim,
    minted: &MintedSet,
    registry: &AssetRegistryView,
    openings: &NoteOpenings,
) -> Result<SeamNoteOutV0, ComposeError> {
    let p = &claim.public;
    let terp_asset = terp_asset_id_from_tacit(&p.source_chain_tag, &p.tacit_asset_id, p.unit_scale);

    // Compose SSOT: must resolve via registry view (active).
    // Prefer mapped Terp id; also allow resolve by tacit id key if registered that way.
    let resolved = if registry.is_active(&terp_asset) {
        Some(terp_asset)
    } else {
        registry.resolve_tacit(&p.tacit_asset_id)
    };
    let _asset = resolved.ok_or(ComposeError::UnregisteredAsset)?;

    let bridge_reg = registry.to_bridge_registry();
    let sketch = authorize_bridge_mint(snapshot, claim, minted, &bridge_reg)?;

    // Note asset_id must be active in compose registry (defense in depth).
    if !registry.is_active(&sketch.asset_id) {
        return Err(ComposeError::UnregisteredAsset);
    }

    let note = sketch_to_seam_note_out(&sketch, openings)?;
    if !is_dex_consumable(&note) {
        return Err(ComposeError::Seam(SeamError::NotDexConsumable));
    }
    Ok(note)
}

/// Apply variant: mark ν minted after successful compose.
pub fn authorize_bridge_mint_to_seam_note_out_apply(
    snapshot: &ReflectionSnapshot,
    claim: &BridgeMintClaim,
    minted: &mut MintedSet,
    registry: &AssetRegistryView,
    openings: &NoteOpenings,
) -> Result<SeamNoteOutV0, ComposeError> {
    let note =
        authorize_bridge_mint_to_seam_note_out(snapshot, claim, minted, registry, openings)?;
    minted.mark(claim.public.nullifier);
    Ok(note)
}

// =============================================================================
// Headstash private-note persist plan (encrypt only; no HTTP)
// =============================================================================

/// After a successful bridge mint → SEAM note, build an opaque store plan.
///
/// - `hs_id`: contract bech32 or season slug
/// - `addr`: defaults to `cm.` + hex(`note.cm_public`) when `addr_override` is `None`
/// - Encrypts full 382B cleartext (client-held key; server never re-derives secrets)
///
/// Mint client then: `put_note_envelope(base, plan.hs_id, plan.addr, &plan.envelope, headers)`
/// (feature `http` on `seam_note_out`) or any hash-market client with the same route.
pub fn persist_plan_after_bridge_mint(
    note: &SeamNoteOutV0,
    key: &[u8; 32],
    hs_id: &str,
    addr_override: Option<&str>,
) -> Result<NotePersistPlan, NotePersistError> {
    let addr_owned;
    let addr = if let Some(a) = addr_override {
        a
    } else {
        addr_owned = note_addr_cm(&note.cm_public);
        &addr_owned
    };
    persist_plan_from_seam_note(note, key, hs_id, addr)
}

// =============================================================================
// Optional SwapActionV0 structural sketch (delegates to ROUND2-SWAP helpers)
// =============================================================================

/// Convert full [`SeamNoteOutV0`] → D-side [`SeamNoteSketch`] for swap compose.
pub fn seam_note_out_to_sketch(n: &SeamNoteOutV0, path_position: u64) -> SeamNoteSketch {
    SeamNoteSketch {
        origin: n.origin,
        asset_id: n.asset_id,
        value: n.value,
        owner_binding: n.owner_binding,
        cm_public: n.cm_public,
        cm_encoding: n.cm_encoding,
        nullifier_lineage: n.nullifier_lineage,
        nullifier_domain: n.nullifier_domain,
        rcm: n.rcm,
        rcm_flag: n.rcm_flag,
        path_position,
    }
}

/// Build a structural [`SwapActionV0`] from one or more DEX-consumable SEAM notes.
///
/// Converts notes → [`SeamNoteSketch`], then delegates to
/// [`build_swap_action_from_seam_notes`] (ROUND2-SWAP). **No prove.**
pub fn sketch_swap_action_from_seam_notes(
    notes: &[SeamNoteOutV0],
    registry: &AssetRegistryView,
    params: &SwapFromSeamParams,
    path_position_base: u64,
) -> Result<SwapActionV0, ComposeError> {
    if notes.is_empty() {
        return Err(ComposeError::SwapSketch("empty notes_in"));
    }
    for n in notes {
        if !is_dex_consumable(n) {
            return Err(ComposeError::Seam(SeamError::NotDexConsumable));
        }
    }
    let sketches: Vec<SeamNoteSketch> = notes
        .iter()
        .enumerate()
        .map(|(i, n)| seam_note_out_to_sketch(n, path_position_base + i as u64))
        .collect();
    build_swap_action_from_seam_notes(&sketches, params, registry).map_err(ComposeError::from)
}

// =============================================================================
// G2 product path: MintSpendEvidence → SwapActionV0 (no synthetic NoteIn)
// =============================================================================

/// Inter-stage mint → spend carrier (host / harness; not a CW msg).
///
/// G1 emits this (or equivalent fields); G2 consumes it; G3 cites spent cm + νs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MintSpendEvidence {
    /// Full SEAM note when available (preferred; 382B layout).
    pub note: SeamNoteOutV0,
    /// Bridge / claim ingress ν (equals `note.nullifier_lineage` for bridge mint).
    pub bridge_nullifier: Hash32,
    /// Optional chain mint coords (Daemon / cw-headstash); pure path may leave None.
    pub chain_mint_tx: Option<String>,
    pub contract_addr: Option<String>,
    /// Stub membership position for pure narrative (tree crypto later).
    pub path_position: u64,
}

impl MintSpendEvidence {
    /// Build from a DEX-consumable SEAM note (G1 pure or decode-from-bytes).
    pub fn from_seam_note(note: SeamNoteOutV0, path_position: u64) -> Result<Self, ComposeError> {
        if !is_dex_consumable(&note) {
            return Err(ComposeError::Seam(SeamError::NotDexConsumable));
        }
        let bridge_nullifier = note.nullifier_lineage;
        Ok(Self {
            note,
            bridge_nullifier,
            chain_mint_tx: None,
            contract_addr: None,
            path_position,
        })
    }

    /// Build from hinge sketch that already carries rcm (`rcm_flag=1`).
    pub fn from_note_out_sketch(
        sketch: &NoteOutSketch,
        path_position: u64,
    ) -> Result<Self, ComposeError> {
        let note = sketch_to_seam_note_out_from_hinge(sketch)?;
        Self::from_seam_note(note, path_position)
    }
}

/// Product params for corridor BTC-side note → ZEC-side note swap.
///
/// Extends [`SwapFromSeamParams`] policy; does not replace pool math fields.
/// **Oracle mid + params are required** (`require_oracle` must be true).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CorridorSwapSpendParams {
    pub pool_id: u64,
    /// Must equal mint note.asset_id (registry-active).
    pub asset_in: Hash32,
    /// Corridor ZEC / sim-ZEC **registry** id (not silent hub enum unless that id is ZEC).
    pub asset_out: Hash32,
    pub r_in_before: u128,
    pub r_out_before: u128,
    pub gamma: u64,
    pub gamma_den: u64,
    pub min_out: u128,
    pub root: Hash32,
    /// Default: full note value (no change). Partial spend needs `change_rcm`.
    pub delta_in: Option<u128>,
    /// ZEC-side owner: preauth dest / note.owner_binding (G4 golden dest).
    pub out_owner: Hash32,
    pub out_rcm: Hash32,
    pub change_rcm: Option<Hash32>,
    pub now_height: u64,
    /// **Required on product path** (bound_only).
    pub oracle_mid: OracleMid,
    pub oracle_params: OracleBoundParams,
}

impl CorridorSwapSpendParams {
    /// Map to ROUND2-SWAP [`SwapFromSeamParams`] with oracle required.
    pub fn to_swap_from_seam(&self) -> Result<SwapFromSeamParams, ComposeError> {
        if !self.oracle_params.require_oracle {
            return Err(ComposeError::Swap(SwapActionError::ErrOracleMissing));
        }
        Ok(SwapFromSeamParams {
            pool_id: self.pool_id,
            asset_in: self.asset_in,
            asset_out: self.asset_out,
            r_in_before: self.r_in_before,
            r_out_before: self.r_out_before,
            gamma: self.gamma,
            gamma_den: self.gamma_den,
            min_out: self.min_out,
            root: self.root,
            delta_in: self.delta_in,
            out_owner: self.out_owner,
            out_rcm: self.out_rcm,
            change_rcm: self.change_rcm,
            now_height: self.now_height,
            oracle_mid: Some(self.oracle_mid.clone()),
            oracle_params: Some(self.oracle_params.clone()),
        })
    }
}

/// Normative product builder: minted SEAM → full [`SwapActionV0`] (openings + public).
///
/// Thin product wrapper over [`sketch_swap_action_from_seam_notes`] after mapping
/// [`CorridorSwapSpendParams`] → [`SwapFromSeamParams`]. Enforces oracle required.
pub fn seam_note_out_to_swap_action(
    note: &SeamNoteOutV0,
    params: &CorridorSwapSpendParams,
    registry: &AssetRegistryView,
    path_position: u64,
) -> Result<SwapActionV0, ComposeError> {
    let seam_params = params.to_swap_from_seam()?;
    sketch_swap_action_from_seam_notes(&[note.clone()], registry, &seam_params, path_position)
}

/// Openings-only view (witness half) — useful for tests asserting no synthetic NoteIn.
pub fn seam_note_out_to_swap_openings(
    note: &SeamNoteOutV0,
    path_position: u64,
) -> Result<SpendNoteOpening, ComposeError> {
    if !is_dex_consumable(note) {
        return Err(ComposeError::Seam(SeamError::NotDexConsumable));
    }
    let sketch = seam_note_out_to_sketch(note, path_position);
    spend_opening_from_seam_sketch(&sketch).map_err(ComposeError::from)
}

/// Evidence + params → action (harness entry).
pub fn mint_evidence_to_swap_action(
    evidence: &MintSpendEvidence,
    params: &CorridorSwapSpendParams,
    registry: &AssetRegistryView,
) -> Result<SwapActionV0, ComposeError> {
    seam_note_out_to_swap_action(
        &evidence.note,
        params,
        registry,
        evidence.path_position,
    )
}

/// Host DTO mirroring CW `SwapStatementPublic` field layout (no cosmwasm dep).
///
/// G3 maps this (or rebuilds) into `cw_private_dex::msg::SwapStatementPublic`.
/// Pure-only `now_height` is **omitted** (CW uses `env.block.height`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SwapStatementPublicView {
    pub pool_id: u64,
    pub asset_in: Vec<u8>,
    pub asset_out: Vec<u8>,
    pub root: Vec<u8>,
    pub nullifiers: Vec<Vec<u8>>,
    pub cm_out: Vec<Vec<u8>>,
    pub delta_r_in: u128,
    pub delta_r_out: u128,
    pub min_out: u128,
    pub gamma: u64,
    pub gamma_den: u64,
    pub r_in_before: u128,
    pub r_out_before: u128,
    pub oracle_mid: Option<OracleMid>,
    pub oracle_params: Option<OracleBoundParams>,
}

/// G3 helper (pure): extract settle packet fields from action public half.
///
/// Witness stays client-side. Binary widths are 32B for fixed fields.
pub fn swap_action_public_to_statement(p: &SwapActionPublic) -> SwapStatementPublicView {
    SwapStatementPublicView {
        pool_id: p.pool_id,
        asset_in: p.asset_in.to_vec(),
        asset_out: p.asset_out.to_vec(),
        root: p.root.to_vec(),
        nullifiers: p.nullifiers.iter().map(|n| n.to_vec()).collect(),
        cm_out: p.cm_out.iter().map(|c| c.to_vec()).collect(),
        delta_r_in: p.delta_r_in,
        delta_r_out: p.delta_r_out,
        min_out: p.min_out,
        gamma: p.gamma,
        gamma_den: p.gamma_den,
        r_in_before: p.r_in_before,
        r_out_before: p.r_out_before,
        oracle_mid: p.oracle_mid.clone(),
        oracle_params: p.oracle_params.clone(),
    }
}

// =============================================================================
// Product pure E2E (documented L0 product path — no Halo2 / no CosmWasm)
// =============================================================================

/// Outcome of [`run_product_path_burn_to_swap_sketch`].
///
/// Asserts reserves + pool nullifiers after a full structural apply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProductPathOutcome {
    /// Bridge mint note(s) spent into the pool (DEX-consumable SEAM).
    pub notes_in: usize,
    /// Bridge ν marked minted (ingress lineage; ≠ pool-spend ν).
    pub bridge_minted_nullifiers: Vec<Hash32>,
    /// Pool-spend nullifiers inserted into host state.
    pub pool_nullifiers: Vec<Hash32>,
    pub asset_in: Hash32,
    pub asset_out: Hash32,
    pub delta_in: u128,
    pub delta_out: u128,
    pub r_in_before: u128,
    pub r_out_before: u128,
    pub r_in_after: u128,
    pub r_out_after: u128,
}

/// **Product pure E2E:** register assets → bridge mint → SEAM note (+rcm) →
/// `SwapActionV0` → `apply_swap_action` → assert reserves + nullifiers.
///
/// Single re-export path for the L0 product narrative (C1+C4 extended with host
/// apply). No Halo2, no CosmWasm. Headstash/cw-headstash remains the on-chain
/// mint/router; this is structural glue only.
///
/// ```text
/// AssetRegistryView.register(tacit + hub)
///   → authorize_bridge_mint_to_seam_note_out_apply  (ν minted)
///   → sketch_swap_action_from_seam_notes            (SwapActionV0)
///   → apply_swap_action                             (R' + pool ν set)
/// ```
pub fn run_product_path_burn_to_swap_sketch() -> Result<ProductPathOutcome, ComposeError> {
    use bridge_auth_seams::{
        derive_claim_id_with_dest, derive_domain_binding, DEFAULT_CONFIRMATIONS_K,
        DEFAULT_MAX_LC_LAG,
    };
    use private_dex_seams::{
        apply_swap_action, asset_id_hub, quote_exact_in, AssetId, Pool, PoolStatus, SwapSeamState,
        validate_swap_action,
    };
    use sha2::{Digest, Sha256};

    fn label_hash(label: &str) -> Hash32 {
        let mut hasher = Sha256::new();
        hasher.update(label.as_bytes());
        let out = hasher.finalize();
        let mut id = [0u8; 32];
        id.copy_from_slice(&out);
        id
    }

    // --- 1. Register assets (resolve-only registry; never mints balances) ---
    let dest = label_hash("terp-chain-1");
    let tacit_asset = label_hash("tacit-btc-etch-1");
    let unit_scale = 1u64;
    let terp_asset = terp_asset_id_from_tacit("bitcoin-mainnet", &tacit_asset, unit_scale);
    let hub = asset_id_hub();

    let mut registry = AssetRegistryView::new();
    registry.register(AssetRecord {
        asset_id: terp_asset,
        tacit_id: Some(tacit_asset),
        denom: Some("utacitbtc".into()),
        origin: AssetOrigin::TacitLane,
        status: AssetStatus::Active,
    });
    registry.register(AssetRecord {
        asset_id: hub,
        tacit_id: None,
        denom: Some("uterp".into()),
        origin: AssetOrigin::Native,
        status: AssetStatus::Active,
    });

    // --- 2. authorize_bridge_mint → full SEAM note with rcm (DEX-consumable) ---
    let nu = label_hash("nu-product-path-1");
    let dest_cm = label_hash("dest-commitment-product");
    let pool_root = label_hash("pool-root-product");
    let spent_root = label_hash("spent-root-product");
    let burn_root = label_hash("burn-root-product");
    let height = 100u64;
    let tip = height + DEFAULT_CONFIRMATIONS_K;
    let mint_value = 1_000_000u64;
    let claim_id =
        derive_claim_id_with_dest(&dest, &dest_cm, &nu, &tacit_asset, mint_value);
    let src_chain = label_hash("src-bitcoin-mainnet");
    let dst_chain = dest;
    let lc_client = label_hash("lc-client-reflection-0");
    let domain_binding = derive_domain_binding(
        &src_chain,
        &dst_chain,
        &lc_client,
        &tacit_asset,
        &nu,
        height,
        &burn_root,
    );

    let snapshot = ReflectionSnapshot {
        pool_root,
        spent_root,
        burn_root,
        source_height: height,
        tip_height: tip,
        confirmations_k: DEFAULT_CONFIRMATIONS_K,
        max_lc_lag: DEFAULT_MAX_LC_LAG,
        frozen: false,
    };

    let claim = BridgeMintClaim {
        public: bridge_auth_seams::BridgeMintPublic {
            source_chain_tag: "bitcoin-mainnet".into(),
            tacit_asset_id: tacit_asset,
            value_u64: mint_value,
            nullifier: nu,
            dest_commitment: dest_cm,
            dest_domain: dest,
            claim_id,
            source_pool_root: pool_root,
            source_burn_root: burn_root,
            source_height: height,
            domain_binding,
            unit_scale,
            pool_domain: label_hash("terp-pool-0"),
            cm_public: label_hash("cm-leaf-product-1"),
            rcm: label_hash("rcm-product-1"),
        },
        mint_value,
        expected_dest_domain: dest,
        src_chain_id: src_chain,
        dst_chain_id: dst_chain,
        lc_client_id: lc_client,
        burn_dest_commitment: dest_cm,
        in_burn_set: true,
        in_pool_root: true,
        spent_only: false,
    };

    let openings = NoteOpenings::with_rcm(label_hash("rcm-product-1"));
    let mut minted = MintedSet::new();
    let note = authorize_bridge_mint_to_seam_note_out_apply(
        &snapshot,
        &claim,
        &mut minted,
        &registry,
        &openings,
    )?;
    if !is_dex_consumable(&note) {
        return Err(ComposeError::Seam(SeamError::NotDexConsumable));
    }
    if !minted.contains(&nu) {
        return Err(ComposeError::SwapSketch("bridge ν not marked minted"));
    }

    // --- 3. Pool setup + structural SwapActionV0 from the mint note ---
    let r_in_before = 10_000_000u128;
    let r_out_before = 5_000_000u128;
    let gamma = 997u64;
    let gamma_den = 1000u64;
    let delta_in = note.value as u128;
    let expected_out =
        quote_exact_in(r_in_before, r_out_before, delta_in, gamma, gamma_den)
            .map_err(|_| ComposeError::SwapSketch("quote_exact_in failed"))?;

    let params = SwapFromSeamParams {
        pool_id: 1,
        asset_in: terp_asset,
        asset_out: hub,
        r_in_before,
        r_out_before,
        gamma,
        gamma_den,
        min_out: expected_out,
        root: label_hash("shared-tree-root-product"),
        delta_in: Some(delta_in),
        out_owner: label_hash("swap-out-owner-product"),
        out_rcm: label_hash("swap-out-rcm-product"),
        change_rcm: None,
        now_height: 200,
        oracle_mid: None,
        oracle_params: None,
    };

    let action = sketch_swap_action_from_seam_notes(&[note], &registry, &params, 0)?;
    let delta_out = validate_swap_action(&action)?;
    if delta_out != expected_out {
        return Err(ComposeError::SwapSketch("curve mismatch after validate"));
    }

    // Pool ν ≠ ingress bridge ν (NE-4)
    for (opening, pub_nf) in action
        .witness
        .notes_in
        .iter()
        .zip(action.public.nullifiers.iter())
    {
        if *pub_nf == opening.ingress_nullifier_lineage {
            return Err(ComposeError::SwapSketch(
                "pool ν must not equal bridge ingress lineage",
            ));
        }
        if *pub_nf == nu {
            return Err(ComposeError::SwapSketch(
                "pool ν must not equal bridge mint ν",
            ));
        }
    }

    // --- 4. apply_swap_action → host reserves + nullifier set ---
    // Orientation: asset_in on B side so r_b = r_in, r_a = r_out (hub).
    let mut pool = Pool {
        pool_id: 1,
        asset_a: AssetId::Hub,
        asset_b: AssetId::AssetB,
        r_a: r_out_before,
        r_b: r_in_before,
        gamma,
        gamma_den,
        status: PoolStatus::Active,
    };
    let mut state = SwapSeamState {
        allowed_root: Some(action.public.root),
        ..Default::default()
    };
    let got = apply_swap_action(&mut pool, &mut state, &action, /* asset_in_is_a */ false)
        .map_err(ComposeError::from)?;
    if got != expected_out {
        return Err(ComposeError::SwapSketch("apply returned unexpected Δ_out"));
    }

    let r_in_after = pool.r_b;
    let r_out_after = pool.r_a;
    if r_in_after != r_in_before + delta_in {
        return Err(ComposeError::SwapSketch("r_in after mismatch"));
    }
    if r_out_after != r_out_before - expected_out {
        return Err(ComposeError::SwapSketch("r_out after mismatch"));
    }
    for nf in &action.public.nullifiers {
        if !state.nullifiers.contains(nf) {
            return Err(ComposeError::SwapSketch("pool ν not in host set"));
        }
    }
    if state.tree_leaves != action.public.cm_out.len() as u64 {
        return Err(ComposeError::SwapSketch("tree_leaves != cm_out len"));
    }

    Ok(ProductPathOutcome {
        notes_in: action.witness.notes_in.len(),
        bridge_minted_nullifiers: vec![nu],
        pool_nullifiers: action.public.nullifiers.clone(),
        asset_in: terp_asset,
        asset_out: hub,
        delta_in,
        delta_out: expected_out,
        r_in_before,
        r_out_before,
        r_in_after,
        r_out_after,
    })
}

/// Extended product path outcome: mint openings + oracle-bound ZEC `asset_out`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProductPathOracleZecOutcome {
    pub base: ProductPathOutcome,
    /// Mint SEAM spent into the pool (identity continuity).
    pub mint_note: SeamNoteOutV0,
    /// Built action (openings + public); no synthetic NoteIn.
    pub action: SwapActionV0,
    /// Statement view for G3 settle map (widths only; no CW types).
    pub statement: SwapStatementPublicView,
}

/// **Product pure E2E (G2):** burn → mint SEAM → `seam_note_out_to_swap_action`
/// with **oracle required** + **registered sim-ZEC `asset_out`** → `apply_swap_action`.
///
/// Asserts openings.cm/rcm == mint note; pool ν ≠ bridge ingress ν.
pub fn run_product_path_burn_to_swap_oracle_zec() -> Result<ProductPathOracleZecOutcome, ComposeError>
{
    use bridge_auth_seams::{
        derive_claim_id_with_dest, derive_domain_binding, DEFAULT_CONFIRMATIONS_K,
        DEFAULT_MAX_LC_LAG,
    };
    use private_dex_seams::{
        apply_swap_action, implied_price, quote_exact_in, AssetId, Pool, PoolStatus, SwapSeamState,
        validate_swap_action, OracleBoundParams, OracleMid,
    };
    use sha2::{Digest, Sha256};

    fn label_hash(label: &str) -> Hash32 {
        let mut hasher = Sha256::new();
        hasher.update(label.as_bytes());
        let out = hasher.finalize();
        let mut id = [0u8; 32];
        id.copy_from_slice(&out);
        id
    }

    // --- 1. Register assets: tacit BTC + corridor sim-ZEC registry id ---
    let dest = label_hash("terp-chain-1");
    let tacit_asset = label_hash("tacit-btc-etch-1");
    let unit_scale = 1u64;
    let terp_asset = terp_asset_id_from_tacit("bitcoin-mainnet", &tacit_asset, unit_scale);
    let zec = label_hash("sim-ZEC");

    let mut registry = AssetRegistryView::new();
    registry.register(AssetRecord {
        asset_id: terp_asset,
        tacit_id: Some(tacit_asset),
        denom: Some("utacitbtc".into()),
        origin: AssetOrigin::TacitLane,
        status: AssetStatus::Active,
    });
    registry.register(AssetRecord {
        asset_id: zec,
        tacit_id: None,
        denom: Some("sim-zec".into()),
        origin: AssetOrigin::Native,
        status: AssetStatus::Active,
    });

    // --- 2. authorize_bridge_mint → full SEAM note with rcm ---
    let nu = label_hash("nu-product-path-oracle-zec-1");
    let dest_cm = label_hash("dest-commitment-product-oracle");
    let pool_root = label_hash("pool-root-product-oracle");
    let spent_root = label_hash("spent-root-product-oracle");
    let burn_root = label_hash("burn-root-product-oracle");
    let height = 100u64;
    let tip = height + DEFAULT_CONFIRMATIONS_K;
    let mint_value = 1_000_000u64;
    let claim_id =
        derive_claim_id_with_dest(&dest, &dest_cm, &nu, &tacit_asset, mint_value);
    let src_chain = label_hash("src-bitcoin-mainnet");
    let dst_chain = dest;
    let lc_client = label_hash("lc-client-reflection-0");
    let domain_binding = derive_domain_binding(
        &src_chain,
        &dst_chain,
        &lc_client,
        &tacit_asset,
        &nu,
        height,
        &burn_root,
    );

    let snapshot = ReflectionSnapshot {
        pool_root,
        spent_root,
        burn_root,
        source_height: height,
        tip_height: tip,
        confirmations_k: DEFAULT_CONFIRMATIONS_K,
        max_lc_lag: DEFAULT_MAX_LC_LAG,
        frozen: false,
    };

    let claim = BridgeMintClaim {
        public: bridge_auth_seams::BridgeMintPublic {
            source_chain_tag: "bitcoin-mainnet".into(),
            tacit_asset_id: tacit_asset,
            value_u64: mint_value,
            nullifier: nu,
            dest_commitment: dest_cm,
            dest_domain: dest,
            claim_id,
            source_pool_root: pool_root,
            source_burn_root: burn_root,
            source_height: height,
            domain_binding,
            unit_scale,
            pool_domain: label_hash("terp-pool-0"),
            cm_public: label_hash("cm-leaf-product-oracle-1"),
            rcm: label_hash("rcm-product-oracle-1"),
        },
        mint_value,
        expected_dest_domain: dest,
        src_chain_id: src_chain,
        dst_chain_id: dst_chain,
        lc_client_id: lc_client,
        burn_dest_commitment: dest_cm,
        in_burn_set: true,
        in_pool_root: true,
        spent_only: false,
    };

    let openings = NoteOpenings::with_rcm(label_hash("rcm-product-oracle-1"));
    let mut minted = MintedSet::new();
    let note = authorize_bridge_mint_to_seam_note_out_apply(
        &snapshot,
        &claim,
        &mut minted,
        &registry,
        &openings,
    )?;
    if !is_dex_consumable(&note) {
        return Err(ComposeError::Seam(SeamError::NotDexConsumable));
    }

    let evidence = MintSpendEvidence::from_seam_note(note.clone(), 0)?;

    // --- 3. Corridor product params: oracle required + ZEC asset_out ---
    let r_in_before = 10_000_000u128;
    let r_out_before = 5_000_000u128;
    let gamma = 997u64;
    let gamma_den = 1000u64;
    let delta_in = note.value as u128;
    let expected_out =
        quote_exact_in(r_in_before, r_out_before, delta_in, gamma, gamma_den)
            .map_err(|_| ComposeError::SwapSketch("quote_exact_in failed"))?;
    let mid = implied_price(delta_in, expected_out)
        .map_err(|_| ComposeError::SwapSketch("implied_price failed"))?;

    let params = CorridorSwapSpendParams {
        pool_id: 1,
        asset_in: terp_asset,
        asset_out: zec,
        r_in_before,
        r_out_before,
        gamma,
        gamma_den,
        min_out: expected_out,
        root: label_hash("shared-tree-root-product-oracle"),
        delta_in: Some(delta_in),
        out_owner: note.owner_binding,
        out_rcm: label_hash("swap-out-rcm-product-oracle"),
        change_rcm: None,
        now_height: 200,
        oracle_mid: OracleMid {
            pair_key: "BTC-ZEC".into(),
            mid,
            observed_height: 100,
        },
        oracle_params: OracleBoundParams {
            max_age_blocks: 1000,
            max_slippage_bps: 500,
            require_oracle: true,
        },
    };

    let action = mint_evidence_to_swap_action(&evidence, &params, &registry)?;
    let delta_out = validate_swap_action(&action)?;
    if delta_out != expected_out {
        return Err(ComposeError::SwapSketch("curve mismatch after validate"));
    }

    // Openings identity: spend the mint note (cm + rcm)
    let opening = &action.witness.notes_in[0];
    if opening.cm_public != evidence.note.cm_public || opening.rcm != evidence.note.rcm {
        return Err(ComposeError::SwapSketch(
            "openings must equal mint SEAM cm/rcm",
        ));
    }
    if action.public.asset_out != zec {
        return Err(ComposeError::SwapSketch("asset_out must be corridor ZEC id"));
    }
    if action.public.oracle_params.as_ref().map(|p| p.require_oracle) != Some(true) {
        return Err(ComposeError::SwapSketch("oracle required on product path"));
    }

    // Pool ν ≠ ingress bridge ν (NE-4)
    for (opening, pub_nf) in action
        .witness
        .notes_in
        .iter()
        .zip(action.public.nullifiers.iter())
    {
        let expect_nf = synthetic_pool_spend_nf(&opening.cm_public, &opening.rcm);
        if *pub_nf != expect_nf {
            return Err(ComposeError::SwapSketch("pool ν != synthetic_pool_spend_nf"));
        }
        if *pub_nf == opening.ingress_nullifier_lineage || *pub_nf == nu {
            return Err(ComposeError::SwapSketch(
                "pool ν must not equal bridge ingress lineage",
            ));
        }
    }

    // --- 4. apply_swap_action ---
    let mut pool = Pool {
        pool_id: 1,
        asset_a: AssetId::Hub, // host enum layout only; statement carries 32B ZEC id
        asset_b: AssetId::AssetB,
        r_a: r_out_before,
        r_b: r_in_before,
        gamma,
        gamma_den,
        status: PoolStatus::Active,
    };
    let mut state = SwapSeamState {
        allowed_root: Some(action.public.root),
        ..Default::default()
    };
    let got = apply_swap_action(&mut pool, &mut state, &action, /* asset_in_is_a */ false)
        .map_err(ComposeError::from)?;
    if got != expected_out {
        return Err(ComposeError::SwapSketch("apply returned unexpected Δ_out"));
    }

    let r_in_after = pool.r_b;
    let r_out_after = pool.r_a;
    let statement = swap_action_public_to_statement(&action.public);

    Ok(ProductPathOracleZecOutcome {
        base: ProductPathOutcome {
            notes_in: action.witness.notes_in.len(),
            bridge_minted_nullifiers: vec![nu],
            pool_nullifiers: action.public.nullifiers.clone(),
            asset_in: terp_asset,
            asset_out: zec,
            delta_in,
            delta_out: expected_out,
            r_in_before,
            r_out_before,
            r_in_after,
            r_out_after,
        },
        mint_note: evidence.note,
        action,
        statement,
    })
}

// =============================================================================
// Tests C1–C4 + product pure E2E
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use bridge_auth_seams::{
        derive_claim_id_with_dest, derive_domain_binding, DEFAULT_CONFIRMATIONS_K,
        DEFAULT_MAX_LC_LAG,
    };
    use private_dex_seams::{quote_exact_in, synthetic_pool_spend_nf, validate_swap_action};
    use seam_note_out::{is_dex_consumable, to_dex_spend_inputs, validate_seam_note_out_v0};
    use sha2::{Digest, Sha256};

    fn h(label: &str) -> Hash32 {
        let mut hasher = Sha256::new();
        hasher.update(label.as_bytes());
        let out = hasher.finalize();
        let mut id = [0u8; 32];
        id.copy_from_slice(&out);
        id
    }

    /// Shared happy hinge world + compose registry with mapped Terp asset.
    fn compose_fixture() -> (
        ReflectionSnapshot,
        BridgeMintClaim,
        MintedSet,
        AssetRegistryView,
        Hash32, // terp asset id
        NoteOpenings,
    ) {
        let dest = h("terp-chain-1");
        let tacit_asset = h("tacit-btc-etch-1");
        let unit_scale = 1u64;
        let terp_asset = terp_asset_id_from_tacit("bitcoin-mainnet", &tacit_asset, unit_scale);
        let nu = h("nu-compose-happy");
        let dest_cm = h("dest-commitment-A");
        let pool_root = h("pool-root-1");
        let spent_root = h("spent-root-1");
        let burn_root = h("burn-root-1");
        let height = 100u64;
        let tip = height + DEFAULT_CONFIRMATIONS_K;
        let claim_id =
            derive_claim_id_with_dest(&dest, &dest_cm, &nu, &tacit_asset, 1_000_000);
        let src_chain = h("src-bitcoin-mainnet");
        let dst_chain = dest;
        let lc_client = h("lc-client-reflection-0");
        let domain_binding = derive_domain_binding(
            &src_chain,
            &dst_chain,
            &lc_client,
            &tacit_asset,
            &nu,
            height,
            &burn_root,
        );

        let snapshot = ReflectionSnapshot {
            pool_root,
            spent_root,
            burn_root,
            source_height: height,
            tip_height: tip,
            confirmations_k: DEFAULT_CONFIRMATIONS_K,
            max_lc_lag: DEFAULT_MAX_LC_LAG,
            frozen: false,
        };

        let public = bridge_auth_seams::BridgeMintPublic {
            source_chain_tag: "bitcoin-mainnet".into(),
            tacit_asset_id: tacit_asset,
            value_u64: 1_000_000,
            nullifier: nu,
            dest_commitment: dest_cm,
            dest_domain: dest,
            claim_id,
            source_pool_root: pool_root,
            source_burn_root: burn_root,
            source_height: height,
            domain_binding,
            unit_scale,
            pool_domain: h("terp-pool-0"),
            cm_public: h("cm-leaf-dest-1"),
            // Round-2 hinge may carry rcm; compose still attaches openings for cm recompute.
            rcm: h("rcm-compose-1"),
        };

        let claim = BridgeMintClaim {
            public,
            mint_value: 1_000_000,
            expected_dest_domain: dest,
            src_chain_id: src_chain,
            dst_chain_id: dst_chain,
            lc_client_id: lc_client,
            burn_dest_commitment: dest_cm,
            in_burn_set: true,
            in_pool_root: true,
            spent_only: false,
        };

        let mut registry = AssetRegistryView::new();
        registry.register(AssetRecord {
            asset_id: terp_asset,
            tacit_id: Some(tacit_asset),
            denom: Some("utacitbtc".into()),
            origin: AssetOrigin::TacitLane,
            status: AssetStatus::Active,
        });
        // Hub asset for swap sketch (C4)
        registry.register(AssetRecord {
            asset_id: private_dex_seams::asset_id_hub(),
            tacit_id: None,
            denom: Some("uterp".into()),
            origin: AssetOrigin::Native,
            status: AssetStatus::Active,
        });

        let openings = NoteOpenings::with_rcm(h("rcm-compose-1"));

        (
            snapshot,
            claim,
            MintedSet::new(),
            registry,
            terp_asset,
            openings,
        )
    }

    /// C1 — Happy bridge mint → SeamNoteOutV0 with rcm_flag=1 / openings / DEX consumable.
    #[test]
    fn c1_happy_bridge_mint_to_seam_note_out() {
        let (snapshot, claim, mut minted, registry, terp_asset, openings) = compose_fixture();
        let note = authorize_bridge_mint_to_seam_note_out_apply(
            &snapshot,
            &claim,
            &mut minted,
            &registry,
            &openings,
        )
        .expect("C1 happy compose");

        assert_eq!(note.version, VERSION_V0);
        assert_eq!(note.origin, ORIGIN_BRIDGE_MINT);
        assert_eq!(note.nullifier_domain, NF_BRIDGE_BURN);
        assert_eq!(note.rcm_flag, 1);
        assert_eq!(note.rcm, openings.rcm);
        assert_ne!(note.rcm, [0u8; 32]);
        assert_eq!(note.asset_id, terp_asset);
        assert_eq!(note.value, 1_000_000);
        assert_eq!(note.provenance_anchor, snapshot.burn_root);
        assert_eq!(note.nullifier_lineage, claim.public.nullifier);
        assert_eq!(note.cm_encoding, CM_ABSTRACT_LEAF_V0);
        assert_eq!(
            note.cm_public,
            abstract_leaf_cm(&note.asset_id, note.value, &note.owner_binding, &note.rcm)
        );

        validate_seam_note_out_v0(&note).unwrap();
        assert!(is_dex_consumable(&note));
        let spend = to_dex_spend_inputs(&note).unwrap();
        assert_eq!(spend.rcm, Some(note.rcm));
        assert_eq!(spend.ingress_nullifier_lineage, note.nullifier_lineage);
        assert!(minted.contains(&claim.public.nullifier));
        assert_eq!(note.to_bytes().len(), 382);
    }

    /// C2 — H-1 spent-only still rejects; compose never bypasses hinge.
    #[test]
    fn c2_h1_spent_only_still_rejects() {
        let (snapshot, mut claim, minted, registry, _, openings) = compose_fixture();
        claim.in_burn_set = false;
        claim.spent_only = true;

        let err = authorize_bridge_mint_to_seam_note_out(
            &snapshot,
            &claim,
            &minted,
            &registry,
            &openings,
        )
        .expect_err("spent-only must reject");

        assert_eq!(err, ComposeError::Bridge(BridgeMintError::NotInBurnSet));

        // Direct hinge agrees
        let bridge_reg = registry.to_bridge_registry();
        assert_eq!(
            authorize_bridge_mint(&snapshot, &claim, &minted, &bridge_reg),
            Err(BridgeMintError::NotInBurnSet)
        );
    }

    /// C3 — Mint note asset_id from registry; unregistered asset rejects.
    #[test]
    fn c3_registry_asset_id_and_unregistered_reject() {
        let (snapshot, claim, minted, registry, terp_asset, openings) = compose_fixture();

        // Registered: asset on note equals registry Terp id.
        let note = authorize_bridge_mint_to_seam_note_out(
            &snapshot,
            &claim,
            &minted,
            &registry,
            &openings,
        )
        .expect("registered");
        assert_eq!(note.asset_id, terp_asset);
        assert!(registry.is_active(&note.asset_id));
        assert_eq!(
            registry.resolve_tacit(&claim.public.tacit_asset_id),
            Some(terp_asset)
        );

        // Empty registry → UnregisteredAsset at compose SSOT (before / instead of hinge).
        let empty = AssetRegistryView::new();
        let err = authorize_bridge_mint_to_seam_note_out(
            &snapshot,
            &claim,
            &minted,
            &empty,
            &openings,
        )
        .expect_err("unregistered");
        assert_eq!(err, ComposeError::UnregisteredAsset);

        // Registry with only hub (wrong asset) → reject.
        let mut wrong = AssetRegistryView::new();
        wrong.register(AssetRecord {
            asset_id: private_dex_seams::asset_id_hub(),
            tacit_id: None,
            denom: Some("uterp".into()),
            origin: AssetOrigin::Native,
            status: AssetStatus::Active,
        });
        let err2 = authorize_bridge_mint_to_seam_note_out(
            &snapshot,
            &claim,
            &minted,
            &wrong,
            &openings,
        )
        .expect_err("wrong asset");
        assert_eq!(err2, ComposeError::UnregisteredAsset);
    }

    /// C4 — Structural SwapActionV0 from mint note(s) + pool reserves.
    #[test]
    fn c4_sketch_swap_action_from_two_notes_and_pool() {
        let (snapshot, mut claim, mut minted, registry, terp_asset, openings) = compose_fixture();

        // Note 1: full value mint
        let note1 = authorize_bridge_mint_to_seam_note_out_apply(
            &snapshot,
            &claim,
            &mut minted,
            &registry,
            &openings,
        )
        .expect("mint1");

        // Note 2: second mint with different ν (same asset)
        let nu2 = h("nu-compose-second");
        claim.public.nullifier = nu2;
        claim.public.claim_id = derive_claim_id_with_dest(
            &claim.public.dest_domain,
            &claim.public.dest_commitment,
            &nu2,
            &claim.public.tacit_asset_id,
            claim.public.value_u64,
        );
        claim.public.domain_binding = derive_domain_binding(
            &claim.src_chain_id,
            &claim.dst_chain_id,
            &claim.lc_client_id,
            &claim.public.tacit_asset_id,
            &nu2,
            claim.public.source_height,
            &claim.public.source_burn_root,
        );
        let openings2 = NoteOpenings::with_rcm(h("rcm-compose-2"));
        let note2 = authorize_bridge_mint_to_seam_note_out_apply(
            &snapshot,
            &claim,
            &mut minted,
            &registry,
            &openings2,
        )
        .expect("mint2");

        assert_eq!(note1.asset_id, terp_asset);
        assert_eq!(note2.asset_id, terp_asset);

        // Spend both notes into hub pool: delta_in = sum of both values
        let sum = note1.value as u128 + note2.value as u128;
        let asset_out = private_dex_seams::asset_id_hub();
        let r_in = 10_000_000u128;
        let r_out = 5_000_000u128;
        let gamma = 997u64;
        let gamma_den = 1000u64;
        let expected_out = quote_exact_in(r_in, r_out, sum, gamma, gamma_den).unwrap();

        let params = SwapFromSeamParams {
            pool_id: 1,
            asset_in: terp_asset,
            asset_out,
            r_in_before: r_in,
            r_out_before: r_out,
            gamma,
            gamma_den,
            min_out: expected_out,
            root: h("shared-tree-root-T"),
            delta_in: Some(sum),
            out_owner: h("swap-out-owner"),
            out_rcm: h("swap-out-rcm"),
            change_rcm: None,
            now_height: 200,
            oracle_mid: None,
            oracle_params: None,
        };

        let action = sketch_swap_action_from_seam_notes(
            &[note1, note2],
            &registry,
            &params,
            0,
        )
        .expect("swap sketch");

        assert_eq!(action.public.asset_in, terp_asset);
        assert_eq!(action.public.asset_out, asset_out);
        assert_eq!(action.public.delta_r_in, sum);
        assert_eq!(action.public.delta_r_out, expected_out);
        assert_eq!(action.witness.notes_in.len(), 2);
        assert_eq!(action.public.nullifiers.len(), 2);
        assert!(action.witness.note_change.is_none());

        // Pool-spend ν ≠ ingress lineage (NE-4)
        for (opening, pub_nf) in action
            .witness
            .notes_in
            .iter()
            .zip(action.public.nullifiers.iter())
        {
            assert_ne!(*pub_nf, opening.ingress_nullifier_lineage);
            assert_eq!(
                *pub_nf,
                synthetic_pool_spend_nf(&opening.cm_public, &opening.rcm)
            );
        }

        // Structural validate (no prove) — also already run inside build_swap_action
        let delta = validate_swap_action(&action).expect("validate_swap_action");
        assert_eq!(delta, expected_out);
    }

    #[test]
    fn registry_never_mints_only_resolves() {
        // Documentation invariant: AssetRegistryView has no mint / credit API.
        let mut reg = AssetRegistryView::new();
        let id = h("asset-x");
        reg.register(AssetRecord {
            asset_id: id,
            tacit_id: Some(h("tacit-x")),
            denom: Some("ux".into()),
            origin: AssetOrigin::TacitLane,
            status: AssetStatus::Active,
        });
        assert_eq!(reg.resolve_tacit(&h("tacit-x")), Some(id));
        assert_eq!(reg.resolve_denom("ux"), Some(id));
        // No balance field exists on AssetRecord — resolve only.
    }

    #[test]
    fn zero_rcm_openings_reject() {
        let (snapshot, mut claim, minted, registry, _, _) = compose_fixture();
        // Hinge also emits zero rcm → no openings source → MissingOpenings
        claim.public.rcm = [0u8; 32];
        let bad = NoteOpenings {
            rcm: [0u8; 32],
            recompute_abstract_cm: true,
        };
        let err =
            authorize_bridge_mint_to_seam_note_out(&snapshot, &claim, &minted, &registry, &bad)
                .unwrap_err();
        assert_eq!(err, ComposeError::MissingOpenings);
    }

    /// When hinge already has rcm, zero openings still succeed via sketch path.
    #[test]
    fn hinge_rcm_without_openings_ok() {
        let (snapshot, claim, minted, registry, _, _) = compose_fixture();
        assert_ne!(claim.public.rcm, [0u8; 32]);
        let openings = NoteOpenings {
            rcm: [0u8; 32],
            recompute_abstract_cm: true,
        };
        let note = authorize_bridge_mint_to_seam_note_out(
            &snapshot,
            &claim,
            &minted,
            &registry,
            &openings,
        )
        .expect("sketch rcm sufficient");
        assert_eq!(note.rcm, claim.public.rcm);
        assert_eq!(note.rcm_flag, 1);
        assert!(is_dex_consumable(&note));
    }

    /// Bridge mint → SEAM note → encrypt persist plan (cm. addr); no HTTP.
    #[test]
    fn bridge_mint_persist_plan_roundtrip() {
        let (snapshot, claim, minted, registry, _, openings) = compose_fixture();
        let note = authorize_bridge_mint_to_seam_note_out(
            &snapshot,
            &claim,
            &minted,
            &registry,
            &openings,
        )
        .expect("mint note");
        let key = h("note-persist-key");
        let plan = persist_plan_after_bridge_mint(&note, &key, "season-demo", None)
            .expect("persist plan");
        assert!(plan.addr.starts_with("cm."));
        assert_eq!(plan.store_path, format!("notes/season-demo/{}", plan.addr));
        assert_eq!(plan.envelope.scheme, SCHEME_XCHACHA20POLY1305);
        assert_eq!(plan.envelope.cleartext_len, 382);
        let recovered = decrypt_note_out(&plan.envelope, &key).unwrap();
        assert_eq!(recovered, note);
    }

    /// **Product pure E2E** — register → burn-auth mint note → SwapActionV0 →
    /// apply_swap_action; assert reserves + nullifiers.
    ///
    /// Run: `cargo test -p compose_seams product_path_burn_to_swap_sketch`
    /// (or `cd docs/plans/spectrum/fixtures/compose_seams && cargo test product_path`).
    #[test]
    fn product_path_burn_to_swap_sketch() {
        let out = run_product_path_burn_to_swap_sketch().expect("product pure e2e");

        assert_eq!(out.notes_in, 1);
        assert_eq!(out.bridge_minted_nullifiers.len(), 1);
        assert_eq!(out.pool_nullifiers.len(), 1);
        assert_ne!(out.pool_nullifiers[0], out.bridge_minted_nullifiers[0]);
        assert_eq!(out.asset_out, private_dex_seams::asset_id_hub());
        assert_eq!(out.delta_in, 1_000_000);
        assert_eq!(out.r_in_after, out.r_in_before + out.delta_in);
        assert_eq!(out.r_out_after, out.r_out_before - out.delta_out);
        assert!(out.delta_out > 0);
        assert!(out.r_out_after > 0);
    }

    /// G2 T3/T4: burn → mint SEAM → oracle-required + ZEC asset_out → apply.
    #[test]
    fn product_path_burn_to_swap_oracle_zec() {
        let out = run_product_path_burn_to_swap_oracle_zec().expect("oracle+zec product path");
        let base = &out.base;
        assert_eq!(base.notes_in, 1);
        assert_eq!(base.pool_nullifiers.len(), 1);
        assert_ne!(base.pool_nullifiers[0], base.bridge_minted_nullifiers[0]);
        assert_eq!(base.asset_out, h("sim-ZEC"));
        assert_ne!(base.asset_out, private_dex_seams::asset_id_hub());
        assert_eq!(out.action.witness.notes_in[0].cm_public, out.mint_note.cm_public);
        assert_eq!(out.action.witness.notes_in[0].rcm, out.mint_note.rcm);
        let opening = &out.action.witness.notes_in[0];
        let pool_nf = synthetic_pool_spend_nf(&opening.cm_public, &opening.rcm);
        assert_eq!(out.action.public.nullifiers[0], pool_nf);
        assert_ne!(pool_nf, opening.ingress_nullifier_lineage);
        assert_ne!(pool_nf, out.mint_note.nullifier_lineage);
        assert_eq!(
            out.action.public.oracle_params.as_ref().map(|p| p.require_oracle),
            Some(true)
        );
        // Statement map widths (G3 collab T8 pure half)
        assert_eq!(out.statement.asset_in.len(), 32);
        assert_eq!(out.statement.asset_out.len(), 32);
        assert_eq!(out.statement.root.len(), 32);
        assert_eq!(out.statement.nullifiers[0].len(), 32);
        assert_eq!(out.statement.cm_out[0].len(), 32);
        assert_eq!(out.statement.asset_out, h("sim-ZEC").to_vec());
        assert!(out.statement.oracle_mid.is_some());
        assert_eq!(base.r_in_after, base.r_in_before + base.delta_in);
        assert_eq!(base.r_out_after, base.r_out_before - base.delta_out);
    }

    /// G2 T5: missing rcm → NotDexConsumable / MissingOpenings.
    #[test]
    fn mint_evidence_rejects_missing_rcm() {
        let (snapshot, mut claim, minted, registry, _, _) = compose_fixture();
        claim.public.rcm = [0u8; 32];
        let openings = NoteOpenings {
            rcm: [0u8; 32],
            recompute_abstract_cm: true,
        };
        let err = authorize_bridge_mint_to_seam_note_out(
            &snapshot,
            &claim,
            &minted,
            &registry,
            &openings,
        )
        .unwrap_err();
        assert_eq!(err, ComposeError::MissingOpenings);

        // Sketch path with rcm_flag=0
        let sketch = hinge_authorize_bridge_mint(
            &snapshot,
            &claim,
            &minted,
            &registry.to_bridge_registry(),
        )
        .expect("hinge ok without rcm");
        assert_eq!(sketch.rcm_flag, 0);
        let err = MintSpendEvidence::from_note_out_sketch(&sketch, 0).unwrap_err();
        assert_eq!(err, ComposeError::MissingOpenings);
    }

    /// G2 T5: wrong asset_in vs note → ErrWrongAsset.
    #[test]
    fn seam_note_out_to_swap_action_wrong_asset() {
        let (snapshot, claim, mut minted, registry, terp, openings) = compose_fixture();
        let note = authorize_bridge_mint_to_seam_note_out_apply(
            &snapshot,
            &claim,
            &mut minted,
            &registry,
            &openings,
        )
        .expect("mint");
        let zec = h("sim-ZEC");
        let mut reg = registry.clone();
        reg.register(AssetRecord {
            asset_id: zec,
            tacit_id: None,
            denom: Some("sim-zec".into()),
            origin: AssetOrigin::Native,
            status: AssetStatus::Active,
        });
        let wrong_in = h("not-the-note-asset");
        reg.register(AssetRecord {
            asset_id: wrong_in,
            tacit_id: None,
            denom: Some("wrong".into()),
            origin: AssetOrigin::Native,
            status: AssetStatus::Active,
        });
        let params = CorridorSwapSpendParams {
            pool_id: 1,
            asset_in: wrong_in,
            asset_out: zec,
            r_in_before: 10_000_000,
            r_out_before: 5_000_000,
            gamma: 997,
            gamma_den: 1000,
            min_out: 1,
            root: h("root"),
            delta_in: Some(note.value as u128),
            out_owner: note.owner_binding,
            out_rcm: h("out-rcm"),
            change_rcm: None,
            now_height: 200,
            oracle_mid: OracleMid {
                pair_key: "BTC-ZEC".into(),
                mid: PRICE_SCALE,
                observed_height: 100,
            },
            oracle_params: OracleBoundParams {
                max_age_blocks: 1000,
                max_slippage_bps: 9_999,
                require_oracle: true,
            },
        };
        let err = seam_note_out_to_swap_action(&note, &params, &reg, 0).unwrap_err();
        assert_eq!(err, ComposeError::Swap(SwapActionError::ErrWrongAsset));
        assert_eq!(note.asset_id, terp);
    }

    /// G2 T5: product path rejects require_oracle=false.
    #[test]
    fn corridor_params_require_oracle() {
        let params = CorridorSwapSpendParams {
            pool_id: 1,
            asset_in: h("a"),
            asset_out: h("b"),
            r_in_before: 1,
            r_out_before: 1,
            gamma: 997,
            gamma_den: 1000,
            min_out: 1,
            root: h("r"),
            delta_in: None,
            out_owner: h("o"),
            out_rcm: h("rcm"),
            change_rcm: None,
            now_height: 1,
            oracle_mid: OracleMid {
                pair_key: "x".into(),
                mid: 1,
                observed_height: 0,
            },
            oracle_params: OracleBoundParams {
                max_age_blocks: 10,
                max_slippage_bps: 100,
                require_oracle: false,
            },
        };
        let err = params.to_swap_from_seam().unwrap_err();
        assert_eq!(err, ComposeError::Swap(SwapActionError::ErrOracleMissing));
    }

    /// G2 T6: oracle_mint_note still hard-reject (bound_only).
    #[test]
    fn oracle_mint_note_still_disabled() {
        let mid = OracleMid {
            pair_key: "BTC-ZEC".into(),
            mid: PRICE_SCALE,
            observed_height: 1,
        };
        let err = oracle_mint_note(&mid, DexPoolAssetId::Hub, 1).unwrap_err();
        assert_eq!(err, private_dex_seams::SeamError::ErrOracleDisabledMint);
    }

    /// Openings-only helper + evidence → action identity.
    #[test]
    fn mint_evidence_to_openings_and_action() {
        let (snapshot, claim, mut minted, mut registry, terp, openings) = compose_fixture();
        let note = authorize_bridge_mint_to_seam_note_out_apply(
            &snapshot,
            &claim,
            &mut minted,
            &registry,
            &openings,
        )
        .expect("mint");
        let zec = h("sim-ZEC");
        registry.register(AssetRecord {
            asset_id: zec,
            tacit_id: None,
            denom: Some("sim-zec".into()),
            origin: AssetOrigin::Native,
            status: AssetStatus::Active,
        });
        let evidence = MintSpendEvidence::from_seam_note(note.clone(), 7).expect("evidence");
        assert_eq!(evidence.bridge_nullifier, note.nullifier_lineage);
        let open = seam_note_out_to_swap_openings(&note, 7).expect("openings");
        assert_eq!(open.cm_public, note.cm_public);
        assert_eq!(open.rcm, note.rcm);
        assert_eq!(open.path_position, 7);

        let delta_in = note.value as u128;
        let r_in = 10_000_000u128;
        let r_out = 5_000_000u128;
        let expected = quote_exact_in(r_in, r_out, delta_in, 997, 1000).unwrap();
        let mid = implied_price(delta_in, expected).unwrap();
        let params = CorridorSwapSpendParams {
            pool_id: 1,
            asset_in: terp,
            asset_out: zec,
            r_in_before: r_in,
            r_out_before: r_out,
            gamma: 997,
            gamma_den: 1000,
            min_out: expected,
            root: h("root-ev"),
            delta_in: Some(delta_in),
            out_owner: note.owner_binding,
            out_rcm: h("out-rcm-ev"),
            change_rcm: None,
            now_height: 200,
            oracle_mid: OracleMid {
                pair_key: "BTC-ZEC".into(),
                mid,
                observed_height: 100,
            },
            oracle_params: OracleBoundParams {
                max_age_blocks: 1000,
                max_slippage_bps: 500,
                require_oracle: true,
            },
        };
        let action = mint_evidence_to_swap_action(&evidence, &params, &registry).expect("action");
        assert_eq!(action.witness.notes_in[0], open);
        let stmt = swap_action_public_to_statement(&action.public);
        assert_eq!(stmt.pool_id, 1);
        assert_eq!(stmt.delta_r_out, expected);
    }
}
