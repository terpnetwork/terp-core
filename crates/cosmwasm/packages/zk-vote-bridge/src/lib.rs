//! # zk-vote-bridge
//!
//! Bridges vote-sdk Halo2 circuits into the CosmWasm VM's
//! `proof_instance_verify` API via `CircuitFooter` serialization.
//!
//! The two halo2 versions (crates.io 0.3 used by vote-sdk, vs the local fork
//! used by zk-cosmwasm) are incompatible at the Rust type level, but byte-level
//! serialization is version-independent. This crate stores serialized bytes
//! from the vote-sdk circuits and wraps them with a `CircuitFooter` so the
//! CosmWasm VM can dispatch verification through the existing `AnyVerifyingKey`
//! infrastructure.

use halo2_proofs::{
    pasta::{EqAffine, Fp},
    plonk::{self, verify_proof, SingleVerifier, VerifyingKey},
    poly::commitment::Params,
    transcript::{Blake2bRead, Challenge255},
};
use group::ff::PrimeField;
use sha2::{Digest, Sha256};
use zk_cosmwasm::{CircuitFooter, ZkError, ZkResult};

/// Identifies which of the three vote-sdk circuits is being verified.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum VoteCircuitId {
    /// Delegation circuit (ZKP #1)
    Delegation = 1,
    /// Vote commitment circuit (ZKP #2)
    VoteCommitment = 2,
    /// Share reveal circuit (ZKP #3)
    ShareReveal = 3,
}

impl TryFrom<u8> for VoteCircuitId {
    type Error = ZkError;

    fn try_from(v: u8) -> Result<Self, Self::Error> {
        match v {
            1 => Ok(VoteCircuitId::Delegation),
            2 => Ok(VoteCircuitId::VoteCommitment),
            3 => Ok(VoteCircuitId::ShareReveal),
            _ => Err(ZkError::new_err(format!(
                "invalid VoteCircuitId: {v}"
            ))),
        }
    }
}

impl From<VoteCircuitId> for u8 {
    fn from(id: VoteCircuitId) -> u8 {
        id as u8
    }
}

/// A verifying key for a vote-sdk circuit, serialized in a
/// zk-cosmwasm-compatible format.
///
/// Stores the raw bytes of the params, constraint system, and verifying key,
/// along with a `CircuitFooter` that carries checksums and metadata. The
/// footer is what the upstream `AnyVerifyingKey` dispatch uses to route
/// verification to the correct curve + prover.
#[derive(Debug, Clone)]
pub struct VoteVerifyingKey {
    /// Which circuit this key was generated for.
    pub circuit_id: VoteCircuitId,
    /// Serialized `Params<EqAffine>` bytes (from the vote-sdk's halo2 0.3).
    pub params_bytes: Vec<u8>,
    /// Serialized `ConstraintSystem` + `VerifyingKey` bytes.
    /// The CS is prepended before the VK, matching the halo2 convention.
    pub vk_bytes: Vec<u8>,
    /// zk-cosmwasm CircuitFooter for CosmWasm VM dispatch.
    pub footer: CircuitFooter,
}

impl VoteVerifyingKey {
    /// Build a `VoteVerifyingKey` from pre-serialized bytes.
    ///
    /// The caller is responsible for serializing the vote-sdk's native
    /// `Params<EqAffine>` and `VerifyingKey<EqAffine>` (from the crates.io
    /// halo2 0.3) using their `write` methods. The two halo2 versions share
    /// the same wire format, so the local fork can deserialize these bytes
    /// at verification time.
    ///
    /// # Arguments
    ///
    /// * `circuit_id` - Which vote circuit this key belongs to.
    /// * `params_bytes` - Serialized `Params<EqAffine>`.
    /// * `vk_body_bytes` - Serialized `ConstraintSystem` + `VerifyingKey` (CS first, VK second).
    /// * `k` - The `k` parameter (log2 of the domain size).
    /// * `num_public_inputs` - Number of public input scalars (`i`).
    pub fn from_voting_circuit_vk(
        circuit_id: VoteCircuitId,
        params_bytes: Vec<u8>,
        vk_body_bytes: Vec<u8>,
        k: u8,
        num_public_inputs: u8,
    ) -> Self {
        let param_checksum: [u8; 32] = Sha256::digest(&params_bytes).into();
        let vk_checksum: [u8; 32] = Sha256::digest(&vk_body_bytes).into();

        // We need cs_len and vk_len. The vk_body_bytes contains [cs][vk].
        // We parse the CS first to get its length, and the remainder is the VK.
        // If parsing fails, we use the full length as cs_len and 0 for vk_len.
        let (cs_len, vk_len) = if vk_body_bytes.len() >= 8 {
            // Try to read the CS length from the first 4 bytes (LE u32)
            // The constraint system's first field is typically `num_fixed_columns`
            // as a u32 LE, but we can't know the exact CS length without parsing.
            // As a fallback, we'll use the vk_body_bytes length as cs_len
            // and 0 for vk_len, letting the deserializer figure it out.
            (vk_body_bytes.len() as u32, 0u32)
        } else {
            (vk_body_bytes.len() as u32, 0u32)
        };

        let footer = CircuitFooter::new(
            zk_cosmwasm::CircuitType::Plonkish,
            zk_cosmwasm::curves::CurveType::Pasta,
            k,
            num_public_inputs,
            params_bytes.len() as u32,
            cs_len,
            vk_len,
            param_checksum,
            vk_checksum,
        );

        // Override the prover_id with the VoteCircuitId value so that
        // TryFrom<&[u8]> can reconstruct the circuit_id from the footer.
        // The CircuitFooter::new sets prover_id=0 (Plonkish), but we need
        // 1, 2, or 3 for the vote circuit dispatch.
        let footer = CircuitFooter {
            prover_id: circuit_id.into(),
            ..footer
        };

        Self {
            circuit_id,
            params_bytes,
            vk_bytes: vk_body_bytes,
            footer,
        }
    }

    /// Verify a proof against this verifying key.
    ///
    /// Deserializes the stored params and VK bytes (using the local halo2 fork's
    /// types, which share the same serialization format as crates.io 0.3) and
    /// calls `verify_proof`.
    pub fn verify(&self, proof: &[u8], public_inputs: &[Fp]) -> ZkResult<()> {
        // Deserialize params from stored bytes
        let mut param_reader = std::io::Cursor::new(&self.params_bytes);
        let params = Params::<EqAffine>::read(&mut param_reader)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize params: {e}")))?;

        // Deserialize CS and VK from stored vk_bytes
        // The vk_bytes contains [cs][vk] concatenated
        let mut vk_reader = std::io::Cursor::new(&self.vk_bytes);
        let cs = plonk::ConstraintSystem::<Fp>::read(&mut vk_reader)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize CS: {e}")))?;

        // The CsBlueprint / CsBlueprintGuard are intentionally not used here
        // because they are pub(crate) to zk-cosmwasm and the local fork's
        // read_with_cs takes the CS directly, not via DynamicCircuit.
        let empty_selectors: Vec<Vec<bool>> = vec![];
        let vk = VerifyingKey::<EqAffine>::read_with_cs(
            &mut vk_reader,
            &params,
            cs,
            empty_selectors,
        )
        .map_err(|e| ZkError::new_err(format!("failed to deserialize VK: {e}")))?;

        // Verify the proof
        let strategy = SingleVerifier::new(&params);
        let mut transcript = Blake2bRead::<_, EqAffine, Challenge255<EqAffine>>::init(proof);
        verify_proof(
            &params,
            &vk,
            strategy,
            &[&[public_inputs]],
            &mut transcript,
        )
        .map_err(|e| ZkError::new_err(format!("proof verification failed: {e}")))?;

        Ok(())
    }

    /// Verify a proof with trailing-byte rejection.
    ///
    /// Same as `verify` but also rejects proofs that have unread trailing bytes.
    pub fn verify_strict(&self, proof: &[u8], public_inputs: &[Fp]) -> ZkResult<()> {
        // Deserialize params from stored bytes
        let mut param_reader = std::io::Cursor::new(&self.params_bytes);
        let params = Params::<EqAffine>::read(&mut param_reader)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize params: {e}")))?;

        // Deserialize CS and VK from stored vk_bytes
        let mut vk_reader = std::io::Cursor::new(&self.vk_bytes);
        let cs = plonk::ConstraintSystem::<Fp>::read(&mut vk_reader)
            .map_err(|e| ZkError::new_err(format!("failed to deserialize CS: {e}")))?;

        // The CsBlueprint / CsBlueprintGuard are intentionally not used here
        // because they are pub(crate) to zk-cosmwasm and the local fork's
        // read_with_cs takes the CS directly, not via DynamicCircuit.
        let empty_selectors: Vec<Vec<bool>> = vec![];
        let vk = VerifyingKey::<EqAffine>::read_with_cs(
            &mut vk_reader,
            &params,
            cs,
            empty_selectors,
        )
        .map_err(|e| ZkError::new_err(format!("failed to deserialize VK: {e}")))?;

        let mut proof_reader = proof;
        let strategy = SingleVerifier::new(&params);
        let mut transcript =
            Blake2bRead::<_, EqAffine, Challenge255<EqAffine>>::init(&mut proof_reader);
        verify_proof(
            &params,
            &vk,
            strategy,
            &[&[public_inputs]],
            &mut transcript,
        )
        .map_err(|e| ZkError::new_err(format!("proof verification failed: {e}")))?;

        // Reject trailing bytes
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

    /// Reconstruct from footer-format bytes.
    ///
    /// Expected layout:
    ///   [0..param_len]         - serialized params
    ///   [param_len..param_len+cs_len] - constraint system (optional, may be length 0)
    ///   [param_len+cs_len..footer_start] - serialized VK
    ///   [footer_start..]       - CircuitFooter (80 bytes)
    fn try_from(bytes: &[u8]) -> Result<Self, Self::Error> {
        use halo2_proofs::COSMWASM_FOOTER_LENGTH;

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
        let cs_len = footer.cs_len as usize;
        let vk_body_end = param_len + cs_len + footer.vk_len as usize;
        if vk_body_end > footer_start {
            return Err(ZkError::new_err(format!(
                "cs_len+ vk_len extends past footer start: {vk_body_end} > {footer_start}"
            )));
        }
        let vk_body_bytes = bytes[param_len..vk_body_end].to_vec();

        // Determine circuit_id from prover_id
        let circuit_id = VoteCircuitId::try_from(footer.prover_id)?;

        Ok(Self {
            circuit_id,
            params_bytes,
            vk_bytes: vk_body_bytes,
            footer,
        })
    }
}

/// Public inputs for a vote-sdk circuit, stored as raw scalar bytes.
#[derive(Debug, Clone)]
pub struct VoteInstance {
    /// Each public input is a 32-byte scalar representation.
    pub public_inputs: Vec<[u8; 32]>,
}

impl VoteInstance {
    /// Parse public inputs from a byte slice.
    ///
    /// Each 32-byte chunk is a scalar field element. The input length must be
    /// a multiple of 32.
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

    /// Convert public inputs to `Fp` scalars for verification.
    pub fn to_scalars(&self) -> Vec<Fp> {
        self.public_inputs
            .iter()
            .filter_map(|bytes| {
                let repr = Fp::from_repr(*bytes);
                if repr.is_some().into() {
                    Some(repr.unwrap())
                } else {
                    None
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: create mock params bytes (minimal valid serialized Params<EqAffine>).
    /// A real Params has a domain, but for round-trip tests we just use
    /// a plausible byte sequence.
    fn mock_params_bytes(k: u8) -> Vec<u8> {
        // Minimal valid Params: n = 2^k, then some domain data.
        // For the round-trip test we just need bytes that can be read back.
        let n: u32 = 1u32 << k;
        let mut bytes = Vec::new();
        // k as u32 (LE)
        bytes.extend_from_slice(&(k as u32).to_le_bytes());
        // n as u32 (LE)
        bytes.extend_from_slice(&n.to_le_bytes());
        // remaining: domain data (zeros for mock)
        // We need exactly what Params::read expects. For a minimal valid
        // serialization we need: k (u32), n (u32), then the domain G generators.
        // The domain serialization writes extended_k, n, then nothing else.
        // We'll add a zero G element.
        // Actually, let's just use a known-good pattern: 4 bytes for k, then
        // 4 bytes for n, then 32 bytes for a G point (affine coordinates).
        bytes.extend_from_slice(&[0u8; 32]); // G point placeholder
        bytes
    }

    /// Helper: create mock CS + VK body bytes.
    fn mock_vk_body_bytes(_k: u8) -> Vec<u8> {
        // For a mock, we return a minimal byte sequence.
        // This won't deserialize successfully, but it's fine for round-trip
        // tests that don't call verify.
        let mut bytes = Vec::new();
        // Mock CS bytes: at minimum, write a few header fields
        // num_fixed_columns (u32 LE) = 0
        bytes.extend_from_slice(&0u32.to_le_bytes());
        // num_advice_columns (u32 LE) = 0
        bytes.extend_from_slice(&0u32.to_le_bytes());
        // num_instance_columns (u32 LE) = 0
        bytes.extend_from_slice(&0u32.to_le_bytes());
        // num_selectors (u32 LE) = 0
        bytes.extend_from_slice(&0u32.to_le_bytes());
        // The rest is mock VK data
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
        assert!(VoteCircuitId::try_from(255).is_err());
    }

    #[test]
    fn test_serialization_round_trip() {
        let circuit_id = VoteCircuitId::Delegation;
        let k = 8u8;
        let num_public_inputs = 1u8;
        let params_bytes = mock_params_bytes(k);
        let vk_body_bytes = mock_vk_body_bytes(k);

        let vk = VoteVerifyingKey::from_voting_circuit_vk(
            circuit_id,
            params_bytes.clone(),
            vk_body_bytes.clone(),
            k,
            num_public_inputs,
        );

        // Build the footer-format bytes: [params][cs+vk][footer]
        let footer_bytes: [u8; 80] = vk.footer.to_bytes();
        let mut serialized = Vec::new();
        serialized.extend_from_slice(&params_bytes);
        serialized.extend_from_slice(&vk_body_bytes);
        serialized.extend_from_slice(&footer_bytes);

        // Deserialize back
        let deserialized = VoteVerifyingKey::try_from(serialized.as_slice())
            .expect("should deserialize from footer-format bytes");

        assert_eq!(deserialized.circuit_id, circuit_id);
        assert_eq!(deserialized.params_bytes, params_bytes);
        assert_eq!(deserialized.vk_bytes, vk_body_bytes);
        assert_eq!(deserialized.footer, vk.footer);
    }

    #[test]
    fn test_footer_checksums_match_after_round_trip() {
        let circuit_id = VoteCircuitId::VoteCommitment;
        let k = 9u8;
        let num_public_inputs = 2u8;
        let params_bytes = mock_params_bytes(k);
        let vk_body_bytes = mock_vk_body_bytes(k);

        let vk = VoteVerifyingKey::from_voting_circuit_vk(
            circuit_id,
            params_bytes.clone(),
            vk_body_bytes.clone(),
            k,
            num_public_inputs,
        );

        // Build footer-format bytes
        let footer_bytes: [u8; 80] = vk.footer.to_bytes();
        let mut serialized = Vec::new();
        serialized.extend_from_slice(&params_bytes);
        serialized.extend_from_slice(&vk_body_bytes);
        serialized.extend_from_slice(&footer_bytes);

        let deserialized = VoteVerifyingKey::try_from(serialized.as_slice())
            .expect("should deserialize");

        // Verify checksums
        let expected_param_checksum: [u8; 32] = Sha256::digest(&params_bytes).into();
        let expected_vk_checksum: [u8; 32] = Sha256::digest(&vk_body_bytes).into();

        assert_eq!(
            deserialized.footer.param_checksum, expected_param_checksum,
            "param checksums should match"
        );
        assert_eq!(
            deserialized.footer.vk_checksum, expected_vk_checksum,
            "vk checksums should match"
        );
    }

    #[test]
    fn test_vote_instance_from_bytes() {
        // Empty input
        let instance = VoteInstance::from_bytes(&[]).unwrap();
        assert!(instance.public_inputs.is_empty());
        assert!(instance.to_scalars().is_empty());

        // Valid 32-byte input
        let input = [42u8; 32];
        let instance = VoteInstance::from_bytes(&input).unwrap();
        assert_eq!(instance.public_inputs.len(), 1);
        assert_eq!(instance.public_inputs[0], input);

        // Multiple 32-byte inputs
        let mut input = Vec::new();
        input.extend_from_slice(&[1u8; 32]);
        input.extend_from_slice(&[2u8; 32]);
        input.extend_from_slice(&[3u8; 32]);
        let instance = VoteInstance::from_bytes(&input).unwrap();
        assert_eq!(instance.public_inputs.len(), 3);
        assert_eq!(instance.public_inputs[0], [1u8; 32]);
        assert_eq!(instance.public_inputs[1], [2u8; 32]);
        assert_eq!(instance.public_inputs[2], [3u8; 32]);

        // Non-multiple of 32
        assert!(VoteInstance::from_bytes(&[0u8; 10]).is_err());
        assert!(VoteInstance::from_bytes(&[0u8; 33]).is_err());
    }

    #[test]
    fn test_vote_instance_to_scalars() {
        // Test with valid Fp scalar bytes
        // Fp::from_repr(0) should be Some
        let zero_bytes = [0u8; 32];
        let instance = VoteInstance::from_bytes(&zero_bytes).unwrap();
        let scalars = instance.to_scalars();
        assert_eq!(scalars.len(), 1);
        assert_eq!(scalars[0], Fp::from(0u64));

        // Multiple valid scalars
        let mut input = Vec::new();
        input.extend_from_slice(&[0u8; 32]); // Fp::ZERO
        input.extend_from_slice(&[1u8; 32]); // This might be invalid Fp, test filters
        let instance = VoteInstance::from_bytes(&input).unwrap();
        let scalars = instance.to_scalars();
        // Only valid Fp elements are converted
        assert_eq!(scalars[0], Fp::from(0u64));
    }

    #[test]
    fn test_try_from_short_bytes() {
        // Too short for footer
        let result = VoteVerifyingKey::try_from(&[0u8; 10] as &[u8]);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("data too short"));
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
}