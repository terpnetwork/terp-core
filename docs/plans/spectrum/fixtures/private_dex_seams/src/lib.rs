//! Pure (no halo2 / MockProver) seam math for private multi-pair DEX.
//!
//! Implements SPEC-private-dex-seams.md:
//! - constant-product fee-aware swap
//! - apply_swap reserve updates + nullifier set
//! - oracle bound checks (staleness / slippage)
//! - hard reject: oracle cannot mint balances
//! - SEAM-NOTE-OUT-aligned SwapActionV0 structural types (v1 single-leg)
//! - ROUND2: SEAM sketch → SwapAction compose + AssetMap registry view
//! - Option D pure egress: `egress` module (`EGRESS_NF_LABEL`, validate/apply burn)

#![deny(unsafe_code)]

mod egress;

pub use egress::{
    apply_egress_burn, build_egress_burn_from_settle, egress_nullifier, hex32,
    lab_receipt_after_burn, settle_opening_from_note_fields, synthetic_deposit_nu,
    validate_egress_burn, DestKind, EgressBurnEvidenceV0, EgressBurnPublic, EgressBurnV0,
    EgressBurnWitness, EgressError, EgressResult, EgressSeamState, SettleLikeOpening,
    ZecEgressReceiptV0, DEPOSIT_NU_LABEL, EGRESS_NF_LABEL,
};

use std::collections::{HashMap, HashSet};

use sha2::{Digest, Sha256};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Logical asset identifier (domain-separated in production; enum for pure tests).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AssetId {
    Hub,
    AssetB,
    AssetC,
    AssetX,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PoolStatus {
    Active,
    Paused,
}

/// Public virtual pool state (SPEC §2.1).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pool {
    pub pool_id: u64,
    pub asset_a: AssetId,
    pub asset_b: AssetId,
    pub r_a: u128,
    pub r_b: u128,
    pub gamma: u64,
    pub gamma_den: u64,
    pub status: PoolStatus,
}

/// Oracle mid snapshot used only as acceptance bounds (SPEC §3.3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OracleMid {
    pub pair_key: String,
    /// Fixed-point mid price (scale = `PRICE_SCALE`).
    pub mid: u128,
    pub observed_height: u64,
}

/// Oracle bound parameters (SPEC §3.3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OracleBoundParams {
    pub max_age_blocks: u64,
    pub max_slippage_bps: u32,
    pub require_oracle: bool,
}

/// Price fixed-point scale: mid and implied prices are `amount_in * PRICE_SCALE / amount_out`
/// in asset_in per asset_out units (or vice-versa consistently).
pub const PRICE_SCALE: u128 = 1_000_000_000_000_000_000; // 1e18

/// Normative error codes (SPEC §2.4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SeamError {
    ErrMinOut,
    ErrOracleStale,
    ErrOracleSlippage,
    ErrOracleDisabledMint,
    ErrNullifierExists,
    ErrWrongAsset,
    ErrPoolPaused,
    ErrInsufficientReserve,
    ErrBadAmount,
    ErrOracleMissing,
}

pub type SeamResult<T> = Result<T, SeamError>;

/// Minimal spend note for pure seam tests (no commitments/crypto).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteIn {
    pub asset_id: AssetId,
    pub value: u128,
    pub nullifier: u64,
}

/// Public swap inputs relevant to pure host recompute (SPEC §1.2 / §2.4).
#[derive(Clone, Debug)]
pub struct SwapPublic {
    pub asset_in: AssetId,
    pub asset_out: AssetId,
    pub delta_in: u128,
    pub min_out: u128,
    pub nullifiers: Vec<u64>,
    /// Optional oracle mid; required when `oracle_params.require_oracle`.
    pub oracle_mid: Option<OracleMid>,
    pub oracle_params: Option<OracleBoundParams>,
    /// Local chain height for staleness.
    pub now_height: u64,
}

/// Host-side nullifier set + optional note tree leaf counter (stubs).
#[derive(Clone, Debug, Default)]
pub struct SeamState {
    pub nullifiers: HashSet<u64>,
    pub tree_leaves: u64,
}

// ---------------------------------------------------------------------------
// Swap math (SPEC §2.2)
// ---------------------------------------------------------------------------

/// Constant-product fee-aware exact-in quote:
///
/// ```text
/// Δ_out = floor(R_out * γ * Δ_in / (R_in * γ_den + γ * Δ_in))
/// ```
///
/// Returns `ErrInsufficientReserve` if output would empty the reserve leg,
/// `ErrBadAmount` if inputs are zero / pool inactive / fee den zero.
pub fn quote_exact_in(
    r_in: u128,
    r_out: u128,
    delta_in: u128,
    gamma: u64,
    gamma_den: u64,
) -> SeamResult<u128> {
    if delta_in == 0 || r_in == 0 || r_out == 0 || gamma_den == 0 {
        return Err(SeamError::ErrBadAmount);
    }
    let g = gamma as u128;
    let gd = gamma_den as u128;

    // numerator = R_out * γ * Δ_in
    // denominator = R_in * γ_den + γ * Δ_in
    let num = r_out
        .checked_mul(g)
        .and_then(|x| x.checked_mul(delta_in))
        .ok_or(SeamError::ErrBadAmount)?;
    let fee_in = g.checked_mul(delta_in).ok_or(SeamError::ErrBadAmount)?;
    let den = r_in
        .checked_mul(gd)
        .and_then(|x| x.checked_add(fee_in))
        .ok_or(SeamError::ErrBadAmount)?;
    if den == 0 {
        return Err(SeamError::ErrBadAmount);
    }
    let delta_out = num / den;
    if delta_out == 0 {
        return Err(SeamError::ErrBadAmount);
    }
    if delta_out >= r_out {
        return Err(SeamError::ErrInsufficientReserve);
    }
    Ok(delta_out)
}

/// Apply reserves after a successful A→B (or oriented) swap:
/// `R_in += Δ_in`, `R_out -= Δ_out`. Requires `R_out' > 0`.
pub fn apply_reserves(
    r_in: u128,
    r_out: u128,
    delta_in: u128,
    delta_out: u128,
) -> SeamResult<(u128, u128)> {
    let r_in2 = r_in
        .checked_add(delta_in)
        .ok_or(SeamError::ErrBadAmount)?;
    if delta_out >= r_out {
        return Err(SeamError::ErrInsufficientReserve);
    }
    let r_out2 = r_out - delta_out;
    if r_out2 == 0 {
        return Err(SeamError::ErrInsufficientReserve);
    }
    Ok((r_in2, r_out2))
}

// ---------------------------------------------------------------------------
// Oracle bounds (SPEC §3)
// ---------------------------------------------------------------------------

/// True if mid is fresh vs local height and `max_age_blocks`.
pub fn is_fresh(mid: &OracleMid, now_height: u64, max_age_blocks: u64) -> bool {
    now_height
        .checked_sub(mid.observed_height)
        .map(|age| age <= max_age_blocks)
        .unwrap_or(false)
}

/// Implied price as `Δ_in * PRICE_SCALE / Δ_out` (in-per-out scaled).
pub fn implied_price(delta_in: u128, delta_out: u128) -> SeamResult<u128> {
    if delta_out == 0 {
        return Err(SeamError::ErrBadAmount);
    }
    delta_in
        .checked_mul(PRICE_SCALE)
        .map(|n| n / delta_out)
        .ok_or(SeamError::ErrBadAmount)
}

/// `implied ∈ [mid*(1-s), mid*(1+s)]` with `s = max_slippage_bps / 10_000`.
pub fn within_slippage(implied: u128, mid: u128, max_slippage_bps: u32) -> bool {
    if mid == 0 {
        return false;
    }
    let bps = max_slippage_bps as u128;
    // low = mid * (10000 - bps) / 10000
    // high = mid * (10000 + bps) / 10000
    let low = mid.saturating_mul(10_000u128.saturating_sub(bps)) / 10_000;
    let high = mid
        .checked_mul(10_000u128.saturating_add(bps))
        .map(|x| x / 10_000)
        .unwrap_or(u128::MAX);
    implied >= low && implied <= high
}

/// Pure oracle bound predicate for swap acceptance when oracle path is configured.
pub fn check_oracle_bound(
    mid: Option<&OracleMid>,
    params: &OracleBoundParams,
    now_height: u64,
    delta_in: u128,
    delta_out: u128,
) -> SeamResult<()> {
    match mid {
        None => {
            if params.require_oracle {
                Err(SeamError::ErrOracleMissing)
            } else {
                Ok(())
            }
        }
        Some(m) => {
            if !is_fresh(m, now_height, params.max_age_blocks) {
                if params.require_oracle {
                    return Err(SeamError::ErrOracleStale);
                }
                // SPEC §3.4: require_oracle=false + stale → MAY allow pure AMM
                return Ok(());
            }
            let implied = implied_price(delta_in, delta_out)?;
            if !within_slippage(implied, m.mid, params.max_slippage_bps) {
                return Err(SeamError::ErrOracleSlippage);
            }
            Ok(())
        }
    }
}

/// Hard rule: any API that would credit a note/balance from oracle mid alone is rejected.
///
/// There is intentionally no successful path — oracle mids are bounds only (SPEC §3.1, §3.5).
pub fn oracle_mint_note(_mid: &OracleMid, _asset: AssetId, _amount: u128) -> SeamResult<()> {
    Err(SeamError::ErrOracleDisabledMint)
}

/// Hard rule: oracle cannot bump pool reserves without a proven swap.
pub fn oracle_update_reserves(_mid: &OracleMid, _pool: &mut Pool) -> SeamResult<()> {
    Err(SeamError::ErrOracleDisabledMint)
}

// ---------------------------------------------------------------------------
// apply_swap seam (pure host recompute; no ZK)
// ---------------------------------------------------------------------------

fn orient_reserves(pool: &Pool, asset_in: AssetId, asset_out: AssetId) -> SeamResult<(u128, u128)> {
    if pool.asset_a == asset_in && pool.asset_b == asset_out {
        Ok((pool.r_a, pool.r_b))
    } else if pool.asset_b == asset_in && pool.asset_a == asset_out {
        Ok((pool.r_b, pool.r_a))
    } else {
        Err(SeamError::ErrWrongAsset)
    }
}

fn write_reserves(pool: &mut Pool, asset_in: AssetId, asset_out: AssetId, r_in: u128, r_out: u128) {
    if pool.asset_a == asset_in && pool.asset_b == asset_out {
        pool.r_a = r_in;
        pool.r_b = r_out;
    } else {
        pool.r_b = r_in;
        pool.r_a = r_out;
    }
}

/// Pure `apply_swap` host seam (SPEC §2.4 steps 1–5 without ZK verify).
///
/// - checks pool Active
/// - validates note asset_ids match `asset_in`
/// - rejects reused nullifiers
/// - recomputes `Δ_out` from reserves; enforces `min_out`
/// - optional oracle bound
/// - updates reserves, inserts nullifiers, appends a stub leaf
pub fn apply_swap(
    pool: &mut Pool,
    state: &mut SeamState,
    notes_in: &[NoteIn],
    public: &SwapPublic,
) -> SeamResult<u128> {
    if pool.status != PoolStatus::Active {
        return Err(SeamError::ErrPoolPaused);
    }

    // Asset orientation must match pool legs
    let (r_in, r_out) = orient_reserves(pool, public.asset_in, public.asset_out)?;

    // Notes must be the correct input asset and cover Δ_in (simple conservation)
    let mut sum_in: u128 = 0;
    for n in notes_in {
        if n.asset_id != public.asset_in {
            return Err(SeamError::ErrWrongAsset);
        }
        sum_in = sum_in.checked_add(n.value).ok_or(SeamError::ErrBadAmount)?;
    }
    if sum_in < public.delta_in {
        return Err(SeamError::ErrBadAmount);
    }

    // Nullifiers: public list must match notes; none already spent
    if public.nullifiers.len() != notes_in.len() {
        return Err(SeamError::ErrBadAmount);
    }
    for (n, &nu) in notes_in.iter().zip(public.nullifiers.iter()) {
        if n.nullifier != nu {
            return Err(SeamError::ErrBadAmount);
        }
        if state.nullifiers.contains(&nu) {
            return Err(SeamError::ErrNullifierExists);
        }
    }

    let delta_out = quote_exact_in(r_in, r_out, public.delta_in, pool.gamma, pool.gamma_den)?;
    if delta_out < public.min_out {
        return Err(SeamError::ErrMinOut);
    }

    if let Some(ref params) = public.oracle_params {
        check_oracle_bound(
            public.oracle_mid.as_ref(),
            params,
            public.now_height,
            public.delta_in,
            delta_out,
        )?;
    }

    let (r_in2, r_out2) = apply_reserves(r_in, r_out, public.delta_in, delta_out)?;
    write_reserves(pool, public.asset_in, public.asset_out, r_in2, r_out2);

    for &nu in &public.nullifiers {
        state.nullifiers.insert(nu);
    }
    // note_out (+ optional change) → tree leaves
    state.tree_leaves += 1;
    if sum_in > public.delta_in {
        state.tree_leaves += 1; // change note
    }

    Ok(delta_out)
}

// ---------------------------------------------------------------------------
// SwapActionV0 — structural SEAM-SPEND fixture (SEAM-NOTE-OUT field widths)
// ---------------------------------------------------------------------------
//
// Round-1 design freeze: public / private I/O for a v1 single-leg private swap
// without Halo2. Field roles match SPEC-private-dex-seams §1.2 and SEAM-NOTE-OUT
// §4 (egress → spend). Pool-spend nullifiers are **derived**, never equal to
// ingress `nullifier_lineage` (claim nf / bridge burn ν).

/// Terp-canonical 32-byte asset id (SEAM-NOTE-OUT width).
pub type AssetId32 = [u8; 32];

/// Merkle root / commitment fingerprint (32-byte public form).
pub type Cm32 = [u8; 32];

/// Pool-spend nullifier (32-byte; domain ≠ claim/bridge lineage).
pub type PoolNullifier32 = [u8; 32];

/// Private opening of a spent note (witness). Paths are stubs in pure v1.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpendNoteOpening {
    pub asset_id: AssetId32,
    pub value: u64,
    pub cm_public: Cm32,
    pub owner_binding: [u8; 32],
    pub rcm: [u8; 32],
    /// Ingress marker from SEAM-NOTE-OUT — **not** the pool-spend ν.
    pub ingress_nullifier_lineage: [u8; 32],
    /// Stub leaf position for membership narrative (no crypto path).
    pub path_position: u64,
}

/// Private output note stub (created by swap).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutputNoteStub {
    pub asset_id: AssetId32,
    pub value: u64,
    pub cm_public: Cm32,
    pub owner_binding: [u8; 32],
    pub rcm: [u8; 32],
}

/// Public statement for a v1 single-leg swap action (SPEC §1.2).
///
/// Posture (honest): pair / pool_id, reserve deltas, nullifiers, new cms are
/// public; per-note openings and who traded remain private under a future proof.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SwapActionPublic {
    pub pool_id: u64,
    pub asset_in: AssetId32,
    pub asset_out: AssetId32,
    /// Commitment tree root used for membership (shared anonymity set T).
    pub root: Cm32,
    /// Pool-spend nullifiers (one per spent note).
    pub nullifiers: Vec<PoolNullifier32>,
    /// New leaf commitments: note_out, then optional change.
    pub cm_out: Vec<Cm32>,
    /// Public Δ applied to reserves: R_in += Δ_in, R_out -= Δ_out.
    pub delta_r_in: u128,
    pub delta_r_out: u128,
    pub min_out: u128,
    pub gamma: u64,
    pub gamma_den: u64,
    /// Pre-trade public reserves (host loads from Pool; fixed in statement for determinism).
    pub r_in_before: u128,
    pub r_out_before: u128,
    pub oracle_mid: Option<OracleMid>,
    pub oracle_params: Option<OracleBoundParams>,
    pub now_height: u64,
}

/// Private witnesses for the same action.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SwapActionWitness {
    pub notes_in: Vec<SpendNoteOpening>,
    pub note_out: OutputNoteStub,
    pub note_change: Option<OutputNoteStub>,
    /// Cleartext amount paid into the curve (may be < sum notes_in).
    pub delta_in: u128,
}

/// Full structural action: public + private halves (circuit I/O sketch).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SwapActionV0 {
    pub public: SwapActionPublic,
    pub witness: SwapActionWitness,
}

/// Host-side nullifier set for 32-byte pool nullifiers + tree leaf counter.
#[derive(Clone, Debug, Default)]
pub struct SwapSeamState {
    pub nullifiers: HashSet<PoolNullifier32>,
    pub tree_leaves: u64,
    /// Last accepted root (stub: single demo root window).
    pub allowed_root: Option<Cm32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SwapActionError {
    ErrMinOut,
    ErrOracleStale,
    ErrOracleSlippage,
    ErrOracleMissing,
    ErrNullifierExists,
    ErrWrongAsset,
    ErrInsufficientReserve,
    ErrBadAmount,
    ErrBadRoot,
    ErrSchema,
    /// Pool-spend ν must not equal ingress lineage (SEAM-NOTE-OUT §4.2 / NE-4).
    ErrNullifierDomain,
    /// Host-recomputed Δ_out ≠ public delta_r_out (conservation / curve).
    ErrCurveMismatch,
    ErrConservation,
    /// Note is not DEX-consumable (SEAM §4.3): missing rcm / bad encoding / invalid shape.
    ErrNotDexConsumable,
    /// Asset id not present in registry view / AssetMap.
    ErrUnregisteredAsset,
}

pub type SwapActionResult<T> = Result<T, SwapActionError>;

/// Domain tag for abstract harness leaves (SEAM-NOTE-OUT `cm_encoding = 0x03`).
pub const ABSTRACT_LEAF_LABEL: &[u8] = b"terp-seam-leaf-v0";

/// Domain tag for synthetic pool-spend nullifiers (not Orchard DeriveNullifier).
pub const POOL_NF_LABEL: &[u8] = b"pool-nf-v0";

/// Demo asset bytes for hub / B / C (deterministic **test helpers only**).
///
/// Prefer resolving 32-byte ids through [`AssetMap`] / [`AssetRegistryView`]
/// in product paths (CLARITY asset registry; registry-resolved notes from
/// cw-headstash mint later). These helpers remain for legacy pure fixtures.
pub fn asset_id_hub() -> AssetId32 {
    let mut a = [0u8; 32];
    a[0] = b'H';
    a[1] = b'U';
    a[2] = b'B';
    a
}

pub fn asset_id_b() -> AssetId32 {
    let mut a = [0u8; 32];
    a[0] = b'B';
    a
}

pub fn asset_id_c() -> AssetId32 {
    let mut a = [0u8; 32];
    a[0] = b'C';
    a
}

// ---------------------------------------------------------------------------
// Asset registry view (CLARITY §2 / ROUND2-SWAP)
// ---------------------------------------------------------------------------
//
// Pure stub of the registry surface used by hinge + swap + (later) cw-headstash.
// Never mints balances — only resolves / admits 32-byte Terp asset ids.

/// Read-only registry view: is this 32-byte id admitted for product paths?
pub trait AssetRegistryView {
    fn is_registered(&self, asset_id: &AssetId32) -> bool;
}

/// Simple in-memory asset map (fixture SSOT for pure compose).
///
/// Keys are Terp-canonical 32-byte `asset_id`s. Optional human labels map into
/// the same width for demo convenience; production maps claim/bridge foreign
/// ids through domain-separated hashes into these entries.
#[derive(Clone, Debug, Default)]
pub struct AssetMap {
    registered: HashSet<AssetId32>,
    /// Optional label → asset_id (tests / demos only).
    labels: HashMap<String, AssetId32>,
}

impl AssetMap {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a Terp-canonical 32-byte asset id (no mint side-effects).
    pub fn register(&mut self, asset_id: AssetId32) {
        self.registered.insert(asset_id);
    }

    /// Register with a demo label (e.g. `"hub"`, `"b"`).
    pub fn register_labeled(&mut self, label: impl Into<String>, asset_id: AssetId32) {
        self.registered.insert(asset_id);
        self.labels.insert(label.into(), asset_id);
    }

    pub fn resolve_label(&self, label: &str) -> Option<AssetId32> {
        self.labels.get(label).copied()
    }

    pub fn require(&self, asset_id: &AssetId32) -> SwapActionResult<AssetId32> {
        if self.is_registered(asset_id) {
            Ok(*asset_id)
        } else {
            Err(SwapActionError::ErrUnregisteredAsset)
        }
    }

    /// Demo map: hub / B / C helpers registered under labels.
    ///
    /// Not the sole product path — only a fixture seed matching ROUND1 tests.
    pub fn demo_hub_b_c() -> Self {
        let mut m = Self::new();
        m.register_labeled("hub", asset_id_hub());
        m.register_labeled("b", asset_id_b());
        m.register_labeled("c", asset_id_c());
        m
    }
}

impl AssetRegistryView for AssetMap {
    fn is_registered(&self, asset_id: &AssetId32) -> bool {
        self.registered.contains(asset_id)
    }
}

// ---------------------------------------------------------------------------
// SEAM-NOTE-OUT → SwapActionV0 pure compose (ROUND2-SWAP)
// ---------------------------------------------------------------------------

/// SEAM-NOTE-OUT cm_encoding codes (mirrored; see SEAM-NOTE-OUT §1.2).
pub const CM_ORCHARD_CMX: u8 = 0x01;
pub const CM_TACIT_KECCAK_LEAF: u8 = 0x02;
pub const CM_ABSTRACT_LEAF_V0: u8 = 0x03;
pub const CM_UNSPECIFIED: u8 = 0x00;

/// SEAM-shaped note sketch consumed by DEX pure compose.
///
/// Field roles match SEAM-NOTE-OUT §1.1 / §4.2 (spend subset). Full
/// `SeamNoteOutV0` serialization lives in `seam_note_out`; this sketch is the
/// D-side structural view so private_dex_seams stays dependency-light.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeamNoteSketch {
    pub origin: u8,
    pub asset_id: AssetId32,
    pub value: u64,
    pub owner_binding: [u8; 32],
    pub cm_public: Cm32,
    pub cm_encoding: u8,
    pub nullifier_lineage: [u8; 32],
    pub nullifier_domain: u8,
    pub rcm: [u8; 32],
    /// `0` = openings not on seam; `1` = rcm present (required for DEX spend).
    pub rcm_flag: u8,
    /// Stub leaf position for membership narrative.
    pub path_position: u64,
}

/// Host params to build a single-leg SwapActionV0 from SEAM spend notes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SwapFromSeamParams {
    pub pool_id: u64,
    /// Registry-resolved 32-byte ids (must be registered + match note assets).
    pub asset_in: AssetId32,
    pub asset_out: AssetId32,
    pub r_in_before: u128,
    pub r_out_before: u128,
    pub gamma: u64,
    pub gamma_den: u64,
    pub min_out: u128,
    pub root: Cm32,
    /// Amount paid into the curve; if `None`, use sum(notes_in.value).
    pub delta_in: Option<u128>,
    pub out_owner: [u8; 32],
    pub out_rcm: [u8; 32],
    /// If residual value remains and this is `Some`, emit change note with this rcm.
    pub change_rcm: Option<[u8; 32]>,
    pub now_height: u64,
    pub oracle_mid: Option<OracleMid>,
    pub oracle_params: Option<OracleBoundParams>,
}

/// Structural DEX consumability (SEAM-NOTE-OUT §4.3 spirit).
///
/// Requires `rcm_flag == 1`, non-zero rcm/asset/cm, and a specified cm_encoding.
pub fn is_dex_consumable_sketch(n: &SeamNoteSketch) -> bool {
    if n.rcm_flag != 1 {
        return false;
    }
    if n.rcm == [0u8; 32] {
        return false;
    }
    if n.asset_id == [0u8; 32] || n.cm_public == [0u8; 32] {
        return false;
    }
    if n.cm_encoding == CM_UNSPECIFIED {
        return false;
    }
    if n.value == 0 {
        return false;
    }
    true
}

/// Map a DEX-consumable SEAM sketch → spend opening (uses sketch `cm_public` as-is).
pub fn spend_opening_from_seam_sketch(
    n: &SeamNoteSketch,
) -> SwapActionResult<SpendNoteOpening> {
    if !is_dex_consumable_sketch(n) {
        return Err(SwapActionError::ErrNotDexConsumable);
    }
    Ok(SpendNoteOpening {
        asset_id: n.asset_id,
        value: n.value,
        cm_public: n.cm_public,
        owner_binding: n.owner_binding,
        rcm: n.rcm,
        ingress_nullifier_lineage: n.nullifier_lineage,
        path_position: n.path_position,
    })
}

/// Build a SEAM sketch with abstract harness leaf (cm_encoding = 0x03).
///
/// Registry-resolved `asset_id` must already be the 32-byte Terp id.
pub fn seam_sketch_abstract_leaf(
    asset_id: AssetId32,
    value: u64,
    owner_binding: [u8; 32],
    rcm: [u8; 32],
    ingress_nullifier_lineage: [u8; 32],
    path_position: u64,
    origin: u8,
    nullifier_domain: u8,
) -> SeamNoteSketch {
    let cm_public = abstract_leaf_cm(&asset_id, value, &owner_binding, &rcm);
    SeamNoteSketch {
        origin,
        asset_id,
        value,
        owner_binding,
        cm_public,
        cm_encoding: CM_ABSTRACT_LEAF_V0,
        nullifier_lineage: ingress_nullifier_lineage,
        nullifier_domain,
        rcm,
        rcm_flag: 1,
        path_position,
    }
}

/// Build + structurally validate [`SwapActionV0`] from SEAM-shaped spend notes.
///
/// Steps:
/// 1. Each note must be DEX-consumable (`rcm_flag=1`, openings present)
/// 2. `asset_in` / `asset_out` must be registered in `registry`
/// 3. Each note `asset_id` must equal `asset_in` (wrong asset → `ErrWrongAsset`)
/// 4. Conservation: sum notes = delta_in + optional change
/// 5. Curve quote on pre-state reserves; `Δ_out ≥ min_out`; exact note_out value
/// 6. Pool ν = synthetic_pool_spend_nf(cm, rcm) ≠ ingress lineage
pub fn build_swap_action_from_seam_notes(
    notes: &[SeamNoteSketch],
    params: &SwapFromSeamParams,
    registry: &impl AssetRegistryView,
) -> SwapActionResult<SwapActionV0> {
    if notes.is_empty() {
        return Err(SwapActionError::ErrBadAmount);
    }
    if !registry.is_registered(&params.asset_in) || !registry.is_registered(&params.asset_out) {
        return Err(SwapActionError::ErrUnregisteredAsset);
    }
    if params.asset_in == params.asset_out {
        return Err(SwapActionError::ErrWrongAsset);
    }
    if params.gamma_den == 0 {
        return Err(SwapActionError::ErrBadAmount);
    }

    let mut openings = Vec::with_capacity(notes.len());
    let mut sum_in: u128 = 0;
    for n in notes {
        if !is_dex_consumable_sketch(n) {
            return Err(SwapActionError::ErrNotDexConsumable);
        }
        if !registry.is_registered(&n.asset_id) {
            return Err(SwapActionError::ErrUnregisteredAsset);
        }
        if n.asset_id != params.asset_in {
            return Err(SwapActionError::ErrWrongAsset);
        }
        sum_in = sum_in
            .checked_add(n.value as u128)
            .ok_or(SwapActionError::ErrBadAmount)?;
        openings.push(spend_opening_from_seam_sketch(n)?);
    }

    let delta_in = params.delta_in.unwrap_or(sum_in);
    if delta_in == 0 || delta_in > sum_in {
        return Err(SwapActionError::ErrBadAmount);
    }
    let residual = sum_in - delta_in;
    if residual > 0 && params.change_rcm.is_none() {
        return Err(SwapActionError::ErrConservation);
    }
    if residual == 0 && params.change_rcm.is_some() {
        return Err(SwapActionError::ErrSchema);
    }

    let delta_out = quote_exact_in(
        params.r_in_before,
        params.r_out_before,
        delta_in,
        params.gamma,
        params.gamma_den,
    )
    .map_err(map_seam_err)?;
    if delta_out < params.min_out {
        return Err(SwapActionError::ErrMinOut);
    }
    if delta_out > u64::MAX as u128 {
        return Err(SwapActionError::ErrBadAmount);
    }

    if let Some(ref oracle_params) = params.oracle_params {
        check_oracle_bound(
            params.oracle_mid.as_ref(),
            oracle_params,
            params.now_height,
            delta_in,
            delta_out,
        )
        .map_err(map_seam_err)?;
    }

    let note_out = OutputNoteStub {
        asset_id: params.asset_out,
        value: delta_out as u64,
        cm_public: abstract_leaf_cm(
            &params.asset_out,
            delta_out as u64,
            &params.out_owner,
            &params.out_rcm,
        ),
        owner_binding: params.out_owner,
        rcm: params.out_rcm,
    };

    let note_change = if residual > 0 {
        let rcm_ch = params.change_rcm.ok_or(SwapActionError::ErrConservation)?;
        // Change pays residual asset_in back to first note owner (demo policy).
        let owner_ch = openings[0].owner_binding;
        Some(OutputNoteStub {
            asset_id: params.asset_in,
            value: residual as u64,
            cm_public: abstract_leaf_cm(
                &params.asset_in,
                residual as u64,
                &owner_ch,
                &rcm_ch,
            ),
            owner_binding: owner_ch,
            rcm: rcm_ch,
        })
    } else {
        None
    };

    let nullifiers: Vec<PoolNullifier32> = openings
        .iter()
        .map(|o| synthetic_pool_spend_nf(&o.cm_public, &o.rcm))
        .collect();
    let mut cm_out = vec![note_out.cm_public];
    if let Some(ref ch) = note_change {
        cm_out.push(ch.cm_public);
    }

    let action = SwapActionV0 {
        public: SwapActionPublic {
            pool_id: params.pool_id,
            asset_in: params.asset_in,
            asset_out: params.asset_out,
            root: params.root,
            nullifiers,
            cm_out,
            delta_r_in: delta_in,
            delta_r_out: delta_out,
            min_out: params.min_out,
            gamma: params.gamma,
            gamma_den: params.gamma_den,
            r_in_before: params.r_in_before,
            r_out_before: params.r_out_before,
            oracle_mid: params.oracle_mid.clone(),
            oracle_params: params.oracle_params.clone(),
            now_height: params.now_height,
        },
        witness: SwapActionWitness {
            notes_in: openings,
            note_out,
            note_change,
            delta_in,
        },
    };

    // Structural validate (conservation, ν domain, curve equality)
    validate_swap_action(&action)?;
    Ok(action)
}

/// Abstract leaf commitment for harness notes (SEAM-NOTE-OUT §1.2 code 0x03).
pub fn abstract_leaf_cm(
    asset_id: &AssetId32,
    value: u64,
    owner_binding: &[u8; 32],
    rcm: &[u8; 32],
) -> Cm32 {
    let mut h = Sha256::new();
    h.update(ABSTRACT_LEAF_LABEL);
    h.update(asset_id);
    h.update(value.to_le_bytes());
    h.update(owner_binding);
    h.update(rcm);
    let d = h.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&d);
    out
}

/// Synthetic pool-spend nullifier: `H("pool-nf-v0" ‖ cm ‖ rcm)`.
///
/// Must differ from ingress `nullifier_lineage` (claim/bridge). Production will
/// use Headstash/Orchard `DeriveNullifier(nk, rho, psi, cm)` instead.
pub fn synthetic_pool_spend_nf(note_cm: &Cm32, rcm: &[u8; 32]) -> PoolNullifier32 {
    let mut h = Sha256::new();
    h.update(POOL_NF_LABEL);
    h.update(note_cm);
    h.update(rcm);
    let d = h.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&d);
    out
}

/// Build a spend opening from SEAM-NOTE-OUT-shaped fields (structural map §4.2).
pub fn spend_opening_from_seam_fields(
    asset_id: AssetId32,
    value: u64,
    owner_binding: [u8; 32],
    rcm: [u8; 32],
    ingress_nullifier_lineage: [u8; 32],
    path_position: u64,
) -> SpendNoteOpening {
    let cm_public = abstract_leaf_cm(&asset_id, value, &owner_binding, &rcm);
    SpendNoteOpening {
        asset_id,
        value,
        cm_public,
        owner_binding,
        rcm,
        ingress_nullifier_lineage,
        path_position,
    }
}

/// Conservation: sum(notes_in) = delta_in + change_value (SPEC §1.3).
pub fn check_note_conservation(w: &SwapActionWitness) -> SwapActionResult<()> {
    let sum_in: u128 = w
        .notes_in
        .iter()
        .map(|n| n.value as u128)
        .try_fold(0u128, |a, b| a.checked_add(b))
        .ok_or(SwapActionError::ErrBadAmount)?;
    let change = w.note_change.as_ref().map(|c| c.value as u128).unwrap_or(0);
    if sum_in != w.delta_in.checked_add(change).ok_or(SwapActionError::ErrBadAmount)? {
        return Err(SwapActionError::ErrConservation);
    }
    if w.note_out.value as u128 == 0 {
        return Err(SwapActionError::ErrBadAmount);
    }
    Ok(())
}

/// Structural validation of a full swap action (no ZK, no tree crypto).
///
/// Checks:
/// 1. notes_in asset_id == public.asset_in; note_out.asset_id == asset_out
/// 2. conservation sum_in = delta_in + change
/// 3. each pool ν = synthetic_pool_spend_nf(cm, rcm) and ≠ ingress lineage
/// 4. public.nullifiers match derived νs; cm_out matches note_out (+ change)
/// 5. public.delta_r_in == witness.delta_in
/// 6. curve quote(R_before, delta_in) == public.delta_r_out; ≥ min_out
pub fn validate_swap_action(action: &SwapActionV0) -> SwapActionResult<u128> {
    let p = &action.public;
    let w = &action.witness;

    if w.notes_in.is_empty() {
        return Err(SwapActionError::ErrBadAmount);
    }
    if p.nullifiers.len() != w.notes_in.len() {
        return Err(SwapActionError::ErrSchema);
    }
    if p.gamma_den == 0 || p.delta_r_in == 0 {
        return Err(SwapActionError::ErrBadAmount);
    }
    if p.delta_r_in != w.delta_in {
        return Err(SwapActionError::ErrConservation);
    }

    for n in &w.notes_in {
        if n.asset_id != p.asset_in {
            return Err(SwapActionError::ErrWrongAsset);
        }
        if n.cm_public == [0u8; 32] || n.rcm == [0u8; 32] {
            return Err(SwapActionError::ErrSchema);
        }
    }
    if w.note_out.asset_id != p.asset_out {
        return Err(SwapActionError::ErrWrongAsset);
    }
    if let Some(ref ch) = w.note_change {
        if ch.asset_id != p.asset_in {
            return Err(SwapActionError::ErrWrongAsset);
        }
    }

    check_note_conservation(w)?;

    for (n, pub_nf) in w.notes_in.iter().zip(p.nullifiers.iter()) {
        let derived = synthetic_pool_spend_nf(&n.cm_public, &n.rcm);
        if &derived != pub_nf {
            return Err(SwapActionError::ErrSchema);
        }
        if *pub_nf == n.ingress_nullifier_lineage {
            return Err(SwapActionError::ErrNullifierDomain);
        }
    }

    // cm_out vector: [note_out, optional change]
    let mut expected_cms = vec![w.note_out.cm_public];
    if let Some(ref ch) = w.note_change {
        expected_cms.push(ch.cm_public);
    }
    if p.cm_out != expected_cms {
        return Err(SwapActionError::ErrSchema);
    }
    // Recompute abstract leaves for outputs
    let out_cm = abstract_leaf_cm(
        &w.note_out.asset_id,
        w.note_out.value,
        &w.note_out.owner_binding,
        &w.note_out.rcm,
    );
    if out_cm != w.note_out.cm_public {
        return Err(SwapActionError::ErrSchema);
    }
    if let Some(ref ch) = w.note_change {
        let ch_cm = abstract_leaf_cm(&ch.asset_id, ch.value, &ch.owner_binding, &ch.rcm);
        if ch_cm != ch.cm_public {
            return Err(SwapActionError::ErrSchema);
        }
    }

    let delta_out = quote_exact_in(
        p.r_in_before,
        p.r_out_before,
        w.delta_in,
        p.gamma,
        p.gamma_den,
    )
    .map_err(map_seam_err)?;
    if delta_out != p.delta_r_out {
        return Err(SwapActionError::ErrCurveMismatch);
    }
    if delta_out < p.min_out {
        return Err(SwapActionError::ErrMinOut);
    }
    // Output note value must equal curve Δ_out (SPEC §1.3 exact equality)
    if w.note_out.value as u128 != delta_out {
        return Err(SwapActionError::ErrConservation);
    }

    if let Some(ref params) = p.oracle_params {
        check_oracle_bound(
            p.oracle_mid.as_ref(),
            params,
            p.now_height,
            w.delta_in,
            delta_out,
        )
        .map_err(map_seam_err)?;
    }

    Ok(delta_out)
}

fn map_seam_err(e: SeamError) -> SwapActionError {
    match e {
        SeamError::ErrMinOut => SwapActionError::ErrMinOut,
        SeamError::ErrOracleStale => SwapActionError::ErrOracleStale,
        SeamError::ErrOracleSlippage => SwapActionError::ErrOracleSlippage,
        SeamError::ErrOracleMissing => SwapActionError::ErrOracleMissing,
        SeamError::ErrNullifierExists => SwapActionError::ErrNullifierExists,
        SeamError::ErrWrongAsset => SwapActionError::ErrWrongAsset,
        SeamError::ErrInsufficientReserve => SwapActionError::ErrInsufficientReserve,
        SeamError::ErrBadAmount => SwapActionError::ErrBadAmount,
        SeamError::ErrPoolPaused => SwapActionError::ErrSchema,
        SeamError::ErrOracleDisabledMint => SwapActionError::ErrSchema,
    }
}

/// Apply a validated swap action to host state (reserves + nullifiers + leaves).
///
/// Does **not** invent mint authority; only updates public reserves from proven Δ.
///
/// `asset_in_is_a`: true if pool.asset_a is the asset_in orientation of this trade.
pub fn apply_swap_action(
    pool: &mut Pool,
    state: &mut SwapSeamState,
    action: &SwapActionV0,
    asset_in_is_a: bool,
) -> SwapActionResult<u128> {
    if pool.status != PoolStatus::Active {
        return Err(SwapActionError::ErrSchema);
    }
    if let Some(root) = state.allowed_root {
        if action.public.root != root {
            return Err(SwapActionError::ErrBadRoot);
        }
    }

    let delta_out = validate_swap_action(action)?;

    for nf in &action.public.nullifiers {
        if state.nullifiers.contains(nf) {
            return Err(SwapActionError::ErrNullifierExists);
        }
    }

    let (r_in, r_out) = if asset_in_is_a {
        (pool.r_a, pool.r_b)
    } else {
        (pool.r_b, pool.r_a)
    };
    if r_in != action.public.r_in_before || r_out != action.public.r_out_before {
        return Err(SwapActionError::ErrCurveMismatch);
    }

    let (r_in2, r_out2) = apply_reserves(r_in, r_out, action.public.delta_r_in, delta_out)
        .map_err(map_seam_err)?;
    if asset_in_is_a {
        pool.r_a = r_in2;
        pool.r_b = r_out2;
    } else {
        pool.r_b = r_in2;
        pool.r_a = r_out2;
    }

    for nf in &action.public.nullifiers {
        state.nullifiers.insert(*nf);
    }
    state.tree_leaves += action.public.cm_out.len() as u64;
    state.allowed_root = Some(action.public.root); // stub: root window unchanged

    Ok(delta_out)
}

// ---------------------------------------------------------------------------
// Tests (SPEC §6.1–6.6)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Demo fee: 30 bps → γ/γ_den = 997/1000
    fn demo_pool() -> Pool {
        Pool {
            pool_id: 1,
            asset_a: AssetId::Hub,
            asset_b: AssetId::AssetB,
            r_a: 1_000_000,
            r_b: 2_000_000,
            gamma: 997,
            gamma_den: 1000,
            status: PoolStatus::Active,
        }
    }

    fn note(asset: AssetId, value: u128, nullifier: u64) -> NoteIn {
        NoteIn {
            asset_id: asset,
            value,
            nullifier,
        }
    }

    fn base_public(delta_in: u128, min_out: u128, nullifiers: Vec<u64>) -> SwapPublic {
        SwapPublic {
            asset_in: AssetId::AssetB,
            asset_out: AssetId::Hub,
            delta_in,
            min_out,
            nullifiers,
            oracle_mid: None,
            oracle_params: None,
            now_height: 100,
        }
    }

    // ---- §6.1 swap_happy ----

    #[test]
    fn swap_happy() {
        let mut pool = demo_pool();
        let mut state = SeamState::default();
        let delta_in = 10_000u128;

        // B → Hub: r_in = R_B, r_out = R_A
        let expected = quote_exact_in(
            pool.r_b,
            pool.r_a,
            delta_in,
            pool.gamma,
            pool.gamma_den,
        )
        .expect("quote");

        let notes = [note(AssetId::AssetB, delta_in, 42)];
        let public = base_public(delta_in, expected, vec![42]);

        let r_a_before = pool.r_a;
        let r_b_before = pool.r_b;
        let leaves_before = state.tree_leaves;

        let delta_out = apply_swap(&mut pool, &mut state, &notes, &public).expect("swap");

        assert_eq!(delta_out, expected);
        // paid B, received Hub
        assert_eq!(pool.r_b, r_b_before + delta_in);
        assert_eq!(pool.r_a, r_a_before - delta_out);
        assert!(state.nullifiers.contains(&42));
        assert_eq!(state.tree_leaves, leaves_before + 1);

        // Formula spot-check against literal floor expression
        let g = 997u128;
        let gd = 1000u128;
        let hand = (r_a_before * g * delta_in) / (r_b_before * gd + g * delta_in);
        assert_eq!(delta_out, hand);
    }

    // ---- §6.2 min_out_fail ----

    #[test]
    fn min_out_fail() {
        let mut pool = demo_pool();
        let mut state = SeamState::default();
        let delta_in = 10_000u128;
        let expected = quote_exact_in(pool.r_b, pool.r_a, delta_in, pool.gamma, pool.gamma_den)
            .unwrap();

        let r_a = pool.r_a;
        let r_b = pool.r_b;
        let notes = [note(AssetId::AssetB, delta_in, 7)];
        let public = base_public(delta_in, expected + 1, vec![7]);

        let err = apply_swap(&mut pool, &mut state, &notes, &public).unwrap_err();
        assert_eq!(err, SeamError::ErrMinOut);
        assert_eq!(pool.r_a, r_a);
        assert_eq!(pool.r_b, r_b);
        assert!(!state.nullifiers.contains(&7));
        assert_eq!(state.tree_leaves, 0);
    }

    // ---- §6.3 oracle_stale ----

    #[test]
    fn oracle_stale() {
        let mut pool = demo_pool();
        let mut state = SeamState::default();
        let delta_in = 10_000u128;
        let expected = quote_exact_in(pool.r_b, pool.r_a, delta_in, pool.gamma, pool.gamma_den)
            .unwrap();

        // Implied mid matching the trade so only staleness fails
        let mid_price = implied_price(delta_in, expected).unwrap();

        let notes = [note(AssetId::AssetB, delta_in, 99)];
        let mut public = base_public(delta_in, expected, vec![99]);
        public.now_height = 1_000;
        public.oracle_params = Some(OracleBoundParams {
            max_age_blocks: 10,
            max_slippage_bps: 500, // 5%
            require_oracle: true,
        });
        public.oracle_mid = Some(OracleMid {
            pair_key: "Hub/AssetB".into(),
            mid: mid_price,
            observed_height: 900, // age = 100 > 10
        });

        let r_a = pool.r_a;
        let r_b = pool.r_b;
        let err = apply_swap(&mut pool, &mut state, &notes, &public).unwrap_err();
        assert_eq!(err, SeamError::ErrOracleStale);
        assert_eq!(pool.r_a, r_a);
        assert_eq!(pool.r_b, r_b);
        assert!(!state.nullifiers.contains(&99));
    }

    #[test]
    fn oracle_stale_optional_allows_amm() {
        let mut pool = demo_pool();
        let mut state = SeamState::default();
        let delta_in = 10_000u128;
        let expected = quote_exact_in(pool.r_b, pool.r_a, delta_in, pool.gamma, pool.gamma_den)
            .unwrap();

        let notes = [note(AssetId::AssetB, delta_in, 100)];
        let mut public = base_public(delta_in, expected, vec![100]);
        public.now_height = 1_000;
        public.oracle_params = Some(OracleBoundParams {
            max_age_blocks: 10,
            max_slippage_bps: 500,
            require_oracle: false,
        });
        public.oracle_mid = Some(OracleMid {
            pair_key: "Hub/AssetB".into(),
            mid: 1,
            observed_height: 1, // very stale, wrong mid — ignored when not required
        });

        apply_swap(&mut pool, &mut state, &notes, &public).expect("pure AMM allowed");
        assert!(state.nullifiers.contains(&100));
    }

    // ---- §6.4 oracle_cannot_inflate_balance ----

    #[test]
    fn oracle_inflate_reject_mint_api() {
        let mid = OracleMid {
            pair_key: "Hub".into(),
            mid: 1_000 * PRICE_SCALE,
            observed_height: 50,
        };
        let err = oracle_mint_note(&mid, AssetId::Hub, 1_000_000).unwrap_err();
        assert_eq!(err, SeamError::ErrOracleDisabledMint);
    }

    #[test]
    fn oracle_inflate_reject_reserve_bump() {
        let mut pool = demo_pool();
        let r_a = pool.r_a;
        let mid = OracleMid {
            pair_key: "Hub/AssetB".into(),
            mid: PRICE_SCALE,
            observed_height: 50,
        };
        let err = oracle_update_reserves(&mid, &mut pool).unwrap_err();
        assert_eq!(err, SeamError::ErrOracleDisabledMint);
        assert_eq!(pool.r_a, r_a);
    }

    #[test]
    fn oracle_cannot_justify_inflated_delta_out() {
        // Host always recomputes Δ_out from curve; a high mid cannot inflate output.
        let pool = demo_pool();
        let delta_in = 10_000u128;
        let curve_out =
            quote_exact_in(pool.r_b, pool.r_a, delta_in, pool.gamma, pool.gamma_den).unwrap();

        // Attacker wants 10× curve output "because oracle mid says so"
        let fake_out = curve_out.saturating_mul(10);
        assert!(fake_out > curve_out);

        // Bound check against a high mid would pass slippage for an inflated trade,
        // but apply_swap never accepts client-supplied Δ_out — only recomputed value.
        let mut pool2 = demo_pool();
        let mut state = SeamState::default();
        let notes = [note(AssetId::AssetB, delta_in, 55)];
        let mut public = base_public(delta_in, fake_out, vec![55]); // min_out inflated
        public.oracle_params = Some(OracleBoundParams {
            max_age_blocks: 100,
            max_slippage_bps: 9_999,
            require_oracle: true,
        });
        public.oracle_mid = Some(OracleMid {
            pair_key: "Hub/AssetB".into(),
            mid: implied_price(delta_in, curve_out).unwrap(),
            observed_height: 100,
        });
        public.now_height = 100;

        // Fails at min_out because curve Δ_out < attacker's min_out
        let err = apply_swap(&mut pool2, &mut state, &notes, &public).unwrap_err();
        assert_eq!(err, SeamError::ErrMinOut);
        assert!(!state.nullifiers.contains(&55));
    }

    // ---- §6.5 double_spend_nullifier ----

    #[test]
    fn double_spend_nullifier() {
        let mut pool = demo_pool();
        let mut state = SeamState::default();
        let delta_in = 5_000u128;
        let expected = quote_exact_in(pool.r_b, pool.r_a, delta_in, pool.gamma, pool.gamma_den)
            .unwrap();

        let notes = [note(AssetId::AssetB, delta_in, 777)];
        let public = base_public(delta_in, expected, vec![777]);

        apply_swap(&mut pool, &mut state, &notes, &public).expect("first spend");
        let r_a_after_first = pool.r_a;
        let r_b_after_first = pool.r_b;

        // Reuse same nullifier / note
        let expected2 = quote_exact_in(pool.r_b, pool.r_a, delta_in, pool.gamma, pool.gamma_den)
            .unwrap();
        let public2 = base_public(delta_in, expected2, vec![777]);
        let err = apply_swap(&mut pool, &mut state, &notes, &public2).unwrap_err();
        assert_eq!(err, SeamError::ErrNullifierExists);
        assert_eq!(pool.r_a, r_a_after_first);
        assert_eq!(pool.r_b, r_b_after_first);
    }

    // ---- §6.6 wrong_asset_id ----

    #[test]
    fn wrong_asset_id() {
        let mut pool = demo_pool();
        let mut state = SeamState::default();
        let delta_in = 10_000u128;
        let expected = quote_exact_in(pool.r_b, pool.r_a, delta_in, pool.gamma, pool.gamma_den)
            .unwrap();

        // Note is AssetX, but public claims AssetB → Hub
        let notes = [note(AssetId::AssetX, delta_in, 3)];
        let public = base_public(delta_in, expected, vec![3]);

        let r_a = pool.r_a;
        let r_b = pool.r_b;
        let err = apply_swap(&mut pool, &mut state, &notes, &public).unwrap_err();
        assert_eq!(err, SeamError::ErrWrongAsset);
        assert_eq!(pool.r_a, r_a);
        assert_eq!(pool.r_b, r_b);
        assert!(!state.nullifiers.contains(&3));
    }

    #[test]
    fn wrong_pool_leg_orientation() {
        let mut pool = demo_pool();
        let mut state = SeamState::default();
        // Pool is Hub/AssetB; AssetC is not a leg
        let notes = [note(AssetId::AssetC, 100, 1)];
        let public = SwapPublic {
            asset_in: AssetId::AssetC,
            asset_out: AssetId::Hub,
            delta_in: 100,
            min_out: 1,
            nullifiers: vec![1],
            oracle_mid: None,
            oracle_params: None,
            now_height: 1,
        };
        let err = apply_swap(&mut pool, &mut state, &notes, &public).unwrap_err();
        assert_eq!(err, SeamError::ErrWrongAsset);
    }

    // ---- pure formula unit ----

    #[test]
    fn quote_zero_fee_matches_xyk() {
        // γ = γ_den = 1000 → no fee: floor(R_out * Δ / (R_in + Δ))
        let r_in = 1000u128;
        let r_out = 1000u128;
        let d = 100u128;
        let out = quote_exact_in(r_in, r_out, d, 1000, 1000).unwrap();
        assert_eq!(out, (r_out * d) / (r_in + d));
        assert_eq!(out, 90); // classic 1000/1000 + 100 → 90
    }

    #[test]
    fn within_slippage_band() {
        let mid = 1_000_000u128;
        assert!(within_slippage(mid, mid, 100)); // exact
        assert!(within_slippage(mid + 5_000, mid, 100)); // +0.5% within 1%
        assert!(!within_slippage(mid + 20_000, mid, 100)); // +2% outside 1%
    }

    // ---- SwapActionV0 full structural fixture (ROUND1-SWAP) ----

    fn arr32(seed: u8) -> [u8; 32] {
        let mut a = [0u8; 32];
        for (i, b) in a.iter_mut().enumerate() {
            *b = seed.wrapping_add(i as u8);
        }
        a
    }

    /// Build a complete single-leg B→Hub swap action fixture.
    ///
    /// Encodes: notes in (SEAM-NOTE-OUT widths), min_out, reserves before/after,
    /// pool nullifiers ≠ ingress lineage, cm_out leaves.
    fn fixture_swap_action_b_to_hub(with_change: bool) -> (Pool, SwapActionV0, u128) {
        let pool = demo_pool();
        let delta_in = 10_000u128;
        let note_value = if with_change { 12_000u64 } else { 10_000u64 };
        let change_value = note_value as u128 - delta_in;

        let expected = quote_exact_in(
            pool.r_b, // asset_in = B
            pool.r_a, // asset_out = Hub
            delta_in,
            pool.gamma,
            pool.gamma_den,
        )
        .expect("quote");

        let owner = arr32(0xA1);
        let rcm_in = arr32(0xB2);
        let ingress_lineage = arr32(0xC3); // claim nf / burn ν — not pool spend
        let opening = spend_opening_from_seam_fields(
            asset_id_b(),
            note_value,
            owner,
            rcm_in,
            ingress_lineage,
            7,
        );
        let pool_nf = synthetic_pool_spend_nf(&opening.cm_public, &opening.rcm);

        let rcm_out = arr32(0xD4);
        let owner_out = arr32(0xE5);
        let note_out = OutputNoteStub {
            asset_id: asset_id_hub(),
            value: expected as u64,
            cm_public: abstract_leaf_cm(&asset_id_hub(), expected as u64, &owner_out, &rcm_out),
            owner_binding: owner_out,
            rcm: rcm_out,
        };

        let note_change = if with_change {
            let rcm_ch = arr32(0xF6);
            let owner_ch = owner;
            Some(OutputNoteStub {
                asset_id: asset_id_b(),
                value: change_value as u64,
                cm_public: abstract_leaf_cm(
                    &asset_id_b(),
                    change_value as u64,
                    &owner_ch,
                    &rcm_ch,
                ),
                owner_binding: owner_ch,
                rcm: rcm_ch,
            })
        } else {
            None
        };

        let mut cm_out = vec![note_out.cm_public];
        if let Some(ref ch) = note_change {
            cm_out.push(ch.cm_public);
        }

        let root = arr32(0x11);
        let public = SwapActionPublic {
            pool_id: pool.pool_id,
            asset_in: asset_id_b(),
            asset_out: asset_id_hub(),
            root,
            nullifiers: vec![pool_nf],
            cm_out,
            delta_r_in: delta_in,
            delta_r_out: expected,
            min_out: expected, // exact floor
            gamma: pool.gamma,
            gamma_den: pool.gamma_den,
            r_in_before: pool.r_b,
            r_out_before: pool.r_a,
            oracle_mid: None,
            oracle_params: None,
            now_height: 100,
        };
        let witness = SwapActionWitness {
            notes_in: vec![opening],
            note_out,
            note_change,
            delta_in,
        };
        (
            pool,
            SwapActionV0 { public, witness },
            expected,
        )
    }

    #[test]
    fn swap_action_structural_fixture_happy() {
        let (mut pool, action, expected) = fixture_swap_action_b_to_hub(false);
        let mut state = SwapSeamState {
            allowed_root: Some(action.public.root),
            ..Default::default()
        };

        // Structural relation holds before host apply
        let delta_out = validate_swap_action(&action).expect("validate");
        assert_eq!(delta_out, expected);

        // Pool nullifier ≠ ingress claim/bridge lineage
        let n0 = &action.witness.notes_in[0];
        assert_ne!(
            action.public.nullifiers[0],
            n0.ingress_nullifier_lineage,
            "pool-spend ν must not reuse ingress lineage (SEAM-NOTE-OUT NE-4)"
        );

        let r_a_before = pool.r_a;
        let r_b_before = pool.r_b;
        // B → Hub: asset_in is B = pool.asset_b → asset_in_is_a = false
        let got = apply_swap_action(&mut pool, &mut state, &action, false).expect("apply");
        assert_eq!(got, expected);
        assert_eq!(pool.r_b, r_b_before + action.public.delta_r_in);
        assert_eq!(pool.r_a, r_a_before - expected);
        assert!(state.nullifiers.contains(&action.public.nullifiers[0]));
        assert_eq!(state.tree_leaves, 1); // note_out only

        // Reserves after match public Δ narrative
        let (r_in2, r_out2) = apply_reserves(
            action.public.r_in_before,
            action.public.r_out_before,
            action.public.delta_r_in,
            expected,
        )
        .unwrap();
        assert_eq!(pool.r_b, r_in2);
        assert_eq!(pool.r_a, r_out2);
    }

    #[test]
    fn swap_action_structural_fixture_with_change() {
        let (mut pool, action, expected) = fixture_swap_action_b_to_hub(true);
        assert!(action.witness.note_change.is_some());
        assert_eq!(action.public.cm_out.len(), 2);

        let mut state = SwapSeamState {
            allowed_root: Some(action.public.root),
            ..Default::default()
        };
        let got = apply_swap_action(&mut pool, &mut state, &action, false).expect("apply+change");
        assert_eq!(got, expected);
        assert_eq!(state.tree_leaves, 2); // out + change

        // Conservation: note_in = delta_in + change
        let sum: u128 = action.witness.notes_in.iter().map(|n| n.value as u128).sum();
        let ch = action.witness.note_change.as_ref().unwrap().value as u128;
        assert_eq!(sum, action.witness.delta_in + ch);
    }

    #[test]
    fn swap_action_rejects_ingress_lineage_as_pool_nf() {
        let (_pool, mut action, _) = fixture_swap_action_b_to_hub(false);
        // Attacker reuses claim/burn lineage as the only double-spend tag
        let lineage = action.witness.notes_in[0].ingress_nullifier_lineage;
        action.public.nullifiers[0] = lineage;
        let err = validate_swap_action(&action).unwrap_err();
        // Fails schema (derived ≠ public) before or as domain error
        assert!(
            err == SwapActionError::ErrSchema || err == SwapActionError::ErrNullifierDomain
        );
    }

    #[test]
    fn swap_action_rejects_min_out_above_curve() {
        let (_pool, mut action, expected) = fixture_swap_action_b_to_hub(false);
        action.public.min_out = expected + 1;
        let err = validate_swap_action(&action).unwrap_err();
        assert_eq!(err, SwapActionError::ErrMinOut);
    }

    #[test]
    fn swap_action_rejects_wrong_asset_out_note() {
        let (_pool, mut action, _) = fixture_swap_action_b_to_hub(false);
        action.witness.note_out.asset_id = asset_id_c();
        // cm_public no longer matches recompute either, but wrong asset first
        let err = validate_swap_action(&action).unwrap_err();
        assert_eq!(err, SwapActionError::ErrWrongAsset);
    }

    #[test]
    fn swap_action_double_spend_pool_nf() {
        let (mut pool, action, _) = fixture_swap_action_b_to_hub(false);
        let mut state = SwapSeamState {
            allowed_root: Some(action.public.root),
            ..Default::default()
        };
        apply_swap_action(&mut pool, &mut state, &action, false).expect("first");
        // Rebuild second action with same nullifier (same note opening)
        let err = apply_swap_action(&mut pool, &mut state, &action, false).unwrap_err();
        // Second apply: either nullifier exists, or curve mismatch because reserves moved
        // (statement still has old r_*_before). Prefer checking nullifier after fixing
        // statement to current reserves would still hit ErrNullifierExists.
        assert!(
            err == SwapActionError::ErrNullifierExists
                || err == SwapActionError::ErrCurveMismatch
        );

        // Explicit: insert same nf again with fresh curve statement
        let (mut pool2, mut action2, expected2) = fixture_swap_action_b_to_hub(false);
        let mut state2 = SwapSeamState {
            allowed_root: Some(action2.public.root),
            ..Default::default()
        };
        apply_swap_action(&mut pool2, &mut state2, &action2, false).unwrap();
        // Update public reserves to post-state so only nullifier fails
        action2.public.r_in_before = pool2.r_b;
        action2.public.r_out_before = pool2.r_a;
        let new_out = quote_exact_in(
            pool2.r_b,
            pool2.r_a,
            action2.witness.delta_in,
            pool2.gamma,
            pool2.gamma_den,
        )
        .unwrap();
        action2.public.delta_r_out = new_out;
        action2.public.min_out = new_out;
        action2.witness.note_out.value = new_out as u64;
        action2.witness.note_out.cm_public = abstract_leaf_cm(
            &action2.witness.note_out.asset_id,
            action2.witness.note_out.value,
            &action2.witness.note_out.owner_binding,
            &action2.witness.note_out.rcm,
        );
        action2.public.cm_out = vec![action2.witness.note_out.cm_public];
        let _ = expected2;
        let err2 = apply_swap_action(&mut pool2, &mut state2, &action2, false).unwrap_err();
        assert_eq!(err2, SwapActionError::ErrNullifierExists);
    }

    // ---- ROUND2-SWAP: SEAM sketches → SwapActionV0 (registry-aware) ----

    /// SEAM origin/nullifier domain codes used in sketches (mirrored).
    const ORIGIN_HEADSTASH: u8 = 0x01;
    const NF_HEADSTASH_CLAIM: u8 = 0x01;

    fn fixture_seam_spend_note(
        registry: &AssetMap,
        asset_label: &str,
        value: u64,
        rcm_seed: u8,
        lineage_seed: u8,
        pos: u64,
    ) -> SeamNoteSketch {
        let asset_id = registry.resolve_label(asset_label).expect("label registered");
        seam_sketch_abstract_leaf(
            asset_id,
            value,
            arr32(0xA1),
            arr32(rcm_seed),
            arr32(lineage_seed),
            pos,
            ORIGIN_HEADSTASH,
            NF_HEADSTASH_CLAIM,
        )
    }

    fn fixture_swap_from_seam_params(
        pool: &Pool,
        registry: &AssetMap,
        delta_in: u128,
        min_out: u128,
        change: bool,
    ) -> SwapFromSeamParams {
        let asset_in = registry.resolve_label("b").unwrap();
        let asset_out = registry.resolve_label("hub").unwrap();
        SwapFromSeamParams {
            pool_id: pool.pool_id,
            asset_in,
            asset_out,
            r_in_before: pool.r_b,
            r_out_before: pool.r_a,
            gamma: pool.gamma,
            gamma_den: pool.gamma_den,
            min_out,
            root: arr32(0x11),
            delta_in: Some(delta_in),
            out_owner: arr32(0xE5),
            out_rcm: arr32(0xD4),
            change_rcm: if change { Some(arr32(0xF6)) } else { None },
            now_height: 100,
            oracle_mid: None,
            oracle_params: None,
        }
    }

    #[test]
    fn seam_to_swap_action_structural_happy() {
        let registry = AssetMap::demo_hub_b_c();
        let pool = demo_pool();
        let delta_in = 10_000u128;
        let expected = quote_exact_in(
            pool.r_b,
            pool.r_a,
            delta_in,
            pool.gamma,
            pool.gamma_den,
        )
        .unwrap();

        let note = fixture_seam_spend_note(&registry, "b", delta_in as u64, 0xB2, 0xC3, 7);
        assert!(is_dex_consumable_sketch(&note));
        assert_eq!(note.asset_id, registry.resolve_label("b").unwrap());

        let params = fixture_swap_from_seam_params(&pool, &registry, delta_in, expected, false);
        let action =
            build_swap_action_from_seam_notes(&[note], &params, &registry).expect("compose");

        // Registry-resolved legs
        assert_eq!(action.public.asset_in, asset_id_b());
        assert_eq!(action.public.asset_out, asset_id_hub());
        assert_eq!(action.public.delta_r_out, expected);
        assert_eq!(action.witness.note_out.value as u128, expected);

        // Pool ν ≠ ingress lineage (NE-4)
        assert_ne!(
            action.public.nullifiers[0],
            action.witness.notes_in[0].ingress_nullifier_lineage
        );

        // Host apply path still works
        let mut pool = pool;
        let mut state = SwapSeamState {
            allowed_root: Some(action.public.root),
            ..Default::default()
        };
        let got = apply_swap_action(&mut pool, &mut state, &action, false).expect("apply");
        assert_eq!(got, expected);
        assert_eq!(state.tree_leaves, 1);
    }

    #[test]
    fn seam_to_swap_action_rejects_wrong_asset() {
        let registry = AssetMap::demo_hub_b_c();
        let pool = demo_pool();
        let delta_in = 10_000u128;
        let expected = quote_exact_in(
            pool.r_b,
            pool.r_a,
            delta_in,
            pool.gamma,
            pool.gamma_den,
        )
        .unwrap();

        // Note holds asset C, but swap params demand B → hub
        let note = fixture_seam_spend_note(&registry, "c", delta_in as u64, 0xB2, 0xC3, 1);
        let params = fixture_swap_from_seam_params(&pool, &registry, delta_in, expected, false);

        let err = build_swap_action_from_seam_notes(&[note], &params, &registry).unwrap_err();
        assert_eq!(err, SwapActionError::ErrWrongAsset);
    }

    #[test]
    fn seam_to_swap_action_rejects_missing_rcm() {
        let registry = AssetMap::demo_hub_b_c();
        let pool = demo_pool();
        let delta_in = 10_000u128;
        let expected = quote_exact_in(
            pool.r_b,
            pool.r_a,
            delta_in,
            pool.gamma,
            pool.gamma_den,
        )
        .unwrap();

        let mut note = fixture_seam_spend_note(&registry, "b", delta_in as u64, 0xB2, 0xC3, 7);
        // Phase-0 egress without openings: not DEX-consumable
        note.rcm_flag = 0;
        note.rcm = [0u8; 32];
        assert!(!is_dex_consumable_sketch(&note));

        let params = fixture_swap_from_seam_params(&pool, &registry, delta_in, expected, false);
        let err = build_swap_action_from_seam_notes(&[note], &params, &registry).unwrap_err();
        assert_eq!(err, SwapActionError::ErrNotDexConsumable);

        // Direct spend_opening path also rejects
        let note2 = fixture_seam_spend_note(&registry, "b", delta_in as u64, 0xB2, 0xC3, 7);
        let mut note2 = note2;
        note2.rcm_flag = 0;
        assert_eq!(
            spend_opening_from_seam_sketch(&note2),
            Err(SwapActionError::ErrNotDexConsumable)
        );
    }

    #[test]
    fn seam_to_swap_action_rejects_unregistered_asset() {
        let mut registry = AssetMap::new();
        // Only hub registered — B not in map
        registry.register_labeled("hub", asset_id_hub());
        let pool = demo_pool();
        let asset_b = asset_id_b();
        let note = seam_sketch_abstract_leaf(
            asset_b,
            10_000,
            arr32(0xA1),
            arr32(0xB2),
            arr32(0xC3),
            0,
            ORIGIN_HEADSTASH,
            NF_HEADSTASH_CLAIM,
        );
        let params = SwapFromSeamParams {
            pool_id: 1,
            asset_in: asset_b,
            asset_out: asset_id_hub(),
            r_in_before: pool.r_b,
            r_out_before: pool.r_a,
            gamma: pool.gamma,
            gamma_den: pool.gamma_den,
            min_out: 1,
            root: arr32(0x11),
            delta_in: Some(10_000),
            out_owner: arr32(0xE5),
            out_rcm: arr32(0xD4),
            change_rcm: None,
            now_height: 100,
            oracle_mid: None,
            oracle_params: None,
        };
        let err = build_swap_action_from_seam_notes(&[note], &params, &registry).unwrap_err();
        assert_eq!(err, SwapActionError::ErrUnregisteredAsset);
    }

    #[test]
    fn asset_map_demo_labels_are_test_helpers_not_sole_path() {
        // Arbitrary registry-resolved id (not HUB/B/C first-byte pattern) works.
        let mut registry = AssetMap::new();
        let mut custom_in = [0u8; 32];
        custom_in[0] = 0xDE;
        custom_in[1] = 0xAD;
        let mut custom_out = [0u8; 32];
        custom_out[0] = 0xBE;
        custom_out[1] = 0xEF;
        registry.register(custom_in);
        registry.register(custom_out);

        let note = seam_sketch_abstract_leaf(
            custom_in,
            5_000,
            arr32(0x11),
            arr32(0x22),
            arr32(0x33),
            2,
            ORIGIN_HEADSTASH,
            NF_HEADSTASH_CLAIM,
        );
        let r_in = 1_000_000u128;
        let r_out = 2_000_000u128;
        let delta_in = 5_000u128;
        let expected = quote_exact_in(r_in, r_out, delta_in, 997, 1000).unwrap();
        let params = SwapFromSeamParams {
            pool_id: 9,
            asset_in: custom_in,
            asset_out: custom_out,
            r_in_before: r_in,
            r_out_before: r_out,
            gamma: 997,
            gamma_den: 1000,
            min_out: expected,
            root: arr32(0x44),
            delta_in: Some(delta_in),
            out_owner: arr32(0x55),
            out_rcm: arr32(0x66),
            change_rcm: None,
            now_height: 1,
            oracle_mid: None,
            oracle_params: None,
        };
        let action = build_swap_action_from_seam_notes(&[note], &params, &registry).expect("custom");
        assert_eq!(action.public.asset_in, custom_in);
        assert_eq!(action.public.asset_out, custom_out);
        assert_eq!(action.public.delta_r_out, expected);
    }
}
