//! Algebraic Poseidon hashes used across Terp ecosystems.
//!
//! | Variant | Field / curve | Spec | Ecosystem |
//! |---------|---------------|------|-----------|
//! | **Pasta Pallas** | `pasta_curves::pallas::Base` | Zcash Orchard `P128Pow5T3` (T=3, RATE=2) | Halo2, vote-sdk, Orchard |
//! | **Pasta Vesta** | `pasta_curves::vesta::Base` | same `P128Pow5T3` | Halo2 cycle dual |
//! | **Poseidon377** | BLS12-377 scalar (`decaf377::Fq`) | Penumbra `poseidon377` rate-1…7 | Penumbra TCT / notes |
//!
//! **Not GPU-accelerated.** Consensus hosts are pure functions of their inputs
//! (bit-identical across validators). See plan §4 / GPU track.
//!
//! Enable with feature `hash-poseidon`.
//!
//! ## Wire format (all variants)
//! - Each field element is **32-byte little-endian canonical** encoding.
//! - Pasta inputs: concatenated elements (`len % 32 == 0`); `n = len/32` in `1..=16`.
//! - Poseidon377: domain separator (32 bytes) + concatenated message elements
//!   (`n` in `1..=7`, matching `hash_1`…`hash_7`).

#![cfg(feature = "hash-poseidon")]

mod bls12_377;
mod pasta;

pub use bls12_377::{
    poseidon377_hash, poseidon377_hash_bytes, POSEIDON377_FIELD_BYTES, POSEIDON377_MAX_ARITY,
    POSEIDON377_MIN_ARITY,
};
pub use pasta::{
    poseidon_hash_pallas, poseidon_hash_pallas_bytes, poseidon_hash_vesta,
    poseidon_hash_vesta_bytes, PASTA_FIELD_BYTES, PASTA_MAX_ARITY,
};
