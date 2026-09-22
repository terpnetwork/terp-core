// use std::io;

use crate::{
    circuits::{CwCircuitParam, CwConstraintSystem},
    curves::ZkCurve,
    CsBlueprint, CsBlueprintGuard, CwInstance, CwProvingKey, CwVerifyingKey, ZkError, ZkResult,
};
use group::ff::PrimeField as _;
use halo2_proofs::plonk::{self};
use pasta_curves::vesta;
pub use pasta_curves::vesta::{Affine as VestaAffine, Scalar as VestaScalar};
use sha2::{Digest as _, Sha256};

pub(crate) type VestaInstance = CwInstance<VestaAffine>;
pub(crate) type VestaVerifyingKey = CwVerifyingKey<VestaAffine>;
pub(crate) type _VestaProvingKey = CwProvingKey<VestaAffine>;
pub(crate) type _VestaConstraintSystem = CwConstraintSystem<VestaAffine>;
pub(crate) type VestaParams = CwCircuitParam<VestaAffine>;

impl TryFrom<halo2_proofs::poly::commitment::Params<vesta::Affine>> for VestaParams {
    type Error = ZkError;

    fn try_from(
        value: halo2_proofs::poly::commitment::Params<vesta::Affine>,
    ) -> Result<Self, Self::Error> {
        Ok(Self { params: value })
    }
}

impl ZkCurve for VestaAffine {
    const ID: u32 = 0;
    type Scalar = VestaScalar;
    type Affine = VestaAffine;

    type Params = halo2_proofs::poly::commitment::Params<Self::Affine>;
    type Instance = VestaInstance;
    type VerifyingKey = plonk::VerifyingKey<Self::Affine>;
    type ProvingKey = plonk::ProvingKey<Self::Affine>;
    type ConstraintSystem = plonk::ConstraintSystem<Self::Scalar>;

    fn scalar_from_bytes(bytes: &[u8; 32]) -> Option<Self::Scalar> {
        VestaScalar::from_repr(*bytes).into()
    }

    fn scalar_to_bytes(s: &Self::Scalar) -> [u8; 32] {
        s.to_repr()
    }
}

impl VestaInstance {
    pub fn new(i: Vec<VestaScalar>) -> Self {
        Self {
            i: i.to_vec(),
            size: i.len(),
        }
    }

    /// Decode host public inputs as concatenated **32-byte** field limbs
    /// (`PrimeField::Repr` / little-endian pasta encoding).
    ///
    /// **C-01:** Do **not** use `Scalar::CAPACITY` (bit capacity, 254) as a
    /// byte limb width — that rejects honest `32×n` encodings and panics on
    /// 254-aligned lengths when copying into `[u8; 32]`.
    pub fn new_from_vm(i: &Vec<u8>) -> crate::ZkResult<Self> {
        const SCALAR_SIZE: usize = 32;
        if i.len() % SCALAR_SIZE != 0 {
            return Err(ZkError::format_err(format!(
                "vesta public-input bytes length {} is not a multiple of {SCALAR_SIZE}",
                i.len()
            )));
        }
        let mut out = Vec::with_capacity(i.len() / SCALAR_SIZE);
        for chunk in i.chunks_exact(SCALAR_SIZE) {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(chunk);
            // from_repr returns Choice; reject non-canonical / out-of-range limbs.
            let ct = vesta::Scalar::from_repr(arr);
            if bool::from(ct.is_some()) {
                out.push(ct.unwrap());
            } else {
                return Err(ZkError::InvalidScalar);
            }
        }
        let size = out.len();
        Ok(Self { i: out, size })
    }

    pub fn get_size(&self) -> usize {
        self.size
    }
}

impl TryFrom<&[u8]> for VestaInstance {
    type Error = ZkError;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        VestaInstance::new_from_vm(&value.to_vec())
    }
}

#[cfg(test)]
mod instance_tests {
    use super::*;
    use group::ff::Field;

    #[test]
    fn vesta_public_inputs_32_byte_limbs() {
        let s = VestaScalar::ONE;
        let mut bytes = s.to_repr().as_ref().to_vec();
        assert_eq!(bytes.len(), 32);
        let inst = VestaInstance::new_from_vm(&bytes).expect("32-byte limb");
        assert_eq!(inst.get_size(), 1);

        bytes.extend_from_slice(s.to_repr().as_ref());
        let inst2 = VestaInstance::new_from_vm(&bytes).expect("64-byte two limbs");
        assert_eq!(inst2.get_size(), 2);
    }

    #[test]
    fn vesta_public_inputs_reject_wrong_len() {
        // Not multiple of 32
        assert!(VestaInstance::new_from_vm(&vec![0u8; 31]).is_err());
        // CAPACITY-bit fallacy would have accepted multiples of 254 — ensure 254 still errors
        assert!(VestaInstance::new_from_vm(&vec![0u8; 254]).is_err());
    }
}

impl TryFrom<&[u8]> for VestaVerifyingKey {
    type Error = ZkError;

    /// expects params bytes in bytes
    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        VestaVerifyingKey::from_bytes_with_params(value)
    }
}

impl TryInto<Vec<u8>> for VestaVerifyingKey {
    type Error = ZkError;

    fn try_into(self) -> Result<Vec<u8>, Self::Error> {
        Ok(self.to_bytes_with_params()?)
    }
}

// impl VestaProvingKey {
//     /// Build from a given circuit.
//     pub fn build<C>(k: u32, circuit: C) -> Self
//     where
//         C: plonk::Circuit<<pasta_curves::EqAffine as group::prime::PrimeCurveAffine>::Scalar>,
//     {
//         let params = halo2_proofs::poly::commitment::Params::new(k);
//         let wrapped_circuit = crate::CosmwasmCircuit { circuit };
//         let vk = plonk::keygen_vk(&params, &wrapped_circuit).unwrap();
//         let _pk = plonk::keygen_pk(&params, vk, &wrapped_circuit).unwrap();
//         // is there a way to implement th ZkCurve trait pk for this specific proving keym since its associated with VestAffine
//         CwProvingKey { params, _pk }
//     }

//     pub fn params(&self) -> halo2_proofs::poly::commitment::Params<VestaAffine> {
//         self.params.clone()
//     }
// }

impl VestaVerifyingKey {
    pub fn from_bytes_without_params(
        mut reader: &mut std::io::Cursor<&[u8]>,
        footer: crate::CircuitFooter,
        p: VestaParams,
    ) -> ZkResult<Self> {
        let cs = plonk::ConstraintSystem::read(&mut reader)?;
        let _guard = CsBlueprintGuard::install(CsBlueprint::from_cs(&cs)?);

        let vk = halo2_proofs::plonk::VerifyingKey::read_with_cs::<std::io::Cursor<&[u8]>>(
            &mut reader,
            &p.params,
            cs,
        )
        .map_err(|e| {
            ZkError::new_io(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("{:?}", e),
            ))
        })?;

        Ok(Self::new(p.params, vk, footer))
    }

    /// Reconstruct from separate param file bytes and cs+vk body bytes.
    pub fn from_split_bytes(
        param_bytes: &[u8],
        vk_body_bytes: &[u8],
        footer: crate::CircuitFooter,
    ) -> ZkResult<Self> {
        if param_bytes.len() as u32 != footer.param_len {
            return Err(ZkError::new_err(format!(
                "param bytes length {} != footer.param_len {}",
                param_bytes.len(),
                footer.param_len
            )));
        }
        let expected_vk_body = footer.cs_len as usize + footer.vk_len as usize;
        if vk_body_bytes.len() != expected_vk_body {
            return Err(ZkError::new_err(format!(
                "vk body length {} != cs_len+vk_len {}",
                vk_body_bytes.len(),
                expected_vk_body
            )));
        }

        let mut param_reader = std::io::Cursor::new(param_bytes);
        let params =
            halo2_proofs::poly::commitment::Params::<vesta::Affine>::read(&mut param_reader)?;
        let mut vk_reader = std::io::Cursor::new(vk_body_bytes);
        Self::from_bytes_without_params(&mut vk_reader, footer, VestaParams::try_from(params)?)
    }
}

impl VestaVerifyingKey {
    /// Create with existing params (use when deserializing).
    pub fn new(
        params: halo2_proofs::poly::commitment::Params<vesta::Affine>,
        vk: plonk::VerifyingKey<vesta::Affine>,
        footer: crate::CircuitFooter,
    ) -> Self {
        CwVerifyingKey { params, vk, footer }
    }
    // /// Verify this proof with the given instances.
    pub fn verify(&self, p: &crate::Proof, i: &[VestaInstance]) -> Result<(), plonk::Error> {
        let instances: Vec<Vec<pasta_curves::Fp>> = i
            .iter()
            .map(|inst| inst.i.iter().map(|&s| pasta_curves::Fp::from(s)).collect())
            .collect();

        let column_refs: Vec<&[pasta_curves::Fp]> =
            instances.iter().map(|v| v.as_slice()).collect();
        let instances_arg: &[&[&[pasta_curves::Fp]]] = &[&column_refs];
        let strategy = plonk::SingleVerifier::new(&self.params);
        let mut transcript = halo2_proofs::transcript::Blake2bRead::init(&p.0[..]);

        plonk::verify_proof(
            &self.params,
            &self.vk,
            strategy,
            instances_arg,
            &mut transcript,
        )
        .map_err(Into::into)
    }

    /// The embedded CS is deserialized and used for VK reconstruction,
    /// giving exact circuit-agnostic verification without the original Rust type.
    pub fn from_bytes_with_params(bytes: &[u8]) -> ZkResult<Self> {
        let footer_bytes = &bytes[bytes.len() - crate::COSMWASM_FOOTER_LENGTH..];
        let mut reader = std::io::Cursor::new(bytes);
        let params = halo2_proofs::poly::commitment::Params::<vesta::Affine>::read(&mut reader)?;
        Self::from_bytes_without_params(
            &mut reader,
            crate::CircuitFooter::from_bytes(footer_bytes)?,
            VestaParams::try_from(params)?,
        )
    }

    pub fn to_bytes_with_params(&self) -> std::io::Result<Vec<u8>> {
        let mut buf1 = Vec::new();
        let mut buf2 = Vec::new();
        let mut buf3 = Vec::new();

        self.params.write(&mut buf1)?;
        self.vk.cs().write(&mut buf2)?;
        self.vk.write(&mut buf3)?;

        println!(
            "cw::vm::vk::from_bytes::params::(len::{},checksum::{})",
            buf1.len(),
            hex::encode(&Sha256::digest(&buf1).to_vec()),
        );
        println!(
            "cw::vm::vk::from_bytes::cs::(len::{},checksum::{})",
            buf2.len(),
            hex::encode(&Sha256::digest(&buf2).to_vec()),
        );
        println!(
            "cw::vm::vk::from_bytes::(len::{},checksum::{})",
            buf3.len(),
            hex::encode(&Sha256::digest(&buf3).to_vec()),
        );

        let mut output = Vec::new();
        output.extend_from_slice(&buf1);
        output.extend_from_slice(&buf2);
        output.extend_from_slice(&buf3);
        output.extend_from_slice(&self.footer.to_bytes());

        Ok(output)
    }
}
