//! FROZEN copy of the deleted `merkle::merkle_multi_proof` ("the octopus",
//! removed from the protocol in 3251bc5 when openings moved to cap layers).
//!
//! The CUDA oracle harness (`cuda-ghash/merkle_open.hpp`,
//! `test_merkle_open.cpp`, and the L0 replay in `test_ligerito_l0`) mirrors
//! the dump bins byte-for-byte, so the bins must keep producing the SAME
//! vectors they produced when the port was written — this copy pins that,
//! independent of where the live protocol goes. Do not "modernize" it.

use flock_prover::merkle::Hash;

/// Deduplicated Merkle multi-proof: the sibling hashes needed to verify the
/// leaves at `positions` against the root, bottom-up, with siblings shared
/// between active nodes elided.
pub fn merkle_multi_proof(tree: &[Hash], num_leaves: usize, positions: &[usize]) -> Vec<Hash> {
    assert!(num_leaves.is_power_of_two() && num_leaves > 0);
    assert_eq!(tree.len(), 2 * num_leaves - 1);

    if positions.is_empty() || num_leaves == 1 {
        return Vec::new();
    }

    let mut active: Vec<usize> = positions.to_vec();
    active.sort_unstable();
    active.dedup();
    debug_assert!(active.iter().all(|&p| p < num_leaves));

    let mut proof = Vec::new();
    let mut level_start = 0usize;
    let mut level_len = num_leaves;

    while level_len > 1 {
        let mut next = Vec::with_capacity(active.len());
        let mut i = 0;
        while i < active.len() {
            let p = active[i];
            let sib_active = i + 1 < active.len() && active[i + 1] == (p ^ 1);
            if sib_active {
                // Both children active — no sibling hash needed; both fold into
                // the same parent.
                i += 2;
            } else {
                // Sibling not in active set; emit it.
                proof.push(tree[level_start + (p ^ 1)]);
                i += 1;
            }
            next.push(p >> 1);
        }
        // `next` is sorted-unique by construction: the input was sorted-unique;
        // consecutive sibling pairs (handled above) collapse to one; otherwise
        // p >> 1 preserves strict ordering.
        active = next;
        level_start += level_len;
        level_len >>= 1;
    }

    proof
}
