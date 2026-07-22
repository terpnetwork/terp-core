//! Option D pure egress seams — Terp ZEC-SEAM burn → preauth dest (G4 seal).
//!
//! SSOT: `DESIGN-ZEC-EGRESS-D.md`,
//! `DESIGN-DECISIONS-ZEC-EGRESS-OPTION-D-ACCEPTED-2026-07-22.md`.
//!
//! Domain tags (must not invent alternatives):
//! - deposit: `terp-btc-deposit-nu-v0`
//! - pool swap: `pool-nf-v0` ([`crate::POOL_NF_LABEL`])
//! - egress: `egress-nf-v0` ([`EGRESS_NF_LABEL`])

use std::collections::HashSet;

use sha2::{Digest, Sha256};

use crate::{synthetic_pool_spend_nf, AssetId32, Cm32, PoolNullifier32, ABSTRACT_LEAF_LABEL};

// ---------------------------------------------------------------------------
// Domain labels
// ---------------------------------------------------------------------------

/// Domain for egress-spend nullifiers (≠ pool-nf-v0, ≠ deposit-nu-v0, ≠ bridge ingress).
pub const EGRESS_NF_LABEL: &[u8] = b"egress-nf-v0";

/// Deposit / ingress one-shot domain (PROMPT-COMMON; for inequality tests only).
pub const DEPOSIT_NU_LABEL: &[u8] = b"terp-btc-deposit-nu-v0";

// ---------------------------------------------------------------------------
// Types (normative)
// ---------------------------------------------------------------------------

/// Zcash receiver class — metadata for wallet API selection; binding stays 32B seal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DestKind {
    Transparent,
    Shielded,
}

/// Public statement for Option D burn on Terp.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EgressBurnPublic {
    pub asset_id: AssetId32,
    pub value: u64,
    /// SEAM cm being burned.
    pub cm_spent: Cm32,
    /// Egress-domain ν: `H("egress-nf-v0" ‖ cm_spent ‖ rcm)`.
    pub nullifier: [u8; 32],
    /// MUST equal G4 seal bytes.
    pub dest_commitment: [u8; 32],
    pub dest_kind: DestKind,
    /// Membership root (lab stub OK).
    pub root: Cm32,
    /// If from swap settle.
    pub source_pool_id: Option<u64>,
}

/// Private witness for egress burn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EgressBurnWitness {
    pub rcm: [u8; 32],
    /// Must equal `dest_commitment` for corridor product.
    pub owner_binding: [u8; 32],
    pub path_position: u64,
}

/// Full structural burn: public + private halves.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EgressBurnV0 {
    pub public: EgressBurnPublic,
    pub witness: EgressBurnWitness,
}

/// After Terp burn is accepted — authorization for Zcash leg.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EgressBurnEvidenceV0 {
    pub terp_tx_hash: Option<String>,
    pub burn: EgressBurnPublic,
    /// `"mock_verify_lab"` | `"zk_api"`.
    pub proof_mode: String,
    pub settle_receipt_ref: Option<String>,
}

/// Zcash leg result (lab or prod).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ZecEgressReceiptV0 {
    pub dest_display: String,
    pub dest_owner_binding_hex: String,
    pub dest_kind: DestKind,
    pub zec_txid: Option<String>,
    pub amount_zat: u64,
    /// `"lab_inventory_pay"` | `"lc_mint"` | ...
    pub mode: String,
    /// Continuity with Terp burn ν.
    pub burn_nullifier_hex: String,
}

/// Host-side egress nullifier set + optional leaf / burned-cm stubs.
#[derive(Clone, Debug, Default)]
pub struct EgressSeamState {
    pub nullifiers: HashSet<[u8; 32]>,
    /// Burned cms (stub spent-set; not pool ν domain).
    pub burned_cms: HashSet<Cm32>,
    pub tree_leaves: u64,
    pub allowed_root: Option<Cm32>,
}

/// Settle-like openings used to build an egress burn after private swap.
///
/// Mirrors G3 settle surface: `cm_out`, amount, dest seal, openings for ν.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettleLikeOpening {
    pub asset_id: AssetId32,
    pub value: u64,
    pub cm: Cm32,
    pub rcm: [u8; 32],
    /// G4 sealed dest (owner_binding on ZEC SEAM note).
    pub dest_seal: [u8; 32],
    pub dest_kind: DestKind,
    pub root: Cm32,
    pub source_pool_id: Option<u64>,
    pub path_position: u64,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EgressError {
    /// `dest_commitment` ≠ sealed G4 / witness owner_binding.
    ErrDestMismatch,
    /// value 0 / empty cm / empty rcm / zero dest.
    ErrBadAmount,
    /// Nullifier does not re-derive from cm ‖ rcm under egress domain.
    ErrNullifierMismatch,
    /// Egress ν already spent (double egress).
    ErrNullifierExists,
    /// Root not in allowed window (when host pins root).
    ErrBadRoot,
    /// Schema / structural failure.
    ErrSchema,
    /// Egress ν collides with pool or deposit domain derivation (domain sep).
    ErrNullifierDomain,
}

pub type EgressResult<T> = Result<T, EgressError>;

// ---------------------------------------------------------------------------
// Nullifier
// ---------------------------------------------------------------------------

/// `egress_ν = SHA256(b"egress-nf-v0" ‖ cm_spent ‖ rcm)`.
pub fn egress_nullifier(cm: &Cm32, rcm: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(EGRESS_NF_LABEL);
    h.update(cm);
    h.update(rcm);
    let d = h.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&d);
    out
}

/// Deposit-domain synthetic ν for inequality checks only:
/// `H("terp-btc-deposit-nu-v0" ‖ cm ‖ rcm)`.
pub fn synthetic_deposit_nu(cm: &Cm32, rcm: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(DEPOSIT_NU_LABEL);
    h.update(cm);
    h.update(rcm);
    let d = h.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&d);
    out
}

// ---------------------------------------------------------------------------
// Validate / apply
// ---------------------------------------------------------------------------

/// Structural validation of Option D egress burn (no ZK, no tree crypto).
///
/// Fail-closed:
/// - `dest_commitment` must equal witness `owner_binding` (G4 seal on corridor)
/// - value > 0; cm / rcm / dest non-zero
/// - public nullifier == `egress_nullifier(cm, rcm)`
/// - egress ν ≠ pool-nf and ≠ deposit-nu for same openings (domain sep)
///
/// `sealed_dest`: optional preauth G4 seal; when `Some`, must equal `public.dest_commitment`.
pub fn validate_egress_burn(
    public: &EgressBurnPublic,
    witness: &EgressBurnWitness,
    sealed_dest: Option<&[u8; 32]>,
) -> EgressResult<()> {
    if public.value == 0 {
        return Err(EgressError::ErrBadAmount);
    }
    if public.cm_spent == [0u8; 32] || witness.rcm == [0u8; 32] {
        return Err(EgressError::ErrSchema);
    }
    if public.dest_commitment == [0u8; 32] {
        return Err(EgressError::ErrBadAmount);
    }
    if public.asset_id == [0u8; 32] {
        return Err(EgressError::ErrSchema);
    }

    // Fail-closed: witness owner must match public dest commitment (corridor product).
    if witness.owner_binding != public.dest_commitment {
        return Err(EgressError::ErrDestMismatch);
    }
    // Fail-closed: optional external G4 seal must match statement dest.
    if let Some(seal) = sealed_dest {
        if public.dest_commitment != *seal {
            return Err(EgressError::ErrDestMismatch);
        }
    }

    let derived = egress_nullifier(&public.cm_spent, &witness.rcm);
    if derived != public.nullifier {
        return Err(EgressError::ErrNullifierMismatch);
    }

    // Domain separation: same (cm, rcm) must not yield pool/deposit ν as egress ν.
    let pool_nf: PoolNullifier32 = synthetic_pool_spend_nf(&public.cm_spent, &witness.rcm);
    if public.nullifier == pool_nf {
        return Err(EgressError::ErrNullifierDomain);
    }
    let dep_nf = synthetic_deposit_nu(&public.cm_spent, &witness.rcm);
    if public.nullifier == dep_nf {
        return Err(EgressError::ErrNullifierDomain);
    }

    Ok(())
}

/// Apply a validated egress burn to host stub state (ν set + burned cm).
///
/// Does **not** authorize Zcash pay — only records Terp-side burn evidence inputs.
pub fn apply_egress_burn(
    state: &mut EgressSeamState,
    public: &EgressBurnPublic,
    witness: &EgressBurnWitness,
    sealed_dest: Option<&[u8; 32]>,
) -> EgressResult<EgressBurnEvidenceV0> {
    if let Some(root) = state.allowed_root {
        if public.root != root {
            return Err(EgressError::ErrBadRoot);
        }
    }

    validate_egress_burn(public, witness, sealed_dest)?;

    if state.nullifiers.contains(&public.nullifier) {
        return Err(EgressError::ErrNullifierExists);
    }
    if state.burned_cms.contains(&public.cm_spent) {
        return Err(EgressError::ErrNullifierExists);
    }

    state.nullifiers.insert(public.nullifier);
    state.burned_cms.insert(public.cm_spent);
    // Burn removes a leaf from spendable set (stub: count as consumed, no new out).
    state.tree_leaves = state.tree_leaves.saturating_sub(0);
    if state.allowed_root.is_none() {
        state.allowed_root = Some(public.root);
    }

    Ok(EgressBurnEvidenceV0 {
        terp_tx_hash: None,
        burn: public.clone(),
        proof_mode: "mock_verify_lab".to_string(),
        settle_receipt_ref: None,
    })
}

// ---------------------------------------------------------------------------
// Builder from settle-like openings
// ---------------------------------------------------------------------------

/// Build [`EgressBurnV0`] from settle-like openings (cm, rcm, value, dest seal).
///
/// Fail-closed if openings are zeroed or dest seal is empty.
pub fn build_egress_burn_from_settle(
    opening: &SettleLikeOpening,
) -> EgressResult<EgressBurnV0> {
    if opening.value == 0 {
        return Err(EgressError::ErrBadAmount);
    }
    if opening.cm == [0u8; 32] || opening.rcm == [0u8; 32] {
        return Err(EgressError::ErrSchema);
    }
    if opening.dest_seal == [0u8; 32] {
        return Err(EgressError::ErrBadAmount);
    }
    if opening.asset_id == [0u8; 32] {
        return Err(EgressError::ErrSchema);
    }

    let nullifier = egress_nullifier(&opening.cm, &opening.rcm);
    let public = EgressBurnPublic {
        asset_id: opening.asset_id,
        value: opening.value,
        cm_spent: opening.cm,
        nullifier,
        dest_commitment: opening.dest_seal,
        dest_kind: opening.dest_kind,
        root: opening.root,
        source_pool_id: opening.source_pool_id,
    };
    let witness = EgressBurnWitness {
        rcm: opening.rcm,
        owner_binding: opening.dest_seal,
        path_position: opening.path_position,
    };

    validate_egress_burn(&public, &witness, Some(&opening.dest_seal))?;

    Ok(EgressBurnV0 { public, witness })
}

/// Build settle-like opening from swap output note fields (cm, rcm, value, dest).
///
/// Uses abstract leaf recompute when `cm` is derived from openings; caller may
/// pass the settle `cm_out` directly as `cm`.
pub fn settle_opening_from_note_fields(
    asset_id: AssetId32,
    value: u64,
    dest_seal: [u8; 32],
    rcm: [u8; 32],
    dest_kind: DestKind,
    root: Cm32,
    source_pool_id: Option<u64>,
    path_position: u64,
) -> SettleLikeOpening {
    let cm = abstract_leaf_cm_local(&asset_id, value, &dest_seal, &rcm);
    SettleLikeOpening {
        asset_id,
        value,
        cm,
        rcm,
        dest_seal,
        dest_kind,
        root,
        source_pool_id,
        path_position,
    }
}

fn abstract_leaf_cm_local(
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

/// Hex encode 32 bytes (lowercase) for receipt fields.
pub fn hex32(bytes: &[u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(64);
    for &b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0xf) as usize] as char);
    }
    s
}

/// Lab helper: build a Zcash-side receipt stub **only after** burn evidence exists.
///
/// Product rule: Zcash pay without burn evidence is rejected (checked here).
pub fn lab_receipt_after_burn(
    evidence: &EgressBurnEvidenceV0,
    dest_display: impl Into<String>,
    zec_txid: Option<String>,
    mode: impl Into<String>,
) -> EgressResult<ZecEgressReceiptV0> {
    // Evidence must carry a non-zero nullifier (burn was applied/validated).
    if evidence.burn.nullifier == [0u8; 32] || evidence.burn.value == 0 {
        return Err(EgressError::ErrSchema);
    }
    Ok(ZecEgressReceiptV0 {
        dest_display: dest_display.into(),
        dest_owner_binding_hex: hex32(&evidence.burn.dest_commitment),
        dest_kind: evidence.burn.dest_kind,
        zec_txid,
        amount_zat: evidence.burn.value,
        mode: mode.into(),
        burn_nullifier_hex: hex32(&evidence.burn.nullifier),
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{asset_id_hub, abstract_leaf_cm, POOL_NF_LABEL};

    fn arr32(fill: u8) -> [u8; 32] {
        [fill; 32]
    }

    fn demo_zec_asset() -> AssetId32 {
        let mut a = [0u8; 32];
        a[0] = b'Z';
        a[1] = b'E';
        a[2] = b'C';
        a
    }

    fn demo_opening_fixed(dest: [u8; 32], value: u64) -> SettleLikeOpening {
        settle_opening_from_note_fields(
            demo_zec_asset(),
            value,
            dest,
            arr32(0xB2),
            DestKind::Shielded,
            arr32(0x11),
            Some(1),
            0,
        )
    }

    #[test]
    fn egress_nf_label_is_normative() {
        assert_eq!(EGRESS_NF_LABEL, b"egress-nf-v0");
        assert_ne!(EGRESS_NF_LABEL, POOL_NF_LABEL);
        assert_ne!(EGRESS_NF_LABEL, DEPOSIT_NU_LABEL);
    }

    #[test]
    fn egress_nullifier_domain_separated_from_pool_and_deposit() {
        let cm = arr32(0xAA);
        let rcm = arr32(0xBB);
        let eg = egress_nullifier(&cm, &rcm);
        let pool = synthetic_pool_spend_nf(&cm, &rcm);
        let dep = synthetic_deposit_nu(&cm, &rcm);
        assert_ne!(eg, pool);
        assert_ne!(eg, dep);
        assert_ne!(pool, dep);
        assert_ne!(eg, [0u8; 32]);
    }

    #[test]
    fn build_and_validate_egress_burn_happy() {
        let dest = arr32(0xD5);
        let opening = demo_opening_fixed(dest, 50_000);
        let burn = build_egress_burn_from_settle(&opening).expect("build");
        assert_eq!(burn.public.dest_commitment, dest);
        assert_eq!(burn.witness.owner_binding, dest);
        assert_eq!(burn.public.value, 50_000);
        assert_eq!(
            burn.public.nullifier,
            egress_nullifier(&opening.cm, &opening.rcm)
        );
        // cm matches abstract leaf of openings
        assert_eq!(
            opening.cm,
            abstract_leaf_cm(&opening.asset_id, opening.value, &dest, &opening.rcm)
        );
        validate_egress_burn(&burn.public, &burn.witness, Some(&dest)).expect("validate");
    }

    #[test]
    fn dest_mismatch_fail_closed() {
        let dest = arr32(0xD5);
        let other = arr32(0xEE);
        let opening = demo_opening_fixed(dest, 10_000);
        let mut burn = build_egress_burn_from_settle(&opening).expect("build");
        // Redirect dest after seal — rejected
        burn.public.dest_commitment = other;
        let err = validate_egress_burn(&burn.public, &burn.witness, Some(&dest)).unwrap_err();
        assert_eq!(err, EgressError::ErrDestMismatch);

        // Witness owner ≠ public dest
        burn.public.dest_commitment = dest;
        burn.witness.owner_binding = other;
        let err = validate_egress_burn(&burn.public, &burn.witness, Some(&dest)).unwrap_err();
        assert_eq!(err, EgressError::ErrDestMismatch);
    }

    #[test]
    fn sealed_dest_external_mismatch_fail_closed() {
        let dest = arr32(0xD5);
        let opening = demo_opening_fixed(dest, 10_000);
        let burn = build_egress_burn_from_settle(&opening).expect("build");
        let wrong_seal = arr32(0xFF);
        let err = validate_egress_burn(&burn.public, &burn.witness, Some(&wrong_seal)).unwrap_err();
        assert_eq!(err, EgressError::ErrDestMismatch);
    }

    #[test]
    fn apply_egress_burn_records_nullifier_once() {
        let dest = arr32(0xD5);
        let opening = demo_opening_fixed(dest, 12_345);
        let burn = build_egress_burn_from_settle(&opening).expect("build");
        let mut state = EgressSeamState {
            allowed_root: Some(arr32(0x11)),
            ..Default::default()
        };

        let evidence =
            apply_egress_burn(&mut state, &burn.public, &burn.witness, Some(&dest)).expect("apply");
        assert_eq!(evidence.proof_mode, "mock_verify_lab");
        assert!(state.nullifiers.contains(&burn.public.nullifier));
        assert!(state.burned_cms.contains(&burn.public.cm_spent));

        // Double egress reject
        let err = apply_egress_burn(&mut state, &burn.public, &burn.witness, Some(&dest))
            .unwrap_err();
        assert_eq!(err, EgressError::ErrNullifierExists);
    }

    #[test]
    fn value_zero_rejected() {
        let dest = arr32(0xD5);
        let mut opening = demo_opening_fixed(dest, 1);
        opening.value = 0;
        let err = build_egress_burn_from_settle(&opening).unwrap_err();
        assert_eq!(err, EgressError::ErrBadAmount);
    }

    #[test]
    fn bad_nullifier_rejected() {
        let dest = arr32(0xD5);
        let opening = demo_opening_fixed(dest, 100);
        let mut burn = build_egress_burn_from_settle(&opening).expect("build");
        burn.public.nullifier = arr32(0x00);
        let err = validate_egress_burn(&burn.public, &burn.witness, Some(&dest)).unwrap_err();
        assert_eq!(err, EgressError::ErrNullifierMismatch);
    }

    #[test]
    fn transparent_and_shielded_dest_kinds_ok() {
        for kind in [DestKind::Transparent, DestKind::Shielded] {
            let dest = arr32(0xA1);
            let mut opening = demo_opening_fixed(dest, 999);
            opening.dest_kind = kind;
            let burn = build_egress_burn_from_settle(&opening).expect("build");
            assert_eq!(burn.public.dest_kind, kind);
        }
    }

    #[test]
    fn lab_receipt_requires_burn_evidence() {
        let dest = arr32(0xD5);
        let opening = demo_opening_fixed(dest, 77);
        let burn = build_egress_burn_from_settle(&opening).expect("build");
        let mut state = EgressSeamState::default();
        let evidence =
            apply_egress_burn(&mut state, &burn.public, &burn.witness, Some(&dest)).expect("apply");
        let receipt = lab_receipt_after_burn(
            &evidence,
            "u1testshieldedua",
            Some("txid-lab-1".into()),
            "lab_inventory_pay",
        )
        .expect("receipt");
        assert_eq!(receipt.amount_zat, 77);
        assert_eq!(receipt.dest_owner_binding_hex, hex32(&dest));
        assert_eq!(receipt.burn_nullifier_hex, hex32(&burn.public.nullifier));
        assert_eq!(receipt.mode, "lab_inventory_pay");

        // Empty evidence reject
        let mut bad = evidence.clone();
        bad.burn.nullifier = [0u8; 32];
        assert_eq!(
            lab_receipt_after_burn(&bad, "x", None, "lab_inventory_pay"),
            Err(EgressError::ErrSchema)
        );
    }

    #[test]
    fn builder_from_settle_cm_rcm_value_dest() {
        // Explicit settle fields (as G3 would hand off)
        let asset = demo_zec_asset();
        let value = 42u64;
        let dest = arr32(0xC0);
        let rcm = arr32(0xC1);
        let cm = abstract_leaf_cm(&asset, value, &dest, &rcm);
        let opening = SettleLikeOpening {
            asset_id: asset,
            value,
            cm,
            rcm,
            dest_seal: dest,
            dest_kind: DestKind::Transparent,
            root: arr32(0x22),
            source_pool_id: Some(7),
            path_position: 3,
        };
        let burn = build_egress_burn_from_settle(&opening).expect("from settle");
        assert_eq!(burn.public.cm_spent, cm);
        assert_eq!(burn.public.source_pool_id, Some(7));
        assert_eq!(burn.witness.path_position, 3);
        assert_eq!(burn.public.dest_kind, DestKind::Transparent);
    }

    #[test]
    fn hub_asset_still_builds_structurally() {
        // Any registered 32B asset shape works at pure layer (ZEC id in product).
        let dest = arr32(0xD5);
        let opening = settle_opening_from_note_fields(
            asset_id_hub(),
            1,
            dest,
            arr32(0xB2),
            DestKind::Transparent,
            arr32(0x11),
            None,
            9,
        );
        let burn = build_egress_burn_from_settle(&opening).expect("hub asset ok pure");
        assert_eq!(burn.public.asset_id, asset_id_hub());
    }
}
