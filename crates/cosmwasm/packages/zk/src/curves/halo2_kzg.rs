//! Halo2-axiom KZG / SHPLONK on BN256 (`curve_id = 6`).
//!
//! Blob layout (same CosmWasm footer as Pasta / Groth16):
//! `[ParamsKZG RawBytesUnchecked | cs_json | vk_bytes | 80-byte CircuitFooter]`
//!
//! `cs` is UTF-8 `BaseCircuitParams` JSON so the host can reconstruct
//! `BaseCircuitBuilder<Fr>` for `VerifyingKey::read` (Axiom requires a
//! `ConcreteCircuit` whose `configure` matches keygen).

use crate::{CircuitFooter, Proof, ZkError, ZkResult};
use halo2_axiom::halo2curves::bn256::{Bn256, Fr, G1Affine};
use halo2_axiom::plonk::{verify_proof, VerifyingKey};
use halo2_axiom::poly::commitment::ParamsProver;
use halo2_axiom::poly::kzg::commitment::{KZGCommitmentScheme, ParamsKZG};
use halo2_axiom::poly::kzg::multiopen::VerifierSHPLONK;
use halo2_axiom::poly::kzg::strategy::SingleStrategy;
use halo2_axiom::transcript::{Blake2bRead, Challenge255, TranscriptReadBuffer};
use halo2_axiom::SerdeFormat;
use halo2_base::gates::circuit::builder::BaseCircuitBuilder;
use halo2_base::gates::circuit::{BaseCircuitParams, CircuitBuilderStage};
use crate::COSMWASM_FOOTER_LENGTH;
use sha2::{Digest, Sha256};

/// Footer `curve_id` for Axiom Halo2 KZG BN256 (not Groth16 BN254).
pub const HALO2_KZG_CURVE_ID: u8 = 6;

#[derive(Debug, Clone)]
pub struct Halo2KzgInstance {
    pub scalars: Vec<Fr>,
}

impl Halo2KzgInstance {
    pub fn from_bytes(bytes: &[u8]) -> ZkResult<Self> {
        if bytes.len() % 32 != 0 {
            return Err(ZkError::format_err(format!(
                "halo2-kzg public-input length {} is not a multiple of 32",
                bytes.len()
            )));
        }
        let mut scalars = Vec::with_capacity(bytes.len() / 32);
        for chunk in bytes.chunks_exact(32) {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(chunk);
            let s = Option::<Fr>::from(Fr::from_bytes(&arr)).ok_or(ZkError::InvalidScalar)?;
            scalars.push(s);
        }
        Ok(Self { scalars })
    }
}

#[derive(Debug, Clone)]
pub struct Halo2KzgVerifyingKey {
    pub params: ParamsKZG<Bn256>,
    pub vk: VerifyingKey<G1Affine>,
    pub footer: CircuitFooter,
    pub config: BaseCircuitParams,
}

impl Halo2KzgVerifyingKey {
    pub fn try_from_blob(bytes: &[u8]) -> ZkResult<Self> {
        if bytes.len() < COSMWASM_FOOTER_LENGTH {
            return Err(ZkError::new_err("halo2-kzg blob too short"));
        }
        let footer = CircuitFooter::from_bytes(&bytes[bytes.len() - COSMWASM_FOOTER_LENGTH..])?;
        let param_len = footer.param_len as usize;
        let body_end = bytes.len() - COSMWASM_FOOTER_LENGTH;
        if param_len > body_end {
            return Err(ZkError::format_err("halo2-kzg param_len exceeds body"));
        }
        Self::from_split_bytes(&bytes[..param_len], &bytes[param_len..body_end], footer)
    }

    pub fn from_split_bytes(
        param_bytes: &[u8],
        vk_body_bytes: &[u8],
        footer: CircuitFooter,
    ) -> ZkResult<Self> {
        if footer.curve_id != HALO2_KZG_CURVE_ID {
            return Err(ZkError::UnsupportedCurve(footer.appstate_key()));
        }
        if param_bytes.len() as u32 != footer.param_len {
            return Err(ZkError::new_err(format!(
                "halo2-kzg param bytes {} != footer.param_len {}",
                param_bytes.len(),
                footer.param_len
            )));
        }
        let expected = (footer.cs_len as usize).saturating_add(footer.vk_len as usize);
        if footer.cs_len != 0 || footer.vk_len != 0 {
            if vk_body_bytes.len() != expected {
                return Err(ZkError::new_err(format!(
                    "halo2-kzg vk body {} != cs+vk {}",
                    vk_body_bytes.len(),
                    expected
                )));
            }
        }
        let cs_len = footer.cs_len as usize;
        if cs_len > vk_body_bytes.len() {
            return Err(ZkError::new_err("halo2-kzg cs_len exceeds vk body"));
        }
        let (cs_bytes, vk_bytes) = if footer.cs_len == 0 && footer.vk_len == 0 {
            return Err(ZkError::new_err(
                "halo2-kzg requires BaseCircuitParams JSON in cs region",
            ));
        } else {
            vk_body_bytes.split_at(cs_len)
        };

        let config: BaseCircuitParams = serde_json::from_slice(cs_bytes)
            .map_err(|e| ZkError::format_err(format!("halo2-kzg BaseCircuitParams JSON: {e}")))?;

        let mut preader = std::io::Cursor::new(param_bytes);
        let params = ParamsKZG::<Bn256>::read_custom(&mut preader, SerdeFormat::RawBytesUnchecked)
            .map_err(|e| ZkError::format_err(format!("halo2-kzg ParamsKZG: {e}")))?;

        let builder = BaseCircuitBuilder::<Fr>::from_stage(CircuitBuilderStage::Keygen)
            .use_params(config.clone());
        let mut vreader = std::io::Cursor::new(vk_bytes);
        let vk = VerifyingKey::<G1Affine>::read::<_, BaseCircuitBuilder<Fr>>(
            &mut vreader,
            SerdeFormat::RawBytesUnchecked,
            config.clone(),
        )
        .map_err(|e| ZkError::format_err(format!("halo2-kzg VK: {e}")))?;
        let _ = builder;

        Ok(Self {
            params,
            vk,
            footer,
            config,
        })
    }

    pub fn to_bytes_with_params(&self) -> ZkResult<Vec<u8>> {
        let mut params_body = Vec::new();
        self.params
            .write_custom(&mut params_body, SerdeFormat::RawBytesUnchecked)
            .map_err(|e| ZkError::format_err(format!("write params: {e}")))?;
        let cs = serde_json::to_vec(&self.config)
            .map_err(|e| ZkError::format_err(format!("config json: {e}")))?;
        let mut vk_bytes = Vec::new();
        self.vk
            .write(&mut vk_bytes, SerdeFormat::RawBytesUnchecked)
            .map_err(|e| ZkError::format_err(format!("write vk: {e}")))?;
        let mut out = params_body;
        out.extend_from_slice(&cs);
        out.extend_from_slice(&vk_bytes);
        out.extend_from_slice(&self.footer.to_bytes());
        Ok(out)
    }

    pub fn verify(&self, proof: &Proof, inst: &Halo2KzgInstance) -> ZkResult<()> {
        if inst.scalars.len() != self.footer.i as usize {
            return Err(ZkError::format_err(format!(
                "halo2-kzg expected {} public inputs, got {}",
                self.footer.i,
                inst.scalars.len()
            )));
        }
        let strategy = SingleStrategy::new(&self.params);
        let mut transcript = Blake2bRead::<_, G1Affine, Challenge255<_>>::init(&proof.0[..]);
        let inst_ref: &[&[Fr]] = &[&inst.scalars];
        match verify_proof::<
            KZGCommitmentScheme<Bn256>,
            VerifierSHPLONK<'_, Bn256>,
            Challenge255<G1Affine>,
            Blake2bRead<&[u8], G1Affine, Challenge255<G1Affine>>,
            SingleStrategy<'_, Bn256>,
        >(
            self.params.verifier_params(),
            &self.vk,
            strategy,
            &[inst_ref],
            &mut transcript,
        ) {
            Ok(()) => Ok(()),
            Err(_) => Err(ZkError::VerifyFailed),
        }
    }
}

impl TryFrom<&[u8]> for Halo2KzgVerifyingKey {
    type Error = ZkError;
    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        Self::try_from_blob(value)
    }
}

/// Build a CosmWasm footer for an Axiom KZG export (`prover_id=0`, `curve_id=6`).
pub fn kzg_footer(
    k: u8,
    i: u8,
    param_bytes: &[u8],
    cs_bytes: &[u8],
    vk_bytes: &[u8],
) -> CircuitFooter {
    let mut vk_body = Vec::with_capacity(cs_bytes.len() + vk_bytes.len());
    vk_body.extend_from_slice(cs_bytes);
    vk_body.extend_from_slice(vk_bytes);
    let param_hash: [u8; 32] = Sha256::digest(param_bytes).into();
    let vk_hash: [u8; 32] = Sha256::digest(&vk_body).into();
    CircuitFooter::new(
        crate::CircuitType::Plonkish,
        crate::curves::CurveType::Bn256Kzg,
        k,
        i,
        param_bytes.len() as u32,
        cs_bytes.len() as u32,
        vk_bytes.len() as u32,
        param_hash,
        vk_hash,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use halo2_axiom::plonk::{keygen_pk, keygen_vk};
    use halo2_axiom::poly::commitment::ParamsProver;
    use rand::rngs::OsRng;

    #[test]
    fn kzg_footer_roundtrip_check_lens() {
        let params = b"params-bytes";
        let cs = br#"{"k":4}"#;
        let vk = b"vk-bytes";
        let f = kzg_footer(4, 1, params, cs, vk);
        assert_eq!(f.curve_id, HALO2_KZG_CURVE_ID);
        assert_eq!(f.param_len as usize, params.len());
        assert_eq!(f.cs_len as usize, cs.len());
        assert_eq!(f.vk_len as usize, vk.len());
        let bytes = f.to_bytes();
        let f2 = CircuitFooter::from_bytes(&bytes).unwrap();
        assert_eq!(f, f2);
    }

    /// Tiny empty-config builder: proves host can read ParamsKZG + VK + footer.
    #[test]
    fn kzg_store_blob_deserializes() {
        let mut builder =
            BaseCircuitBuilder::<Fr>::from_stage(CircuitBuilderStage::Keygen).use_k(4);
        builder.set_instance_columns(1);
        let config = builder.calculate_params(Some(9));
        let params = ParamsKZG::<Bn256>::setup(4, OsRng);
        let vk = keygen_vk(&params, &builder).expect("keygen_vk");
        let _pk = keygen_pk(&params, vk.clone(), &builder).expect("keygen_pk");
        let mut params_body = Vec::new();
        params
            .write_custom(&mut params_body, SerdeFormat::RawBytesUnchecked)
            .unwrap();
        let cs = serde_json::to_vec(&config).unwrap();
        let mut vk_bytes = Vec::new();
        vk.write(&mut vk_bytes, SerdeFormat::RawBytesUnchecked)
            .unwrap();
        let footer = kzg_footer(4, 0, &params_body, &cs, &vk_bytes);
        let mut blob = params_body.clone();
        blob.extend_from_slice(&cs);
        blob.extend_from_slice(&vk_bytes);
        blob.extend_from_slice(&footer.to_bytes());
        let loaded = Halo2KzgVerifyingKey::try_from_blob(&blob).expect("load kzg vk");
        assert_eq!(loaded.footer.curve_id, HALO2_KZG_CURVE_ID);
    }
}
