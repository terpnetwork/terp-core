//! Gas schedule constants for BN254 host functions.
//!
//! The numbers here are expressed in **CosmWasm VM gas** — the internal
//! unit used by `cosmwasm-vm` when instrumenting Wasm execution. The
//! conversion to Cosmos-SDK gas uses `wasmd`'s default multiplier of `100`:
//!
//! ```text
//! sdk_gas = wasm_gas / 100
//! ```
//!
//! which is the same relationship applied to the existing BLS12-381 host
//! functions in `cosmwasm-vm`.
//!
//! The SDK-gas targets are taken directly from EIP-1108 (Istanbul):
//!
//! | Operation                 | SDK gas                | CosmWasm VM gas           |
//! |---------------------------|------------------------|---------------------------|
//! | `bn254_add`               | 150                    | 15 000                    |
//! | `bn254_scalar_mul`        | 6 000                  | 600 000                   |
//! | `bn254_pairing_equality`  | 45 000 + 34 000·N      | 4 500 000 + 3 400 000·N   |
//!
//! `N` is the number of `(G1, G2)` pairs supplied to the pairing op. The
//! base cost covers the one final exponentiation; the per-pair cost covers
//! one Miller-loop iteration.
//!
//! These numbers are *ceilings* derived from Ethereum's public schedule.
//! Concrete wall-clock measurements from `benches/bn254.rs` on a 2023
//! Apple M2 Pro are well below them; the headroom is intentional and can
//! be tightened with a follow-up PR once the Juno community converges on
//! a methodology for deriving CosmWasm gas from native runtime.

/// Cost of a single G1 point addition, in CosmWasm VM gas.
pub const BN254_ADD_COST: u64 = 15_000;

/// Cost of a single G1 scalar multiplication, in CosmWasm VM gas.
pub const BN254_SCALAR_MUL_COST: u64 = 600_000;

/// Base cost of a pairing equality check, in CosmWasm VM gas.
///
/// Charged regardless of `N`, including `N = 0`.
pub const BN254_PAIRING_BASE_COST: u64 = 4_500_000;

/// Per-pair cost of a pairing equality check, in CosmWasm VM gas.
pub const BN254_PAIRING_PER_PAIR_COST: u64 = 3_400_000;

/// Total cost for a pairing equality check over `n` `(G1, G2)` pairs.
///
/// Saturates at [`u64::MAX`] to avoid overflow on pathological input
/// lengths; the VM will then reject the call on gas exhaustion anyway.
#[inline]
pub const fn pairing_cost(n: usize) -> u64 {
    let n64 = n as u64;
    match BN254_PAIRING_PER_PAIR_COST.checked_mul(n64) {
        Some(per) => match BN254_PAIRING_BASE_COST.checked_add(per) {
            Some(total) => total,
            None => u64::MAX,
        },
        None => u64::MAX,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_cost_matches_eip1108() {
        // N=0: just the base cost.
        assert_eq!(pairing_cost(0), BN254_PAIRING_BASE_COST);
        // N=3 (typical Groth16): 4_500_000 + 3 * 3_400_000 = 14_700_000.
        assert_eq!(pairing_cost(3), 14_700_000);
        // SDK equivalent: 147 000, which is exactly 45k + 3·34k.
        assert_eq!(pairing_cost(3) / 100, 147_000);
    }

    #[test]
    fn pairing_cost_saturates_without_panic() {
        // Must not panic on overflow.
        let _ = pairing_cost(usize::MAX);
    }
}
