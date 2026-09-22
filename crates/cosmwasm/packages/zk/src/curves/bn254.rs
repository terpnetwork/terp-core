//! BN254 curve implementation for the generic ZkCurve trait.
//!
//! BN254 (alt_bn128 / bn254) is the primary curve used in Ethereum
//! precompiles (EIP-196/197) and widely supported by Groth16 proving
//! systems. This module provides the `ZkCurve` impl so that BN254
//! proofs can be verified through the same `AnyVerifyingKey::verify()`
//! interface as Pasta/Vesta.
//!
//! ## Wire formats (Phase B locked decisions)
//!
//! - **VK body**: ark-serialize compressed `ark_groth16::VerifyingKey<Bn254>`
//! - **Proof**: ark-serialize compressed `ark_groth16::Proof<Bn254>`
//! - **Instances**: concat of 32-byte **big-endian** Fr limbs; Fr ≥ r rejected
//! - **Footer**: empty-param Groth16 (`prover_id=1`, `curve_id=4`, `param_len=0`)

use crate::{curves::ZkCurve, ZkError, ZkResult};
use crate::COSMWASM_FOOTER_LENGTH;

#[cfg(feature = "bn254")]
use ark_bn254::{Bn254, Fr};
#[cfg(feature = "bn254")]
use ark_crypto_primitives::snark::SNARK;
#[cfg(feature = "bn254")]
use ark_ff::{BigInteger, PrimeField};
#[cfg(feature = "bn254")]
use ark_groth16::{Groth16, Proof as ArkProof, VerifyingKey as ArkVerifyingKey};
#[cfg(feature = "bn254")]
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize, Compress, Validate};

// ── Scalar ────────────────────────────────────────────────────────────────

/// BN254 scalar field element (Fr) as a 32-byte **big-endian** limb.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bn254Scalar(pub [u8; 32]);

impl Bn254Scalar {
    /// Accept any 32-byte limb without range check (legacy). Prefer [`Self::from_be_bytes_checked`].
    pub fn from_bytes(bytes: &[u8; 32]) -> Option<Self> {
        Some(Bn254Scalar(*bytes))
    }

    /// Big-endian Fr limb; rejects non-canonical encodings (Fr ≥ r).
    #[cfg(feature = "bn254")]
    pub fn from_be_bytes_checked(bytes: &[u8; 32]) -> ZkResult<Self> {
        let fr = fr_from_be32_checked(bytes)?;
        Ok(Bn254Scalar(fr_to_be32(&fr)))
    }

    pub fn to_bytes(&self) -> [u8; 32] {
        self.0
    }

    #[cfg(feature = "bn254")]
    pub fn to_fr(&self) -> ZkResult<Fr> {
        fr_from_be32_checked(&self.0)
    }
}

// ── Affine ────────────────────────────────────────────────────────────────

/// BN254 affine curve point (G1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bn254Affine(pub [u8; 64]);

// ── Instance ──────────────────────────────────────────────────────────────

/// Public inputs for a BN254 circuit (Groth16).
#[derive(Clone, Debug)]
pub struct Bn254Instance {
    pub i: Vec<Bn254Scalar>,
    pub size: usize,
}

impl Bn254Instance {
    pub fn new(scalars: Vec<Bn254Scalar>) -> Self {
        let size = scalars.len();
        Self { i: scalars, size }
    }

    /// Decode concatenated 32-byte **big-endian** Fr limbs.
    /// Rejects non-multiple-of-32 length and Fr ≥ r (when `bn254` feature on).
    pub fn from_bytes(bytes: &[u8]) -> ZkResult<Self> {
        if bytes.len() % 32 != 0 {
            return Err(ZkError::format_err(format!(
                "Bn254Instance bytes length {} must be multiple of 32",
                bytes.len()
            )));
        }
        let mut scalars = Vec::with_capacity(bytes.len() / 32);
        for chunk in bytes.chunks_exact(32) {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(chunk);
            #[cfg(feature = "bn254")]
            {
                // Range-check each limb.
                let _ = fr_from_be32_checked(&arr)?;
            }
            scalars.push(Bn254Scalar(arr));
        }
        let size = scalars.len();
        Ok(Self { i: scalars, size })
    }

    #[cfg(feature = "bn254")]
    pub fn to_fr_vec(&self) -> ZkResult<Vec<Fr>> {
        self.i.iter().map(|s| s.to_fr()).collect()
    }
}

// ── Verifying key ─────────────────────────────────────────────────────────

/// Verifying key for a BN254 Groth16 circuit.
///
/// `vk_bytes` holds ark-compressed `VerifyingKey<Bn254>` (optionally with a
/// zero-length empty-param prefix from split storage).
#[derive(Debug, Clone)]
pub struct Bn254VerifyingKey {
    /// Raw verifying-key body (ark-compressed VK; empty-param prefix empty).
    pub vk_bytes: Vec<u8>,
    pub footer: crate::CircuitFooter,
}

impl Bn254VerifyingKey {
    pub fn new(vk_bytes: Vec<u8>, footer: crate::CircuitFooter) -> Self {
        Self { vk_bytes, footer }
    }

    /// Reconstruct from split param + vk-body files.
    ///
    /// Groth16 has no reusable Halo2-style params: `param_len` is typically 0
    /// and `param_bytes` may be empty.
    pub fn from_split_bytes(
        param_bytes: &[u8],
        vk_body_bytes: &[u8],
        footer: crate::CircuitFooter,
    ) -> ZkResult<Self> {
        if param_bytes.len() as u32 != footer.param_len {
            return Err(ZkError::format_err(format!(
                "param bytes length {} != footer.param_len {}",
                param_bytes.len(),
                footer.param_len
            )));
        }
        let expected_vk_body = (footer.cs_len as usize).saturating_add(footer.vk_len as usize);
        if vk_body_bytes.len() != expected_vk_body {
            return Err(ZkError::format_err(format!(
                "vk body length {} != cs_len+vk_len {}",
                vk_body_bytes.len(),
                expected_vk_body
            )));
        }
        let mut vk_bytes =
            Vec::with_capacity(param_bytes.len().saturating_add(vk_body_bytes.len()));
        vk_bytes.extend_from_slice(param_bytes);
        vk_bytes.extend_from_slice(vk_body_bytes);
        Ok(Self::new(vk_bytes, footer))
    }

    /// Verify a Groth16 proof against BN254 public inputs.
    ///
    /// - Format errors (bad proof/VK encoding, PI length, Fr ≥ r) → `ZkError::FormatErr`
    /// - Well-formed but invalid proof → `ZkError::VerifyFailed`
    /// - Valid proof → `Ok(())`
    pub fn verify(&self, proof: &crate::Proof, instances: &[Bn254Instance]) -> ZkResult<()> {
        #[cfg(feature = "bn254")]
        {
            self.verify_ark(proof, instances)
        }
        #[cfg(not(feature = "bn254"))]
        {
            let _ = (proof, instances);
            Err(ZkError::new_err("BN254 feature not enabled"))
        }
    }

    #[cfg(feature = "bn254")]
    fn verify_ark(&self, proof: &crate::Proof, instances: &[Bn254Instance]) -> ZkResult<()> {
        // Collect public inputs: typically a single Bn254Instance with n Frs.
        let mut public_inputs: Vec<Fr> = Vec::new();
        for inst in instances {
            public_inputs.extend(inst.to_fr_vec()?);
        }

        // H-05: always enforce footer.i when set; 0 means "unspecified" and we
        // still enforce VK gamma_abc arity below.
        let expected = self.footer.i as usize;
        if expected > 0 && public_inputs.len() != expected {
            return Err(ZkError::format_err(format!(
                "public input count {} != footer.i {}",
                public_inputs.len(),
                expected
            )));
        }

        let ark_vk = deserialize_ark_vk(&self.vk_bytes)?;
        // gamma_abc_g1 has length n_public + 1
        let n_from_vk = ark_vk.gamma_abc_g1.len().saturating_sub(1);
        if public_inputs.len() != n_from_vk {
            return Err(ZkError::format_err(format!(
                "public input count {} != vk gamma_abc_g1-1 {}",
                public_inputs.len(),
                n_from_vk
            )));
        }

        let ark_proof = deserialize_ark_proof(&proof.0)?;

        let pvk = Groth16::<Bn254>::process_vk(&ark_vk)
            .map_err(|e| ZkError::format_err(format!("prepare verifying key failed: {e}")))?;

        let ok = Groth16::<Bn254>::verify_with_processed_vk(&pvk, &public_inputs, &ark_proof)
            .map_err(|e| ZkError::format_err(format!("groth16 verify error: {e}")))?;

        if ok {
            Ok(())
        } else {
            Err(ZkError::VerifyFailed)
        }
    }
}

impl TryFrom<&[u8]> for Bn254VerifyingKey {
    type Error = ZkError;

    fn try_from(bytes: &[u8]) -> Result<Self, Self::Error> {
        if bytes.len() < COSMWASM_FOOTER_LENGTH {
            return Err(ZkError::format_err("Data too short for footer"));
        }
        let footer =
            crate::CircuitFooter::from_bytes(&bytes[bytes.len() - COSMWASM_FOOTER_LENGTH..])?;
        let vk_bytes = bytes[..bytes.len() - COSMWASM_FOOTER_LENGTH].to_vec();
        Ok(Self { vk_bytes, footer })
    }
}

// ── ZkCurve impl ──────────────────────────────────────────────────────────

impl ZkCurve for Bn254Affine {
    const ID: u32 = 4;

    type Scalar = Bn254Scalar;
    type Affine = Bn254Affine;

    type Params = ();
    type Instance = Bn254Instance;
    type VerifyingKey = Bn254VerifyingKey;
    type ProvingKey = ();
    type ConstraintSystem = ();

    fn scalar_from_bytes(bytes: &[u8; 32]) -> Option<Self::Scalar> {
        Bn254Scalar::from_bytes(bytes)
    }

    fn scalar_to_bytes(s: &Self::Scalar) -> [u8; 32] {
        s.to_bytes()
    }
}

// ── Ark helpers ───────────────────────────────────────────────────────────

#[cfg(feature = "bn254")]
fn fr_from_be32_checked(bytes: &[u8; 32]) -> ZkResult<Fr> {
    let fr = Fr::from_be_bytes_mod_order(bytes);
    // Reject non-canonical (Fr ≥ r would wrap under mod_order).
    let mut reencoded = fr.into_bigint().to_bytes_be();
    // Pad/truncate to 32 bytes BE.
    if reencoded.len() > 32 {
        return Err(ZkError::format_err("Fr encoding longer than 32 bytes"));
    }
    if reencoded.len() < 32 {
        let mut padded = vec![0u8; 32 - reencoded.len()];
        padded.extend_from_slice(&reencoded);
        reencoded = padded;
    }
    if reencoded.as_slice() != bytes.as_slice() {
        return Err(ZkError::format_err(
            "Fr limb not canonical big-endian in [0, r)",
        ));
    }
    Ok(fr)
}

#[cfg(feature = "bn254")]
fn fr_to_be32(fr: &Fr) -> [u8; 32] {
    let bytes = fr.into_bigint().to_bytes_be();
    let mut out = [0u8; 32];
    let start = 32 - bytes.len().min(32);
    out[start..].copy_from_slice(&bytes[bytes.len().saturating_sub(32)..]);
    out
}

#[cfg(feature = "bn254")]
fn deserialize_ark_vk(bytes: &[u8]) -> ZkResult<ArkVerifyingKey<Bn254>> {
    // Validate::No: snarkjs-imported points use new_unchecked; groth16 verify is the gate.
    ArkVerifyingKey::<Bn254>::deserialize_with_mode(bytes, Compress::Yes, Validate::No)
        .map_err(|e| ZkError::format_err(format!("invalid ark VerifyingKey encoding: {e}")))
}

#[cfg(feature = "bn254")]
fn deserialize_ark_proof(bytes: &[u8]) -> ZkResult<ArkProof<Bn254>> {
    ArkProof::<Bn254>::deserialize_with_mode(bytes, Compress::Yes, Validate::No)
        .map_err(|e| ZkError::format_err(format!("invalid ark Proof encoding: {e}")))
}

/// Serialize an ark VerifyingKey to compressed bytes (VK body for Phase A blob).
#[cfg(feature = "bn254")]
pub fn serialize_ark_vk(vk: &ArkVerifyingKey<Bn254>) -> ZkResult<Vec<u8>> {
    let mut buf = Vec::new();
    vk.serialize_with_mode(&mut buf, Compress::Yes)
        .map_err(|e| ZkError::format_err(format!("serialize VK: {e}")))?;
    Ok(buf)
}

/// Serialize an ark Proof to compressed bytes.
#[cfg(feature = "bn254")]
pub fn serialize_ark_proof(proof: &ArkProof<Bn254>) -> ZkResult<Vec<u8>> {
    let mut buf = Vec::new();
    proof
        .serialize_with_mode(&mut buf, Compress::Yes)
        .map_err(|e| ZkError::format_err(format!("serialize proof: {e}")))?;
    Ok(buf)
}

/// Encode Fr slice as concatenated BE 32-byte limbs.
#[cfg(feature = "bn254")]
pub fn encode_public_inputs_be(inputs: &[Fr]) -> Vec<u8> {
    let mut out = Vec::with_capacity(inputs.len() * 32);
    for fr in inputs {
        out.extend_from_slice(&fr_to_be32(fr));
    }
    out
}

/// Build a Phase A empty-param circuit blob around an ark-compressed VK body.
#[cfg(feature = "bn254")]
pub fn build_bn254_circuit_blob(vk_body: &[u8], n_public: u8) -> ZkResult<Vec<u8>> {
    use sha2::{Digest, Sha256};

    let param_checksum: [u8; 32] = Sha256::digest([]).into();
    let vk_checksum: [u8; 32] = Sha256::digest(vk_body).into();
    let footer = crate::CircuitFooter::new(
        crate::CircuitType::Groth16,
        crate::curves::CurveType::Bn254,
        0,
        n_public,
        0,
        0,
        vk_body.len() as u32,
        param_checksum,
        vk_checksum,
    );
    let mut blob = Vec::with_capacity(vk_body.len() + COSMWASM_FOOTER_LENGTH);
    blob.extend_from_slice(vk_body);
    blob.extend_from_slice(&footer.to_bytes());
    Ok(blob)
}

// ── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalar_roundtrip() {
        let bytes = [0x42u8; 32];
        let s = Bn254Scalar::from_bytes(&bytes).unwrap();
        assert_eq!(s.to_bytes(), bytes);
    }

    #[test]
    fn instance_from_bytes() {
        // Two small BE Frs (canonical).
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&[0u8; 31]);
        bytes.push(0x01);
        bytes.extend_from_slice(&[0u8; 31]);
        bytes.push(0x02);
        let inst = Bn254Instance::from_bytes(&bytes).unwrap();
        assert_eq!(inst.size, 2);
    }

    #[test]
    fn zkcurve_id() {
        assert_eq!(<Bn254Affine as ZkCurve>::ID, 4);
    }

    #[test]
    fn from_split_bytes_empty_param() {
        use sha2::{Digest, Sha256};

        let vk_body = b"synthetic-bn254-vk-body".to_vec();
        let param_checksum: [u8; 32] = Sha256::digest([]).into();
        let vk_checksum: [u8; 32] = Sha256::digest(&vk_body).into();
        let footer = crate::CircuitFooter::new(
            crate::CircuitType::Groth16,
            crate::curves::CurveType::Bn254,
            0,
            2,
            0,
            0,
            vk_body.len() as u32,
            param_checksum,
            vk_checksum,
        );
        let vk = Bn254VerifyingKey::from_split_bytes(&[], &vk_body, footer).unwrap();
        assert_eq!(vk.vk_bytes, vk_body);
        assert_eq!(vk.footer.curve_id, 4);
        assert_eq!(vk.footer.prover_id, crate::CircuitType::Groth16 as u8);
    }

    #[test]
    fn empty_vk_verify_is_format_err() {
        let vk = Bn254VerifyingKey {
            vk_bytes: vec![],
            footer: crate::CircuitFooter {
                prover_id: crate::CircuitType::Groth16 as u8,
                curve_id: 4,
                k: 0,
                i: 0,
                param_len: 0,
                cs_len: 0,
                vk_len: 0,
                param_checksum: [0u8; 32],
                vk_checksum: [0u8; 32],
            },
        };
        let proof = crate::Proof::new(vec![]);
        let inst = Bn254Instance::new(vec![]);
        let result = vk.verify(&proof, &[inst]);
        assert!(result.is_err());
        let err = result.unwrap_err();
        // Format error, not the old stub string.
        assert!(
            err.is_format_err() || matches!(err, ZkError::FormatErr(_)),
            "got: {err}"
        );
    }

    /// Tiny multiplier circuit (a * b = c public) — golden generate + verify.
    #[test]
    fn golden_multiplier_prove_and_verify() {
        use ark_crypto_primitives::snark::SNARK;
        use ark_relations::{
            lc,
            r1cs::{ConstraintSynthesizer, ConstraintSystemRef, SynthesisError},
        };
        use ark_std::rand::SeedableRng;
        use rand::rngs::StdRng;

        #[derive(Clone)]
        struct MultCircuit {
            a: Option<Fr>,
            b: Option<Fr>,
        }

        impl ConstraintSynthesizer<Fr> for MultCircuit {
            fn generate_constraints(
                self,
                cs: ConstraintSystemRef<Fr>,
            ) -> Result<(), SynthesisError> {
                let a =
                    cs.new_witness_variable(|| self.a.ok_or(SynthesisError::AssignmentMissing))?;
                let b =
                    cs.new_witness_variable(|| self.b.ok_or(SynthesisError::AssignmentMissing))?;
                let c = cs.new_input_variable(|| {
                    let mut a = self.a.ok_or(SynthesisError::AssignmentMissing)?;
                    let b = self.b.ok_or(SynthesisError::AssignmentMissing)?;
                    a *= &b;
                    Ok(a)
                })?;
                cs.enforce_constraint(lc!() + a, lc!() + b, lc!() + c)?;
                Ok(())
            }
        }

        let mut rng = StdRng::seed_from_u64(42);
        let (pk, ark_vk) =
            Groth16::<Bn254>::circuit_specific_setup(MultCircuit { a: None, b: None }, &mut rng)
                .expect("setup");

        let a = Fr::from(3u64);
        let b = Fr::from(5u64);
        let mut c = a;
        c *= &b;

        let ark_proof = Groth16::<Bn254>::prove(
            &pk,
            MultCircuit {
                a: Some(a),
                b: Some(b),
            },
            &mut rng,
        )
        .expect("prove");

        let vk_body = serialize_ark_vk(&ark_vk).unwrap();
        let proof_bytes = serialize_ark_proof(&ark_proof).unwrap();
        let public_bytes = encode_public_inputs_be(&[c]);
        let blob = build_bn254_circuit_blob(&vk_body, 1).unwrap();

        // Round-trip via Phase A types.
        let loaded = Bn254VerifyingKey::try_from(blob.as_slice()).unwrap();
        assert_eq!(loaded.footer.curve_id, 4);
        assert_eq!(loaded.footer.prover_id, 1);
        assert_eq!(loaded.footer.param_len, 0);

        let inst = Bn254Instance::from_bytes(&public_bytes).unwrap();
        let proof = crate::Proof::new(proof_bytes.clone());
        loaded.verify(&proof, &[inst.clone()]).expect("verify true");

        // Bit-flip proof → VerifyFailed (or format if structure breaks).
        let mut bad_proof = proof_bytes.clone();
        if let Some(last) = bad_proof.last_mut() {
            *last ^= 0x01;
        }
        let bad = loaded.verify(&crate::Proof::new(bad_proof), &[inst.clone()]);
        assert!(bad.is_err());
        // Prefer VerifyFailed; format err also acceptable for corrupt encoding.
        let e = bad.unwrap_err();
        assert!(e.is_verify_failed() || e.is_format_err(), "unexpected: {e}");

        // Wrong public input → VerifyFailed
        let wrong_pub = encode_public_inputs_be(&[a]); // a instead of c
        let wrong_inst = Bn254Instance::from_bytes(&wrong_pub).unwrap();
        let wrong = loaded.verify(&proof, &[wrong_inst]);
        assert!(matches!(wrong, Err(ZkError::VerifyFailed)));

        // PI length mismatch → FormatErr
        let two = encode_public_inputs_be(&[c, a]);
        let two_inst = Bn254Instance::from_bytes(&two).unwrap();
        let len_err = loaded.verify(&proof, &[two_inst]);
        assert!(len_err.unwrap_err().is_format_err());

        // Fr ≥ r → format error on instance parse
        let ge_r = [0xffu8; 32];
        let ge_err = Bn254Instance::from_bytes(&ge_r);
        assert!(ge_err.unwrap_err().is_format_err());

        // Sanity: n_public from vk
        assert_eq!(ark_vk.gamma_abc_g1.len(), 2); // 1 public + 1
    }

    /// Write committed golden fixtures under packages/zk/testdata when
    /// `ZK_WRITE_GOLDEN=1` (developer regenerate path). Always verifies round-trip.
    #[test]
    fn write_or_load_committed_golden_fixtures() {
        use ark_crypto_primitives::snark::SNARK;
        use ark_relations::{
            lc,
            r1cs::{ConstraintSynthesizer, ConstraintSystemRef, SynthesisError},
        };
        use ark_std::rand::SeedableRng;
        use rand::rngs::StdRng;
        use std::path::PathBuf;

        #[derive(Clone)]
        struct MultCircuit {
            a: Option<Fr>,
            b: Option<Fr>,
        }

        impl ConstraintSynthesizer<Fr> for MultCircuit {
            fn generate_constraints(
                self,
                cs: ConstraintSystemRef<Fr>,
            ) -> Result<(), SynthesisError> {
                let a =
                    cs.new_witness_variable(|| self.a.ok_or(SynthesisError::AssignmentMissing))?;
                let b =
                    cs.new_witness_variable(|| self.b.ok_or(SynthesisError::AssignmentMissing))?;
                let c = cs.new_input_variable(|| {
                    let mut a = self.a.ok_or(SynthesisError::AssignmentMissing)?;
                    let b = self.b.ok_or(SynthesisError::AssignmentMissing)?;
                    a *= &b;
                    Ok(a)
                })?;
                cs.enforce_constraint(lc!() + a, lc!() + b, lc!() + c)?;
                Ok(())
            }
        }

        // Deterministic fixtures (seed 42, a=3, b=5, c=15).
        let mut rng = StdRng::seed_from_u64(42);
        let (pk, ark_vk) =
            Groth16::<Bn254>::circuit_specific_setup(MultCircuit { a: None, b: None }, &mut rng)
                .expect("setup");
        let a = Fr::from(3u64);
        let b = Fr::from(5u64);
        let mut c = a;
        c *= &b;
        let ark_proof = Groth16::<Bn254>::prove(
            &pk,
            MultCircuit {
                a: Some(a),
                b: Some(b),
            },
            &mut rng,
        )
        .expect("prove");

        let vk_body = serialize_ark_vk(&ark_vk).unwrap();
        let proof_bytes = serialize_ark_proof(&ark_proof).unwrap();
        let public_bytes = encode_public_inputs_be(&[c]);
        let blob = build_bn254_circuit_blob(&vk_body, 1).unwrap();

        let testdata = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata");
        if std::env::var("ZK_WRITE_GOLDEN").ok().as_deref() == Some("1") {
            std::fs::create_dir_all(&testdata).unwrap();
            std::fs::write(testdata.join("square_vk.bin"), &blob).unwrap();
            std::fs::write(testdata.join("square_proof.bin"), &proof_bytes).unwrap();
            std::fs::write(testdata.join("square_public.bin"), &public_bytes).unwrap();
            eprintln!("wrote golden fixtures to {}", testdata.display());
        }

        // Prefer committed fixtures when present (CI / Path A).
        let blob = std::fs::read(testdata.join("square_vk.bin")).unwrap_or(blob);
        let proof_bytes = std::fs::read(testdata.join("square_proof.bin")).unwrap_or(proof_bytes);
        let public_bytes =
            std::fs::read(testdata.join("square_public.bin")).unwrap_or(public_bytes);

        let loaded = Bn254VerifyingKey::try_from(blob.as_slice()).expect("load blob");
        let inst = Bn254Instance::from_bytes(&public_bytes).unwrap();
        loaded
            .verify(&crate::Proof::new(proof_bytes), &[inst])
            .expect("committed golden must verify");
    }
}
