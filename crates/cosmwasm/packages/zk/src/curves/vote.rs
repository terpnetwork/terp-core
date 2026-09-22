//! Vote-sdk circuit VK types for the CosmWasm VM.
//!
//! These types bridge vote-sdk's Halo2 circuits (delegation, vote commitment,
//! share reveal) into the `AnyVerifyingKey` dispatch via `CircuitFooter`.
//! The vote-sdk uses `halo2_proofs = "0.3"` (crates.io), but the local fork
//! shares the same byte-level serialization format, so we deserialize using
//! the local fork at verification time.

use group::ff::PrimeField;
use halo2_proofs::{
    pasta::{EqAffine, Fp},
    plonk::{self, verify_proof, SingleVerifier, VerifyingKey},
    poly::commitment::Params,
    transcript::{Blake2bRead, Challenge255},
};
use sha2::{Digest, Sha256};

use crate::{CircuitFooter, ZkError, ZkResult};

/// Identifies which of the three vote-sdk circuits is being verified.
///
/// Encoded as `curve_id` in the `CircuitFooter`:
///   1 = VoteDelegation (ZKP #1)
///   2 = VoteCommitment (ZKP #2)
///   3 = ShareReveal (ZKP #3)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum VoteCircuitId {
    Delegation = 1,
    VoteCommitment = 2,
    ShareReveal = 3,
}

impl TryFrom<u8> for VoteCircuitId {
    type Error = ZkError;

    fn try_from(v: u8) -> Result<Self, Self::Error> {
        match v {
            1 => Ok(VoteCircuitId::Delegation),
            2 => Ok(VoteCircuitId::VoteCommitment),
            3 => Ok(VoteCircuitId::ShareReveal),
            _ => Err(ZkError::new_err(format!("invalid VoteCircuitId: {v}"))),
        }
    }
}

impl From<VoteCircuitId> for u8 {
    fn from(id: VoteCircuitId) -> u8 {
        id as u8
    }
}

/// A verifying key for a vote-sdk circuit, self-describing via its
/// `CircuitFooter` which carries `curve_id ∈ {1,2,3}`.
#[derive(Debug, Clone)]
pub struct VoteVerifyingKey {
    /// Which vote circuit this key was generated for (Delegation=1, VoteCommitment=2, ShareReveal=3).
    pub circuit_id: VoteCircuitId,
    /// Serialized `Params<EqAffine>` bytes (from the vote-sdk's halo2 0.3, compatible with local fork).
    pub params_bytes: Vec<u8>,
    /// Serialized `ConstraintSystem` + `VerifyingKey` bytes (CS first, VK second).
    pub vk_body_bytes: Vec<u8>,
    /// CosmWasm CircuitFooter for dispatch.
    pub footer: CircuitFooter,
}

impl VoteVerifyingKey {
    /// Build from pre-serialized bytes.
    pub fn from_voting_circuit_vk(
        circuit_id: VoteCircuitId,
        params_bytes: Vec<u8>,
        vk_body_bytes: Vec<u8>,
        k: u8,
        num_public_inputs: u8,
    ) -> Self {
        let param_checksum: [u8; 32] = Sha256::digest(&params_bytes).into();
        let vk_checksum: [u8; 32] = Sha256::digest(&vk_body_bytes).into();

        let footer = CircuitFooter::new(
            crate::CircuitType::Plonkish,
            // Map VoteCircuitId to the corresponding CurveType
            match circuit_id {
                VoteCircuitId::Delegation => crate::curves::CurveType::VoteDelegation,
                VoteCircuitId::VoteCommitment => crate::curves::CurveType::VoteCommitment,
                VoteCircuitId::ShareReveal => crate::curves::CurveType::ShareReveal,
            },
            k,
            num_public_inputs,
            params_bytes.len() as u32,
            vk_body_bytes.len() as u32,
            0, // vk_len: 0 since we don't split cs+vk
            param_checksum,
            vk_checksum,
        );

        Self {
            circuit_id,
            params_bytes,
            vk_body_bytes,
            footer,
        }
    }

    /// Verify a proof. Deserializes params + CS + VK from stored bytes
    /// using the local halo2 fork, then calls `verify_proof`.
    pub fn verify(&self, proof: &[u8], public_inputs: &[Fp]) -> ZkResult<()> {
        let mut param_reader = std::io::Cursor::new(&self.params_bytes);
        let params = Params::<EqAffine>::read(&mut param_reader)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize params: {e}")))?;

        let mut vk_reader = std::io::Cursor::new(&self.vk_body_bytes);
        let cs = plonk::ConstraintSystem::<Fp>::read(&mut vk_reader)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize CS: {e}")))?;

        let vk = VerifyingKey::<EqAffine>::read_with_cs(&mut vk_reader, &params, cs)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize VK: {e}")))?;

        let strategy = SingleVerifier::new(&params);
        let mut transcript = Blake2bRead::<_, EqAffine, Challenge255<EqAffine>>::init(proof);
        verify_proof(&params, &vk, strategy, &[&[public_inputs]], &mut transcript)
            // C-06: crypto reject → VerifyFailed (host Ok(1)), not Aborted/VmError.
            .map_err(|_e| ZkError::VerifyFailed)?;

        Ok(())
    }

    /// Verify with trailing-byte rejection.
    pub fn verify_strict(&self, proof: &[u8], public_inputs: &[Fp]) -> ZkResult<()> {
        let mut param_reader = std::io::Cursor::new(&self.params_bytes);
        let params = Params::<EqAffine>::read(&mut param_reader)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize params: {e}")))?;

        let mut vk_reader = std::io::Cursor::new(&self.vk_body_bytes);
        let cs = plonk::ConstraintSystem::<Fp>::read(&mut vk_reader)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize CS: {e}")))?;

        let vk = VerifyingKey::<EqAffine>::read_with_cs(&mut vk_reader, &params, cs)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize VK: {e}")))?;

        let mut proof_reader = proof;
        let strategy = SingleVerifier::new(&params);
        let mut transcript =
            Blake2bRead::<_, EqAffine, Challenge255<EqAffine>>::init(&mut proof_reader);
        verify_proof(&params, &vk, strategy, &[&[public_inputs]], &mut transcript)
            .map_err(|e| ZkError::new_err(format!("proof verification failed: {e}")))?;

        if !proof_reader.is_empty() {
            return Err(ZkError::new_err(format!(
                "proof has {} unread trailing bytes",
                proof_reader.len()
            )));
        }

        Ok(())
    }
}

impl TryFrom<&[u8]> for VoteVerifyingKey {
    type Error = ZkError;

    /// Reconstruct from footer-format bytes:
    ///   [params_bytes] [vk_body_bytes] [80-byte CircuitFooter]
    fn try_from(bytes: &[u8]) -> Result<Self, Self::Error> {
        use crate::COSMWASM_FOOTER_LENGTH;

        if bytes.len() < COSMWASM_FOOTER_LENGTH {
            return Err(ZkError::new_err(format!(
                "data too short for footer: {} bytes, need at least {COSMWASM_FOOTER_LENGTH}",
                bytes.len()
            )));
        }

        let footer_start = bytes.len() - COSMWASM_FOOTER_LENGTH;
        let footer = CircuitFooter::from_bytes(&bytes[footer_start..])?;

        let param_len = footer.param_len as usize;
        if param_len > footer_start {
            return Err(ZkError::new_err(format!(
                "param_len {param_len} exceeds data before footer {footer_start}"
            )));
        }

        let params_bytes = bytes[..param_len].to_vec();
        let vk_body_bytes = bytes[param_len..footer_start].to_vec();

        // Determine circuit_id from footer.curve_id (1, 2, or 3)
        let circuit_id = VoteCircuitId::try_from(footer.curve_id).map_err(|_| {
            ZkError::new_err(format!(
                "invalid curve_id for vote circuit: {}",
                footer.curve_id
            ))
        })?;

        Ok(Self {
            circuit_id,
            params_bytes,
            vk_body_bytes,
            footer,
        })
    }
}

/// Public inputs for a vote-sdk circuit.
#[derive(Debug, Clone)]
pub struct VoteInstance {
    pub public_inputs: Vec<[u8; 32]>,
}

impl VoteInstance {
    pub fn from_bytes(bytes: &[u8]) -> ZkResult<Self> {
        if bytes.is_empty() {
            return Ok(Self {
                public_inputs: vec![],
            });
        }
        if bytes.len() % 32 != 0 {
            return Err(ZkError::new_err(format!(
                "input length {} is not a multiple of 32",
                bytes.len()
            )));
        }

        let public_inputs = bytes
            .chunks_exact(32)
            .map(|chunk| {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(chunk);
                arr
            })
            .collect();

        Ok(Self { public_inputs })
    }

    /// Decode all limbs; returns empty vec if any limb is non-canonical
    /// (caller must compare length to `public_inputs.len()` — C-06 / H-01).
    pub fn to_scalars(&self) -> Vec<Fp> {
        let mut out = Vec::with_capacity(self.public_inputs.len());
        for bytes in &self.public_inputs {
            let repr = Fp::from_repr(*bytes);
            if bool::from(repr.is_some()) {
                out.push(repr.unwrap());
            } else {
                // Stop early; circuits.rs treats len mismatch as InvalidScalar.
                return out;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mock_params_bytes(k: u8) -> Vec<u8> {
        let n: u32 = 1u32 << k;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&(k as u32).to_le_bytes());
        bytes.extend_from_slice(&n.to_le_bytes());
        bytes.extend_from_slice(&[0u8; 32]);
        bytes
    }

    fn mock_vk_body_bytes() -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&0u32.to_le_bytes()); // num_fixed_columns
        bytes.extend_from_slice(&0u32.to_le_bytes()); // num_advice_columns
        bytes.extend_from_slice(&0u32.to_le_bytes()); // num_instance_columns
        bytes.extend_from_slice(&0u32.to_le_bytes()); // num_selectors
        bytes.extend_from_slice(b"mock_vk_data");
        bytes
    }

    #[test]
    fn test_vote_circuit_id_try_from() {
        assert_eq!(
            VoteCircuitId::try_from(1).unwrap(),
            VoteCircuitId::Delegation
        );
        assert_eq!(
            VoteCircuitId::try_from(2).unwrap(),
            VoteCircuitId::VoteCommitment
        );
        assert_eq!(
            VoteCircuitId::try_from(3).unwrap(),
            VoteCircuitId::ShareReveal
        );
        assert!(VoteCircuitId::try_from(0).is_err());
        assert!(VoteCircuitId::try_from(4).is_err());
    }

    #[test]
    fn test_vote_circuit_id_conversion() {
        let ids = [
            VoteCircuitId::Delegation,
            VoteCircuitId::VoteCommitment,
            VoteCircuitId::ShareReveal,
        ];
        let expected = [1u8, 2, 3];
        for (id, exp) in ids.iter().zip(expected.iter()) {
            let val: u8 = (*id).into();
            assert_eq!(val, *exp);
            let back = VoteCircuitId::try_from(val).unwrap();
            assert_eq!(*id, back);
        }
    }

    #[test]
    fn test_serialization_round_trip() {
        let circuit_id = VoteCircuitId::Delegation;
        let params_bytes = mock_params_bytes(8);
        let vk_body_bytes = mock_vk_body_bytes();

        let vk = VoteVerifyingKey::from_voting_circuit_vk(
            circuit_id,
            params_bytes.clone(),
            vk_body_bytes.clone(),
            8,
            1,
        );

        let footer_bytes: [u8; 80] = vk.footer.to_bytes();
        let mut serialized = Vec::new();
        serialized.extend_from_slice(&params_bytes);
        serialized.extend_from_slice(&vk_body_bytes);
        serialized.extend_from_slice(&footer_bytes);

        let deserialized = VoteVerifyingKey::try_from(serialized.as_slice())
            .expect("should deserialize from footer-format bytes");

        assert_eq!(deserialized.circuit_id, circuit_id);
        assert_eq!(deserialized.params_bytes, params_bytes);
        assert_eq!(deserialized.vk_body_bytes, vk_body_bytes);
        assert_eq!(deserialized.footer, vk.footer);

        // Verify curve_id encodes the circuit
        assert_eq!(deserialized.footer.curve_id, 1); // VoteDelegation
    }

    #[test]
    fn test_footer_checksums_match_after_round_trip() {
        let circuit_id = VoteCircuitId::VoteCommitment;
        let params_bytes = mock_params_bytes(9);
        let vk_body_bytes = mock_vk_body_bytes();

        let vk = VoteVerifyingKey::from_voting_circuit_vk(
            circuit_id,
            params_bytes.clone(),
            vk_body_bytes.clone(),
            9,
            2,
        );

        let footer_bytes: [u8; 80] = vk.footer.to_bytes();
        let mut serialized = Vec::new();
        serialized.extend_from_slice(&params_bytes);
        serialized.extend_from_slice(&vk_body_bytes);
        serialized.extend_from_slice(&footer_bytes);

        let deserialized =
            VoteVerifyingKey::try_from(serialized.as_slice()).expect("should deserialize");

        let expected_param_checksum: [u8; 32] = Sha256::digest(&params_bytes).into();
        let expected_vk_checksum: [u8; 32] = Sha256::digest(&vk_body_bytes).into();

        assert_eq!(deserialized.footer.param_checksum, expected_param_checksum);
        assert_eq!(deserialized.footer.vk_checksum, expected_vk_checksum);
        assert_eq!(deserialized.footer.curve_id, 2); // VoteCommitment
    }

    #[test]
    fn test_vote_instance_from_bytes() {
        let instance = VoteInstance::from_bytes(&[]).unwrap();
        assert!(instance.public_inputs.is_empty());

        let input = [42u8; 32];
        let instance = VoteInstance::from_bytes(&input).unwrap();
        assert_eq!(instance.public_inputs.len(), 1);

        let mut input = Vec::new();
        input.extend_from_slice(&[1u8; 32]);
        input.extend_from_slice(&[2u8; 32]);
        input.extend_from_slice(&[3u8; 32]);
        let instance = VoteInstance::from_bytes(&input).unwrap();
        assert_eq!(instance.public_inputs.len(), 3);

        assert!(VoteInstance::from_bytes(&[0u8; 10]).is_err());
        assert!(VoteInstance::from_bytes(&[0u8; 33]).is_err());
    }

    #[test]
    fn test_try_from_short_bytes() {
        let result = VoteVerifyingKey::try_from(&[0u8; 10] as &[u8]);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("data too short"));
    }
}
