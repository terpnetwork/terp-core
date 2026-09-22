//! BN254 (alt_bn128) host primitives — optional multi-curve library.
//!
//! Implementation lives in in-tree `packages/crypto-bn254`.
//! Enable with feature `bn254`. Never depends on junoclaw checkout paths.
//!
//! Host functions (when wired through cosmwasm-vm):
//! - [`bn254_add`] — EIP-196 ECADD
//! - [`bn254_scalar_mul`] — EIP-196 ECMUL
//! - [`bn254_pairing_equality`] — EIP-197 pairing check
//!
//! See `crates/junoclaw/docs/ADR-001-BN254-PRECOMPILE.md` and
//! `.hermes/plans/zkvm-bn254-multicurve-hash-vote.md`.

#![cfg(feature = "bn254")]

pub use cosmwasm_crypto_bn254::{
    bn254_add, bn254_pairing_equality, bn254_scalar_mul, Bn254Error, FQ_BYTES, FR_BYTES, G1_BYTES,
    G2_BYTES, PAIR_BYTES,
};

// Re-export gas helpers for cosmwasm-vm gas_config wiring.
pub use cosmwasm_crypto_bn254::gas;
