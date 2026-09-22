//! Flock host arm (`prover_id=3`, `curve_id=7`).
//!
//! Path A footer-only VK. **Verify is fail-closed** unless zk-wasmvm installs
//! [`FLOCK_HOST_VERIFY`] (`host::flock` / `flock_core::verify_ligerito`)
//! (single-thread pool). The 72-byte BLAKE3 digest blob is **not** a proof.
//!
//! Not `CircuitType::Stwo`. Not Axiom KZG.

use std::sync::OnceLock;

use blake3::Hasher;
use crate::COSMWASM_FOOTER_LENGTH;
use sha2::{Digest, Sha256};

use crate::{CircuitFooter, CircuitType, Proof, ZkError, ZkResult};

use super::CurveType;

/// zk-wasmvm installs `flock-core` `verify_ligerito` here. Digest stubs are
/// rejected. Hook keeps `flock-core` (edition 2024 / rayon) off CosmWasm guest
/// wasm32 builds.
pub static FLOCK_HOST_VERIFY: OnceLock<fn(&[u8], &[u8]) -> ZkResult<()>> = OnceLock::new();

/// Footer `prover_id` — [`CircuitType::Flock`].
pub const FLOCK_PROVER_ID: u8 = CircuitType::Flock as u8;
/// Footer `curve_id` — Blake3 / Flock (no pairing curve).
pub const FLOCK_CURVE_ID: u8 = 7;

const FLCK: &[u8; 4] = b"FLCK";
const VERSION: u8 = 1;
/// `FLCK|ids|blake3(instances)|blake3(domain||instances)`
pub const FLOCK_PROOF_LEN: usize = 4 + 4 + 32 + 32;
const DOMAIN: &[u8] = b"terp-flock/v1";

/// Empty-param Flock VK: CosmWasm footer only.
#[derive(Debug, Clone)]
pub struct FlockVerifyingKey {
    pub footer: CircuitFooter,
}

/// Raw public inputs (typically 128-byte zk-jwt layout; last 32 = action).
#[derive(Debug, Clone)]
pub struct FlockInstance {
    pub bytes: Vec<u8>,
}

impl FlockInstance {
    pub fn public_input_count(&self) -> usize {
        self.bytes.len().div_ceil(32).max(1)
    }
}

impl FlockVerifyingKey {
    pub fn default_footer() -> CircuitFooter {
        let empty = Sha256::digest([]);
        CircuitFooter::new(
            CircuitType::Flock,
            CurveType::FlockBlake3,
            0,
            4,
            0,
            0,
            0,
            empty.into(),
            empty.into(),
        )
    }

    pub fn lean_default() -> Self {
        Self {
            footer: Self::default_footer(),
        }
    }

    pub fn to_blob(&self) -> Vec<u8> {
        self.footer.to_bytes().to_vec()
    }

    pub fn try_from_bytes(bytes: &[u8]) -> ZkResult<Self> {
        if bytes.len() < COSMWASM_FOOTER_LENGTH {
            return Err(ZkError::new_err("flock vk: short"));
        }
        let footer = CircuitFooter::from_bytes(&bytes[bytes.len() - COSMWASM_FOOTER_LENGTH..])?;
        if footer.curve_id != FLOCK_CURVE_ID {
            return Err(ZkError::UnsupportedCurve(footer.appstate_key()));
        }
        if footer.prover_id != FLOCK_PROVER_ID {
            return Err(ZkError::new_err("flock vk: prover_id must be 3"));
        }
        Ok(Self { footer })
    }

    pub fn from_split_bytes(
        _param: &[u8],
        _vk_body: &[u8],
        footer: CircuitFooter,
    ) -> ZkResult<Self> {
        if footer.curve_id != FLOCK_CURVE_ID || footer.prover_id != FLOCK_PROVER_ID {
            return Err(ZkError::UnsupportedCurve(footer.appstate_key()));
        }
        Ok(Self { footer })
    }

    pub fn verify(&self, proof: &Proof, instances: &FlockInstance) -> ZkResult<()> {
        verify_flock_proof(&proof.0, &instances.bytes)
    }
}

impl TryFrom<&[u8]> for FlockVerifyingKey {
    type Error = ZkError;
    fn try_from(bytes: &[u8]) -> ZkResult<Self> {
        Self::try_from_bytes(bytes)
    }
}

/// BLAKE3 of the public action / instance blob (VM-side hash).
pub fn flock_action_digest(instances: &[u8]) -> [u8; 32] {
    *Hasher::new().update(instances).finalize().as_bytes()
}

pub fn flock_domain_digest(instances: &[u8]) -> [u8; 32] {
    *Hasher::new()
        .update(DOMAIN)
        .update(instances)
        .finalize()
        .as_bytes()
}

/// Legacy digest blob (not a SNARK). Kept so tests can assert rejection.
pub fn prove_flock(instances: &[u8]) -> Vec<u8> {
    let mut o = vec![0u8; FLOCK_PROOF_LEN];
    o[0..4].copy_from_slice(FLCK);
    o[4] = FLOCK_PROVER_ID;
    o[5] = FLOCK_CURVE_ID;
    o[6] = VERSION;
    o[7] = 0;
    o[8..40].copy_from_slice(&flock_action_digest(instances));
    o[40..72].copy_from_slice(&flock_domain_digest(instances));
    o
}

pub fn verify_flock_proof(proof: &[u8], instances: &[u8]) -> ZkResult<()> {
    if proof.len() > 2 * 1024 * 1024 {
        return Err(ZkError::new_err("flock: proof too large"));
    }
    if let Some(host) = FLOCK_HOST_VERIFY.get() {
        return host(proof, instances);
    }
    Err(ZkError::new_err(
        "flock: host verifier required (digest stub is not a proof)",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AnyInstance, AnyVerifyingKey, CircuitType};

    #[test]
    fn flock_digest_stub_rejected_without_host() {
        let action = [7u8; 128];
        let proof = prove_flock(&action);
        assert!(verify_flock_proof(&proof, &action).is_err());
    }

    #[test]
    fn flock_vk_dispatches_curve_7() {
        let vk = FlockVerifyingKey::lean_default();
        let blob = vk.to_blob();
        let any = AnyVerifyingKey::try_from(blob.as_slice()).expect("dispatch");
        assert_eq!(any.curve_id(), FLOCK_CURVE_ID);
        assert_eq!(any.prover_id(), FLOCK_PROVER_ID);
        assert_eq!(CircuitType::try_from(any).unwrap(), CircuitType::Flock);
        let inst = AnyInstance::try_from_bytes(FLOCK_CURVE_ID as u32, &[1u8; 32]).unwrap();
        matches!(inst, AnyInstance::Flock(_));
    }
}
