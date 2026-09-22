//! Host Path A verifiers for [`zk_cosmwasm`] (Stwo + Flock).
//!
//! Excluded from the CosmWasm workspace: `stwo` and vote-sdk disagree on
//! `crypto-common`. libwasmvm (separate workspace) depends on this crate and
//! calls [`install`] at cache init. Guest wasm32 never links this.

pub mod flock;
pub mod stwo;

/// Install Stwo/Flock `OnceLock` hooks on [`zk_cosmwasm`].
pub fn install() {
    stwo::install();
    flock::install();
}
