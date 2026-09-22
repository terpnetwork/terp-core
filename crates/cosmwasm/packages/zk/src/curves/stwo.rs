//! Stwo / M31 host arm (`prover_id=2`, `curve_id=5`).
//!
//! Path A: `proof_instance_verify(zkid, proof, instances)` loads a footer-only
//! VK (`curve_id=5`). **Verify is fail-closed** unless zk-wasmvm installs
//! [`STWO_HOST_VERIFY`] (installed by [`crate::install_path_a_hosts`] from
//! `host::stwo`). Dummy DSTW / 18-byte `c=3a+5b+7` blobs are not proofs.
//! Not `CircuitType::Stark`.

use std::sync::OnceLock;

use crate::COSMWASM_FOOTER_LENGTH;
use sha2::{Digest, Sha256};

use crate::{CircuitFooter, CircuitType, Proof, ZkError, ZkResult};

use super::CurveType;

/// zk-wasmvm installs real S-two verify here (FOLD/SSLE). Dummy DSTW is
/// rejected by that host. Kept as a hook so this crate does not depend on
/// `stwo` (CosmWasm workspace digest clash with vote-sdk).
pub static STWO_HOST_VERIFY: OnceLock<fn(&[u8], &[u8]) -> ZkResult<()>> = OnceLock::new();

/// Footer `prover_id` for this arm.
pub const STWO_PROVER_ID: u8 = CircuitType::Stwo as u8;
/// Footer / proof `curve_id` (M31 Circle).
pub const STWO_CURVE_ID: u8 = 5;

/// Empty-param Stwo VK: footer only (`param_len=0`, `cs_len=0`).
#[derive(Debug, Clone)]
pub struct StwoVerifyingKey {
    pub footer: CircuitFooter,
}

/// Raw public inputs (period|weight|subject or empty).
#[derive(Debug, Clone)]
pub struct StwoInstance {
    pub bytes: Vec<u8>,
}

impl StwoInstance {
    pub fn public_input_count(&self) -> usize {
        1
    }
}

impl StwoVerifyingKey {
    pub fn lean_default() -> Self {
        let empty = Sha256::digest([]);
        Self {
            footer: CircuitFooter::new(
                CircuitType::Stwo,
                CurveType::M31,
                0,
                1,
                0,
                0,
                0,
                empty.into(),
                empty.into(),
            ),
        }
    }

    pub fn to_blob(&self) -> Vec<u8> {
        self.footer.to_bytes().to_vec()
    }

    pub fn try_from_bytes(bytes: &[u8]) -> ZkResult<Self> {
        if bytes.len() < COSMWASM_FOOTER_LENGTH {
            return Err(ZkError::new_err("stwo vk: short"));
        }
        let footer = CircuitFooter::from_bytes(&bytes[bytes.len() - COSMWASM_FOOTER_LENGTH..])?;
        if footer.curve_id != STWO_CURVE_ID {
            return Err(ZkError::UnsupportedCurve(footer.appstate_key()));
        }
        if footer.prover_id != STWO_PROVER_ID {
            return Err(ZkError::new_err("stwo vk: prover_id must be 2"));
        }
        Ok(Self { footer })
    }

    pub fn from_split_bytes(
        _param: &[u8],
        _vk_body: &[u8],
        footer: CircuitFooter,
    ) -> ZkResult<Self> {
        if footer.curve_id != STWO_CURVE_ID || footer.prover_id != STWO_PROVER_ID {
            return Err(ZkError::UnsupportedCurve(footer.appstate_key()));
        }
        Ok(Self { footer })
    }

    pub fn verify(&self, proof: &Proof, instances: &StwoInstance) -> ZkResult<()> {
        verify_stwo_proof(&proof.0, &instances.bytes)
    }
}

impl TryFrom<&[u8]> for StwoVerifyingKey {
    type Error = ZkError;
    fn try_from(bytes: &[u8]) -> ZkResult<Self> {
        Self::try_from_bytes(bytes)
    }
}

/// When [`STWO_HOST_VERIFY`] is set (zk-wasmvm), Dummy DSTW is rejected and
/// FOLD/SSLE Circle STARKs are verified by pinned S-two.
pub fn verify_stwo_proof(proof: &[u8], instances: &[u8]) -> ZkResult<()> {
    if proof.len() > 2 * 1024 * 1024 {
        return Err(ZkError::new_err("stwo: proof too large"));
    }
    if let Some(host) = STWO_HOST_VERIFY.get() {
        return host(proof, instances);
    }
    Err(ZkError::new_err(
        "stwo: host verifier required (dummy DSTW is not a proof)",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::{AnyInstance, AnyVerifyingKey, CircuitType};

    const M31_P: u32 = (1 << 31) - 1;
    const DSTW: &[u8; 4] = b"DSTW";
    const DUMMY_LEN: usize = 18;

    fn dummy_m31_hash(a: u32, b: u32) -> u32 {
        ((3u64 * u64::from(a) + 5u64 * u64::from(b) + 7) % u64::from(M31_P)) as u32
    }

    fn dstw(a: u32, b: u32) -> Vec<u8> {
        let c = dummy_m31_hash(a, b);
        let mut o = vec![0u8; DUMMY_LEN];
        o[0..4].copy_from_slice(DSTW);
        o[4] = STWO_PROVER_ID;
        o[5] = STWO_CURVE_ID;
        o[6..10].copy_from_slice(&a.to_le_bytes());
        o[10..14].copy_from_slice(&b.to_le_bytes());
        o[14..18].copy_from_slice(&c.to_le_bytes());
        o
    }

    #[test]
    fn circuit_type_stwo_is_two() {
        assert_eq!(CircuitType::from_u8(2), Some(CircuitType::Stwo));
        assert_eq!(CircuitType::Stwo as u8, 2);
        assert!(CircuitType::from_u8(99).is_none());
    }

    #[test]
    fn footer_curve_5_loads_stwo_vk() {
        let vk = StwoVerifyingKey::lean_default();
        let blob = vk.to_blob();
        let loaded = AnyVerifyingKey::try_from(blob.as_slice()).expect("load");
        assert_eq!(loaded.prover_id(), 2);
        assert_eq!(loaded.curve_id(), 5);
        assert!(matches!(loaded, AnyVerifyingKey::Stwo(_)));
    }

    #[test]
    fn proof_instance_verify_dstw_rejected_without_host() {
        let vk = AnyVerifyingKey::Stwo(StwoVerifyingKey::lean_default());
        let p = Proof::new(dstw(3, 5));
        let i = AnyInstance::Stwo(StwoInstance { bytes: vec![] });
        assert!(vk.verify(&p, std::slice::from_ref(&i)).is_err());
    }

    #[test]
    fn wrong_prover_id_in_proof_fails() {
        let mut p = dstw(1, 1);
        p[4] = 0;
        let vk = StwoVerifyingKey::lean_default();
        assert!(vk
            .verify(&Proof::new(p), &StwoInstance { bytes: vec![] })
            .is_err());
    }
}
