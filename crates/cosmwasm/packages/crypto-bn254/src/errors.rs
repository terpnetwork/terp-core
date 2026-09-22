//! Error taxonomy for BN254 host functions.
//!
//! The variants are deliberately specific so that on-chain revert messages
//! tell a contract author exactly what went wrong with their proof, matching
//! the style of the existing BLS12-381 host function errors in
//! `cosmwasm-crypto`.

#[cfg(not(feature = "std"))]
use core::fmt;
#[cfg(feature = "std")]
use std::fmt;

/// All errors that can be produced by this crate's public API.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum Bn254Error {
    /// Input length does not match the exact required size for this op.
    ///
    /// - `bn254_add`: 128 bytes
    /// - `bn254_scalar_mul`: 96 bytes
    InvalidInputLength {
        /// Expected length in bytes.
        expected: usize,
        /// Actual length that was supplied.
        actual: usize,
    },

    /// `bn254_pairing_equality` input is not a whole number of 192-byte pairs.
    InvalidPairingInputLength(
        /// The offending length in bytes.
        usize,
    ),

    /// Decoded point is not on the BN254 curve `y² = x³ + 3`.
    NotOnCurve,

    /// Decoded G2 point is on the curve but not in the prime-order subgroup.
    ///
    /// G1 has cofactor 1 on BN254, so this variant is only produced by the
    /// G2 decoder.
    NotInSubgroup,

    /// A 32-byte coordinate encodes a value ≥ the base-field modulus `p`.
    InvalidFieldElement,

    /// Backend arithmetic failed. This variant should be unreachable for
    /// well-formed input; its presence is a safety net against future
    /// arkworks changes.
    BackendError(&'static str),
}

impl fmt::Display for Bn254Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInputLength { expected, actual } => write!(
                f,
                "BN254: invalid input length: expected {expected} bytes, got {actual}"
            ),
            Self::InvalidPairingInputLength(n) => write!(
                f,
                "BN254: pairing input length {n} is not a multiple of 192"
            ),
            Self::NotOnCurve => f.write_str("BN254: point is not on the curve"),
            Self::NotInSubgroup => {
                f.write_str("BN254: G2 point is not in the prime-order subgroup")
            }
            Self::InvalidFieldElement => {
                f.write_str("BN254: coordinate is not a canonical base-field element (>= p)")
            }
            Self::BackendError(s) => write!(f, "BN254: backend error: {s}"),
        }
    }
}

#[cfg(feature = "std")]
impl std::error::Error for Bn254Error {}
