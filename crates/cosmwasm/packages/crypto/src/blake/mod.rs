//! Deterministic native hash digests for optional CosmWasm host functions.
//!
//! **Not GPU-accelerated.** Consensus host functions must be pure functions of
//! their inputs (bit-identical across validators). GPU kernels break that
//! contract — see plan `zkvm-bn254-multicurve-hash-vote.md` §4.
//!
//! Enable with feature `hash-blake`.

#![cfg(feature = "hash-blake")]

mod b2b_256;
mod b2b_512;
mod b3;

pub use b2b_256::blake2b_256;
pub use b2b_512::blake2b_512;
pub use b3::blake3_256;
