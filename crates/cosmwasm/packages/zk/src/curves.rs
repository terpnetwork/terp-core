mod vesta;
pub(crate) use vesta::{VestaInstance, VestaVerifyingKey};

#[cfg(feature = "bn254")]
mod bn254;
#[cfg(feature = "bn254")]
pub use bn254::{
    build_bn254_circuit_blob, encode_public_inputs_be, serialize_ark_proof, serialize_ark_vk,
    Bn254Instance, Bn254Scalar, Bn254VerifyingKey,
};

#[cfg(feature = "bn254")]
pub mod snarkjs;
#[cfg(feature = "bn254")]
pub use snarkjs::{
    convert_snarkjs_proof_json, convert_snarkjs_public_json, convert_snarkjs_vkey_json,
    verify_snarkjs_fixtures, SnarkjsProof, SnarkjsVerifyingKey,
};

mod flock;
#[cfg(feature = "halo2-kzg")]
mod halo2_kzg;
mod stwo;
mod vote;
pub use flock::{
    prove_flock, verify_flock_proof, FlockInstance, FlockVerifyingKey, FLOCK_CURVE_ID,
    FLOCK_HOST_VERIFY, FLOCK_PROVER_ID,
};
#[cfg(feature = "halo2-kzg")]
pub use halo2_kzg::{kzg_footer, Halo2KzgInstance, Halo2KzgVerifyingKey, HALO2_KZG_CURVE_ID};
pub use stwo::{
    verify_stwo_proof, StwoInstance, StwoVerifyingKey, STWO_CURVE_ID, STWO_HOST_VERIFY,
    STWO_PROVER_ID,
};
pub use vote::{VoteCircuitId, VoteInstance, VoteVerifyingKey};

use crate::{ZkError, ZkResult};

pub trait ConstraintSystemTrait: Send + Sync + std::fmt::Debug + 'static {
    fn write(&self) -> ZkResult<()>;
}
pub trait VerifyingKeyTrait: Send + Sync + 'static {
    fn curve_id(&self) -> u32;
    // fn cs(&self) -> impl ConstraintSystemTrait;
    fn verify(
        &self,
        proof: &crate::Proof,
        instances: &[impl Into<crate::AnyInstance>],
    ) -> ZkResult<()>;
    // fn to_bytes(&self) -> ZkResult<Vec<u8>>;
    fn read() -> ZkResult<()>;
    fn write(&self) -> ZkResult<()>;
}

pub trait InstanceTrait: Send + Sync + std::fmt::Debug + 'static {
    fn curve_id(&self) -> u32;
    fn to_bytes(&self) -> Vec<u8>;
}

/// Generic curve trait for the zk-wasmvm.
///
/// Bounds are intentionally minimal — `Scalar` and `Affine` do not require
/// `group::ff::PrimeField` or `pasta_curves::arithmetic::CurveAffine`, so
/// any curve library (arkworks, pasta, etc.) can implement it without
/// adapting to a specific framework's trait hierarchy.
///
/// Concrete methods (verify, scalar_from_bytes, etc.) live in the impl
/// blocks, not on the trait — generic code dispatches through
/// `AnyVerifyingKey` / `AnyInstance` enum variants, not through trait
/// methods on `ZkCurve`.
pub trait ZkCurve: 'static + Clone + Copy + Send + Sync + std::fmt::Debug {
    /// Scalar field element type. Must implement `Clone + Debug` for
    /// `CwInstance<Self>` which derives both.
    type Scalar: Send + Sync + 'static + Clone + std::fmt::Debug;
    /// Affine curve point type. No supertraits required — the concrete
    /// impl handles all curve operations.
    type Affine: Send + Sync + 'static;

    type Params: std::fmt::Debug + Clone;
    type Instance: std::fmt::Debug + Clone;
    type VerifyingKey: std::fmt::Debug + Clone;
    type ProvingKey: std::fmt::Debug;
    type ConstraintSystem: std::fmt::Debug;

    const ID: u32;

    fn scalar_from_bytes(bytes: &[u8; 32]) -> Option<Self::Scalar>;
    fn scalar_to_bytes(s: &Self::Scalar) -> [u8; 32];
}

/// Curve identifier — the sole routing key for VK dispatch.
///
/// Each distinct circuit/curve combination gets its own unique ID, making
/// the `curve_id` field in `CircuitFooter` informationally self-describing.
/// A reader can look at `curve_id` alone and know exactly which circuit
/// and curve the footer refers to.
///
/// | ID | Curve | Circuit | Proving system |
/// |----|-------|---------|---------------|
/// | 0  | Pasta | Generic Plonkish | Plonkish (Halo2 IPA) |
/// | 1  | Pasta | Vote delegation (ZKP #1) | Plonkish (Halo2) |
/// | 2  | Pasta | Vote commitment (ZKP #2) | Plonkish (Halo2) |
/// | 3  | Pasta | Share reveal (ZKP #3) | Plonkish (Halo2) |
/// | 4  | BN254 | Generic Groth16 (snarkjs) | Groth16 |
/// | 5  | M31 | Lean SSLE / fold | Stwo |
/// | 6  | BN256 | zkjwt.passkey | Halo2 KZG |
/// | 7  | Flock | Hash R1CS / archive | Ligerito |
///
/// Terp product uses: `crates/cosmwasm/book/src/using/vm/curve-use-cases.md`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CurveType {
    /// Pasta curve, generic Plonkish (Vesta).
    Pasta = 0,
    /// Pasta curve, vote delegation circuit (ZKP #1).
    VoteDelegation = 1,
    /// Pasta curve, vote commitment circuit (ZKP #2).
    VoteCommitment = 2,
    /// Pasta curve, share reveal circuit (ZKP #3).
    ShareReveal = 3,
    /// BN254 curve (alt_bn128), Groth16.
    #[cfg(feature = "bn254")]
    Bn254 = 4,
    /// M31 / Circle STARK (Stwo).
    M31 = 5,
    /// BN256 Halo2-axiom KZG / SHPLONK (zkjwt.passkey).
    #[cfg(feature = "halo2-kzg")]
    Bn256Kzg = 6,
    /// Flock R1CS / Ligerito (host `verify_ligerito`; not a BLAKE3 digest).
    FlockBlake3 = 7,
}

impl TryFrom<u8> for CurveType {
    type Error = ZkError;

    fn try_from(v: u8) -> Result<Self, Self::Error> {
        match v {
            0 => Ok(CurveType::Pasta),
            1 => Ok(CurveType::VoteDelegation),
            2 => Ok(CurveType::VoteCommitment),
            3 => Ok(CurveType::ShareReveal),
            #[cfg(feature = "bn254")]
            4 => Ok(CurveType::Bn254),
            5 => Ok(CurveType::M31),
            #[cfg(feature = "halo2-kzg")]
            6 => Ok(CurveType::Bn256Kzg),
            7 => Ok(CurveType::FlockBlake3),
            _ => Err(ZkError::new_err("bad CurveType")),
        }
    }
}
impl Into<u8> for CurveType {
    fn into(self) -> u8 {
        match self {
            CurveType::Pasta => 0,
            CurveType::VoteDelegation => 1,
            CurveType::VoteCommitment => 2,
            CurveType::ShareReveal => 3,
            #[cfg(feature = "bn254")]
            CurveType::Bn254 => 4,
            CurveType::M31 => 5,
            #[cfg(feature = "halo2-kzg")]
            CurveType::Bn256Kzg => 6,
            CurveType::FlockBlake3 => 7,
        }
    }
}
