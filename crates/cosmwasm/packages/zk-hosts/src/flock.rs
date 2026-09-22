//! Path A Flock host: `flock_core::verifier::verify_ligerito` (1-thread pool).

use flock_core::{
    challenger::FsChallenger,
    pcs::{Commitment, PcsParams},
    proof::R1csProofLigerito,
    r1cs::{BlockR1cs, SparseBinaryMatrix, WitnessLayout},
    verifier::verify_ligerito,
};
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

use zk_cosmwasm::{ZkError, ZkResult};

const FLCK: &[u8; 4] = b"FLCK";
const VERSION_LIGERITO: u8 = 2;
const HEADER: usize = 8;
const STUB_LEN: usize = 72;
const DOMAIN_PREFIX: &[u8] = b"terp-flock/ligerito/v1";

const M: usize = 22;
const K_LOG: usize = 6;
const K_SKIP: usize = 6;

#[derive(Serialize, Deserialize)]
struct LigeritoBody {
    commitment: Commitment,
    proof: R1csProofLigerito,
}

pub fn install() {
    let _ = zk_cosmwasm::FLOCK_HOST_VERIFY.set(host_verify);
}

pub fn host_verify(proof: &[u8], instances: &[u8]) -> ZkResult<()> {
    if proof.len() == STUB_LEN && proof.starts_with(FLCK) && proof.get(6) == Some(&1) {
        return Err(ZkError::new_err("flock: digest stub rejected"));
    }
    if proof.len() < HEADER + 8 {
        return Err(ZkError::new_err("flock: truncated"));
    }
    if &proof[0..4] != FLCK {
        return Err(ZkError::new_err("flock: bad magic"));
    }
    if proof[4] != 3 {
        return Err(ZkError::new_err("flock: prover_id must be 3"));
    }
    if proof[5] != 7 {
        return Err(ZkError::new_err("flock: curve_id must be 7"));
    }
    if proof[6] != VERSION_LIGERITO {
        return Err(ZkError::new_err("flock: want ligerito version 2"));
    }
    let body: LigeritoBody =
        bincode::deserialize(&proof[HEADER..]).map_err(|_| ZkError::new_err("flock: bincode"))?;
    let r1cs = canonical_identity_r1cs();
    let pcs_params = canonical_pcs_params();
    if body.commitment.params != pcs_params {
        return Err(ZkError::new_err("flock: pcs params mismatch"));
    }
    let lc = r1cs.sparse_lincheck_circuit();
    let mut ch = FsChallenger::new(&fs_domain(instances));
    verify_ligerito(
        &r1cs,
        &body.commitment,
        &body.proof,
        &lc,
        &pcs_params,
        &mut ch,
    )
    .map_err(|e| ZkError::new_err(format!("flock: {e:?}")))?;
    Ok(())
}

fn fs_domain(instances: &[u8]) -> Vec<u8> {
    let mut d = DOMAIN_PREFIX.to_vec();
    d.extend_from_slice(blake3::hash(instances).as_bytes());
    d
}

fn identity_matrix(k: usize) -> SparseBinaryMatrix {
    SparseBinaryMatrix::new(k, k, (0..k).map(|i| vec![i]).collect())
}

fn canonical_identity_r1cs() -> BlockR1cs {
    let k = 1usize << K_LOG;
    BlockR1cs {
        m: M,
        k_log: K_LOG,
        k_skip: K_SKIP,
        useful_bits: k,
        a_0: identity_matrix(k),
        b_0: identity_matrix(k),
        c_0: identity_matrix(k),
        layout: WitnessLayout::RowMajor,
        const_pin: None,
        digest_cache: OnceLock::new(),
        csc_cache: OnceLock::new(),
    }
}

fn canonical_pcs_params() -> PcsParams {
    PcsParams {
        m: M,
        log_inv_rate: 1,
        log_batch_size: 6,
        profile: Default::default(),
        num_lanes: None,
        merkle_hash: Default::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zk_cosmwasm::{prove_flock, verify_flock_proof};

    #[test]
    fn host_rejects_digest_stub() {
        install();
        let action = [7u8; 128];
        let stub = prove_flock(&action);
        assert!(host_verify(&stub, &action).is_err());
        assert!(verify_flock_proof(&stub, &action).is_err());
    }

    #[test]
    fn host_rejects_truncated_ligerito() {
        install();
        let mut p = vec![0u8; HEADER];
        p[0..4].copy_from_slice(FLCK);
        p[4] = 3;
        p[5] = 7;
        p[6] = VERSION_LIGERITO;
        assert!(host_verify(&p, &[]).is_err());
    }
}
