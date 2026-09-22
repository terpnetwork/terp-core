//! CosmWasm is a smart contract platform for the Cosmos ecosystem.
//! This crate implements cryptography-related functions for CosmWasm contracts and internal crates.
//!
//! **Note:** This crate is intended to be used in internal crates / utils only.
//! Please don't use any of these types directly, as they might change frequently,
//! or be removed in the future. This crate does not adhere to semantic versioning.
//!
//! For more information, see: <https://cosmwasm.cosmos.network>

// digest 0.10 GenericArray deprecations via k256/p256 until those crates move to 1.x
#![allow(deprecated)]

extern crate alloc;

mod backtrace;
mod bls12_381;
mod ecdsa;
mod ed25519;
mod errors;
mod identity_digest;
mod secp256k1;
mod secp256r1;

// Multi-curve / multi-hash libraries (feature-gated).
#[cfg(feature = "hash-blake")]
pub mod blake;
#[cfg(feature = "bn254")]
mod bn254;
#[cfg(feature = "hash-poseidon")]
pub mod poseidon;
#[cfg(feature = "redpallas")]
pub mod redpallas;

#[doc(hidden)]
pub use crate::bls12_381::{
    bls12_381_aggregate_g1, bls12_381_aggregate_g2, bls12_381_g1_is_identity,
    bls12_381_g2_is_identity, bls12_381_hash_to_g1, bls12_381_hash_to_g2,
    bls12_381_pairing_equality, HashFunction,
};
#[doc(hidden)]
pub use crate::ecdsa::{ECDSA_PUBKEY_MAX_LEN, ECDSA_SIGNATURE_LEN, MESSAGE_HASH_MAX_LEN};
#[doc(hidden)]
pub use crate::ed25519::EDDSA_PUBKEY_LEN;
#[doc(hidden)]
pub use crate::ed25519::{ed25519_batch_verify, ed25519_verify};
#[doc(hidden)]
pub use crate::errors::{
    Aggregation as AggregationError, CryptoError, CryptoResult,
    PairingEquality as PairingEqualityError,
};
#[doc(hidden)]
pub use crate::secp256k1::{secp256k1_recover_pubkey, secp256k1_verify};
#[doc(hidden)]
pub use crate::secp256r1::{secp256r1_recover_pubkey, secp256r1_verify};

// Optional BN254 (Groth16 / EIP-196/197 layout) — multi-curve showcase.
#[cfg(feature = "bn254")]
#[doc(hidden)]
pub use crate::bn254::{
    bn254_add, bn254_pairing_equality, bn254_scalar_mul, gas, Bn254Error, FQ_BYTES, FR_BYTES,
    G1_BYTES, G2_BYTES, PAIR_BYTES,
};

// Optional deterministic hash digests for host imports.
#[cfg(feature = "hash-blake")]
#[doc(hidden)]
pub use crate::blake::{blake2b_256, blake2b_512, blake3_256};

// Algebraic Poseidon (Zcash Pasta + Penumbra BLS12-377) for host imports.
#[cfg(feature = "hash-poseidon")]
#[doc(hidden)]
pub use crate::poseidon::{
    poseidon377_hash, poseidon377_hash_bytes, poseidon_hash_pallas, poseidon_hash_pallas_bytes,
    poseidon_hash_vesta, poseidon_hash_vesta_bytes, PASTA_FIELD_BYTES, PASTA_MAX_ARITY,
    POSEIDON377_FIELD_BYTES, POSEIDON377_MAX_ARITY, POSEIDON377_MIN_ARITY,
};

// RedPallas (Orchard) + RedJubjub (Sapling) signature verification.
#[cfg(feature = "redpallas")]
#[doc(hidden)]
pub use crate::redpallas::{
    redjubjub_binding_verify, redjubjub_spendauth_verify, redpallas_binding_verify,
    redpallas_spendauth_verify, verify_spend_auth_sig, REDPALLAS_MESSAGE_MAX_LEN,
    REDPALLAS_SIGNATURE_LEN, REDPALLAS_VK_LEN,
};

pub(crate) use backtrace::BT;
