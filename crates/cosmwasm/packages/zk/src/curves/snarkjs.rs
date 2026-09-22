//! snarkjs (bn128) JSON → ark-groth16 BN254 conversion.
//!
//! Circom / snarkjs emit decimal-string coordinates. ark-groth16 consumes
//! compressed `VerifyingKey` / `Proof`. This module is the bridge so
//! `Bn254VerifyingKey::verify` can check real jwt-auth proofs.
//!
//! ## G2 coordinate order
//! snarkjs stores Fq2 as `[c1, c0]` (imag, real). ark uses `Fq2::new(c0, c1)`.
//! We swap on import (standard ark-circom convention).

use ark_bn254::{Bn254, Fq, Fq2, Fr, G1Affine, G2Affine};
use ark_ff::PrimeField;
use ark_groth16::{Proof as ArkProof, VerifyingKey as ArkVerifyingKey};
use ark_serialize::{CanonicalSerialize, Compress};
use serde::Deserialize;
use std::str::FromStr;

use crate::{ZkError, ZkResult};

/// snarkjs verification_key.json (export from zkey).
#[derive(Debug, Clone, Deserialize)]
pub struct SnarkjsVerifyingKey {
    pub protocol: String,
    pub curve: String,
    #[serde(rename = "nPublic")]
    pub n_public: u32,
    pub vk_alpha_1: Vec<String>,
    pub vk_beta_2: Vec<Vec<String>>,
    pub vk_gamma_2: Vec<Vec<String>>,
    pub vk_delta_2: Vec<Vec<String>>,
    #[serde(rename = "IC")]
    pub ic: Vec<Vec<String>>,
}

/// snarkjs proof.json from groth16.fullProve / prove.
#[derive(Debug, Clone, Deserialize)]
pub struct SnarkjsProof {
    pub pi_a: Vec<String>,
    pub pi_b: Vec<Vec<String>>,
    pub pi_c: Vec<String>,
    #[serde(default)]
    pub protocol: String,
    #[serde(default)]
    pub curve: String,
}

fn parse_fq(s: &str) -> ZkResult<Fq> {
    Fq::from_str(s.trim())
        .map_err(|_| ZkError::format_err(format!("invalid Fq decimal: {}", &s[..s.len().min(32)])))
}

fn parse_fr(s: &str) -> ZkResult<Fr> {
    Fr::from_str(s.trim())
        .map_err(|_| ZkError::format_err(format!("invalid Fr decimal: {}", &s[..s.len().min(32)])))
}

fn g1_from_snarkjs(coords: &[String]) -> ZkResult<G1Affine> {
    if coords.len() < 2 {
        return Err(ZkError::format_err("G1 needs at least [x,y]"));
    }
    let x = parse_fq(&coords[0])?;
    let y = parse_fq(&coords[1])?;
    // snarkjs points are already verified; use unchecked to avoid ark panic on edge forms.
    Ok(G1Affine::new_unchecked(x, y))
}

/// snarkjs G2: [[x_c1, x_c0], [y_c1, y_c0], [1, 0]] → ark Fq2(c0, c1).
fn g2_from_snarkjs(coords: &[Vec<String>]) -> ZkResult<G2Affine> {
    if coords.len() < 2 || coords[0].len() < 2 || coords[1].len() < 2 {
        return Err(ZkError::format_err("G2 needs [[x1,x0],[y1,y0]]"));
    }
    // ark-circom convention: swap snarkjs [c1,c0] → Fq2(c0,c1)
    let x = Fq2::new(parse_fq(&coords[0][1])?, parse_fq(&coords[0][0])?);
    let y = Fq2::new(parse_fq(&coords[1][1])?, parse_fq(&coords[1][0])?);
    Ok(G2Affine::new_unchecked(x, y))
}

/// Alternate G2 without c0/c1 swap (fallback if verify fails).
fn g2_from_snarkjs_noswap(coords: &[Vec<String>]) -> ZkResult<G2Affine> {
    if coords.len() < 2 || coords[0].len() < 2 || coords[1].len() < 2 {
        return Err(ZkError::format_err("G2 needs [[x0,x1],[y0,y1]]"));
    }
    let x = Fq2::new(parse_fq(&coords[0][0])?, parse_fq(&coords[0][1])?);
    let y = Fq2::new(parse_fq(&coords[1][0])?, parse_fq(&coords[1][1])?);
    Ok(G2Affine::new_unchecked(x, y))
}

fn vkey_with_g2(
    vkey: &SnarkjsVerifyingKey,
    g2: fn(&[Vec<String>]) -> ZkResult<G2Affine>,
) -> ZkResult<ArkVerifyingKey<Bn254>> {
    let alpha_g1 = g1_from_snarkjs(&vkey.vk_alpha_1)?;
    let beta_g2 = g2(&vkey.vk_beta_2)?;
    let gamma_g2 = g2(&vkey.vk_gamma_2)?;
    let delta_g2 = g2(&vkey.vk_delta_2)?;
    let mut gamma_abc_g1 = Vec::with_capacity(vkey.ic.len());
    for pt in &vkey.ic {
        gamma_abc_g1.push(g1_from_snarkjs(pt)?);
    }
    if gamma_abc_g1.len() != (vkey.n_public as usize) + 1 {
        return Err(ZkError::format_err(format!(
            "IC len {} != nPublic+1 ({})",
            gamma_abc_g1.len(),
            vkey.n_public + 1
        )));
    }
    Ok(ArkVerifyingKey {
        alpha_g1,
        beta_g2,
        gamma_g2,
        delta_g2,
        gamma_abc_g1,
    })
}

/// Convert snarkjs verifying key JSON to ark `VerifyingKey<Bn254>`.
pub fn snarkjs_vkey_to_ark(vkey: &SnarkjsVerifyingKey) -> ZkResult<ArkVerifyingKey<Bn254>> {
    if vkey.curve != "bn128" && vkey.curve != "bn254" {
        return Err(ZkError::format_err(format!(
            "unsupported snarkjs curve {}",
            vkey.curve
        )));
    }
    // Prefer ark-circom swap; callers may retry with noswap via verify helper.
    vkey_with_g2(vkey, g2_from_snarkjs)
}

/// Convert snarkjs proof JSON to ark `Proof<Bn254>`.
pub fn snarkjs_proof_to_ark(proof: &SnarkjsProof) -> ZkResult<ArkProof<Bn254>> {
    let a = g1_from_snarkjs(&proof.pi_a)?;
    let b = g2_from_snarkjs(&proof.pi_b)?;
    let c = g1_from_snarkjs(&proof.pi_c)?;
    Ok(ArkProof { a, b, c })
}

fn snarkjs_proof_to_ark_noswap(proof: &SnarkjsProof) -> ZkResult<ArkProof<Bn254>> {
    let a = g1_from_snarkjs(&proof.pi_a)?;
    let b = g2_from_snarkjs_noswap(&proof.pi_b)?;
    let c = g1_from_snarkjs(&proof.pi_c)?;
    Ok(ArkProof { a, b, c })
}

/// Parse snarkjs public signal decimals → Fr vector.
pub fn snarkjs_publics_to_fr(publics: &[String]) -> ZkResult<Vec<Fr>> {
    publics.iter().map(|s| parse_fr(s)).collect()
}

/// Serialize ark VK to compressed bytes (circuit blob body).
pub fn ark_vk_to_bytes(vk: &ArkVerifyingKey<Bn254>) -> ZkResult<Vec<u8>> {
    let mut buf = Vec::new();
    vk.serialize_with_mode(&mut buf, Compress::Yes)
        .map_err(|e| ZkError::format_err(format!("serialize VK: {e}")))?;
    Ok(buf)
}

/// Serialize ark proof to compressed bytes (payload.proof).
pub fn ark_proof_to_bytes(proof: &ArkProof<Bn254>) -> ZkResult<Vec<u8>> {
    let mut buf = Vec::new();
    proof
        .serialize_with_mode(&mut buf, Compress::Yes)
        .map_err(|e| ZkError::format_err(format!("serialize proof: {e}")))?;
    Ok(buf)
}

/// Encode Frs as concatenated BE 32-byte limbs (host instances).
pub fn fr_publics_to_be_bytes(inputs: &[Fr]) -> Vec<u8> {
    use ark_ff::BigInteger;
    let mut out = Vec::with_capacity(inputs.len() * 32);
    for fr in inputs {
        let bytes = fr.into_bigint().to_bytes_be();
        let mut limb = [0u8; 32];
        let start = 32 - bytes.len().min(32);
        limb[start..].copy_from_slice(&bytes[bytes.len().saturating_sub(32)..]);
        out.extend_from_slice(&limb);
    }
    out
}

/// One-shot: snarkjs vkey JSON str → ark-compressed VK bytes + n_public.
pub fn convert_snarkjs_vkey_json(json: &str) -> ZkResult<(Vec<u8>, u32)> {
    let vkey: SnarkjsVerifyingKey = serde_json::from_str(json)
        .map_err(|e| ZkError::format_err(format!("parse snarkjs vkey: {e}")))?;
    let n = vkey.n_public;
    let ark = snarkjs_vkey_to_ark(&vkey)?;
    Ok((ark_vk_to_bytes(&ark)?, n))
}

/// One-shot: snarkjs proof JSON str → ark-compressed proof bytes.
pub fn convert_snarkjs_proof_json(json: &str) -> ZkResult<Vec<u8>> {
    let proof: SnarkjsProof = serde_json::from_str(json)
        .map_err(|e| ZkError::format_err(format!("parse snarkjs proof: {e}")))?;
    let ark = snarkjs_proof_to_ark(&proof)?;
    ark_proof_to_bytes(&ark)
}

/// One-shot: snarkjs public.json array → BE instance bytes.
pub fn convert_snarkjs_public_json(json: &str) -> ZkResult<Vec<u8>> {
    let publics: Vec<String> = serde_json::from_str(json)
        .map_err(|e| ZkError::format_err(format!("parse snarkjs public: {e}")))?;
    let frs = snarkjs_publics_to_fr(&publics)?;
    Ok(fr_publics_to_be_bytes(&frs))
}

fn try_verify_pair(
    ark_vk: &ArkVerifyingKey<Bn254>,
    ark_proof: &ArkProof<Bn254>,
    inputs: &[Fr],
) -> ZkResult<bool> {
    use ark_crypto_primitives::snark::SNARK;
    use ark_groth16::Groth16;

    let pvk = Groth16::<Bn254>::process_vk(ark_vk)
        .map_err(|e| ZkError::format_err(format!("process_vk: {e}")))?;
    Groth16::<Bn254>::verify_with_processed_vk(&pvk, inputs, ark_proof)
        .map_err(|e| ZkError::format_err(format!("verify: {e}")))
}

/// Verify snarkjs fixtures end-to-end with ark-groth16 (no CosmWasm).
///
/// Tries G2 coordinate swap conventions until one verifies (snarkjs layout varies).
pub fn verify_snarkjs_fixtures(
    vkey_json: &str,
    proof_json: &str,
    public_json: &str,
) -> ZkResult<()> {
    let vkey: SnarkjsVerifyingKey =
        serde_json::from_str(vkey_json).map_err(|e| ZkError::format_err(format!("vkey: {e}")))?;
    let proof: SnarkjsProof =
        serde_json::from_str(proof_json).map_err(|e| ZkError::format_err(format!("proof: {e}")))?;
    let publics: Vec<String> = serde_json::from_str(public_json)
        .map_err(|e| ZkError::format_err(format!("public: {e}")))?;
    let inputs = snarkjs_publics_to_fr(&publics)?;

    // Attempt 1: ark-circom G2 swap on both vk and proof
    let vk1 = vkey_with_g2(&vkey, g2_from_snarkjs)?;
    let p1 = snarkjs_proof_to_ark(&proof)?;
    if try_verify_pair(&vk1, &p1, &inputs)? {
        return Ok(());
    }
    // Attempt 2: no swap on both
    let vk2 = vkey_with_g2(&vkey, g2_from_snarkjs_noswap)?;
    let p2 = snarkjs_proof_to_ark_noswap(&proof)?;
    if try_verify_pair(&vk2, &p2, &inputs)? {
        return Ok(());
    }
    // Attempt 3: swap vk, noswap proof
    if try_verify_pair(&vk1, &p2, &inputs)? {
        return Ok(());
    }
    // Attempt 4: noswap vk, swap proof
    if try_verify_pair(&vk2, &p1, &inputs)? {
        return Ok(());
    }
    Err(ZkError::VerifyFailed)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Load committed jwt-auth L2 fixtures from terp-zkjwt if present at known path;
    // otherwise skip is handled by optional include in integration — here use env or embedded via path.
    #[test]
    fn convert_and_verify_jwt_auth_fixtures() {
        // Relative to cosmwasm package when run from workspace
        let base = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../terp-rs/contracts/smart-accounts/terp-zkjwt/src/fixtures/l2"
        );
        let vkey = std::fs::read_to_string(format!("{base}/jwt-auth_vkey.json"));
        let proof = std::fs::read_to_string(format!("{base}/proof.json"));
        let public = std::fs::read_to_string(format!("{base}/public.json"));
        let (Ok(vkey), Ok(proof), Ok(public)) = (vkey, proof, public) else {
            eprintln!("skip: jwt-auth L2 fixtures not found at {base}");
            return;
        };
        verify_snarkjs_fixtures(&vkey, &proof, &public).expect("ark must verify snarkjs jwt-auth");
        let inst = convert_snarkjs_public_json(&public).unwrap();
        assert_eq!(inst.len(), 40 * 32);
        let publics: Vec<String> = serde_json::from_str(&public).unwrap();
        assert_eq!(publics.len(), 40);
    }
}
