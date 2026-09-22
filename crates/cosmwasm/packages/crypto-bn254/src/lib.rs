//! BN254 (alt_bn128) host-function implementations for the CosmWasm VM.
//!
//! This crate exposes three primitives against the BN254 curve, mirroring
//! Ethereum's precompiles at addresses `0x06`, `0x07`, and `0x08`:
//!
//! | Function                | EVM precompile | Input size | Output size |
//! |-------------------------|----------------|------------|-------------|
//! | [`bn254_add`]           | ECADD          | 128 bytes  | 64 bytes    |
//! | [`bn254_scalar_mul`]    | ECMUL          | 96 bytes   | 64 bytes    |
//! | [`bn254_pairing_equality`] | ECPAIRING    | 192·N bytes | bool      |
//!
//! The byte layout follows EIP-196 / EIP-197: big-endian coordinates, G1 as
//! `(x, y)`, G2 as `(x.c1, x.c0, y.c1, y.c0)`, and `(0, 0)` for the point at
//! infinity.
//!
//! # Determinism
//!
//! - Non-canonical field elements (coordinates ≥ p) are rejected.
//! - Points not on the curve are rejected.
//! - G2 points outside the prime-order subgroup are rejected (required for
//!   pairing soundness; G1 on BN254 has cofactor 1 so no explicit check is
//!   needed).
//! - Scalars are reduced modulo `r` (matches EIP-196 ECMUL semantics; does
//!   not reject).
//! - No randomness, no wall-clock reads, no threading.
//!
//! # Gas semantics
//!
//! See [`gas`] for the cost constants, which mirror EIP-1108 expressed in
//! CosmWasm VM gas (100× SDK gas, matching the existing BLS12-381 host
//! function convention in `cosmwasm-vm`).

#![cfg_attr(not(feature = "std"), no_std)]
#![deny(missing_docs)]
#![deny(unsafe_code)]

extern crate alloc;

mod bn254;
pub mod errors;
pub mod gas;

pub use bn254::{bn254_add, bn254_pairing_equality, bn254_scalar_mul};
pub use errors::Bn254Error;

/// Size of a BN254 base-field element in bytes (big-endian).
pub const FQ_BYTES: usize = 32;

/// Size of a BN254 scalar-field element in bytes (big-endian).
pub const FR_BYTES: usize = 32;

/// Size of a BN254 G1 point in uncompressed affine form (bytes).
pub const G1_BYTES: usize = 64;

/// Size of a BN254 G2 point in uncompressed affine form (bytes).
pub const G2_BYTES: usize = 128;

/// Size of one `(G1, G2)` pair in the pairing-equality input (bytes).
pub const PAIR_BYTES: usize = G1_BYTES + G2_BYTES;
