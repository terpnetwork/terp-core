//! Zcash / Halo2 Poseidon over Pasta fields (`P128Pow5T3`).
//!
//! Matches `halo2_poseidon` / `halo2_gadgets::poseidon::primitives` used by
//! vote-sdk (`ConstantLength<N>`, T=3, RATE=2) and Orchard-style gadgets.

use group::ff::PrimeField;
use halo2_poseidon::{ConstantLength, Hash, P128Pow5T3, Spec};
use pasta_curves::{pallas, vesta};

use crate::{CryptoError, CryptoResult};

/// Canonical LE encoding size for Pasta base-field elements.
pub const PASTA_FIELD_BYTES: usize = 32;
/// Maximum number of field elements for one ConstantLength hash call.
pub const PASTA_MAX_ARITY: usize = 16;

type PallasBase = pallas::Base;
type VestaBase = vesta::Base;

fn parse_field<F: PrimeField<Repr = [u8; PASTA_FIELD_BYTES]>>(
    bytes: &[u8; PASTA_FIELD_BYTES],
) -> CryptoResult<F> {
    Option::from(F::from_repr(*bytes)).ok_or_else(CryptoError::invalid_hash_format)
}

fn field_to_bytes<F: PrimeField<Repr = [u8; PASTA_FIELD_BYTES]>>(f: F) -> [u8; PASTA_FIELD_BYTES] {
    f.to_repr()
}

fn parse_inputs<F: PrimeField<Repr = [u8; PASTA_FIELD_BYTES]>>(
    inputs: &[[u8; PASTA_FIELD_BYTES]],
) -> CryptoResult<Vec<F>> {
    if inputs.is_empty() || inputs.len() > PASTA_MAX_ARITY {
        return Err(CryptoError::generic_err(format!(
            "poseidon pasta arity must be 1..={PASTA_MAX_ARITY}, got {}",
            inputs.len()
        )));
    }
    inputs.iter().map(parse_field::<F>).collect()
}

fn parse_concatenated<F: PrimeField<Repr = [u8; PASTA_FIELD_BYTES]>>(
    inputs: &[u8],
) -> CryptoResult<Vec<F>> {
    if inputs.is_empty() || inputs.len() % PASTA_FIELD_BYTES != 0 {
        return Err(CryptoError::generic_err(
            "poseidon pasta inputs must be a non-empty multiple of 32 bytes",
        ));
    }
    let n = inputs.len() / PASTA_FIELD_BYTES;
    if n > PASTA_MAX_ARITY {
        return Err(CryptoError::generic_err(format!(
            "poseidon pasta arity must be 1..={PASTA_MAX_ARITY}, got {n}"
        )));
    }
    let mut out = Vec::with_capacity(n);
    for chunk in inputs.chunks_exact(PASTA_FIELD_BYTES) {
        let mut arr = [0u8; PASTA_FIELD_BYTES];
        arr.copy_from_slice(chunk);
        out.push(parse_field::<F>(&arr)?);
    }
    Ok(out)
}

/// Hash `L` field elements with Zcash Orchard `P128Pow5T3` ConstantLength domain.
fn hash_constant_length<F, const L: usize>(message: [F; L]) -> F
where
    F: PrimeField,
    P128Pow5T3: Spec<F, 3, 2>,
{
    Hash::<F, P128Pow5T3, ConstantLength<L>, 3, 2>::init().hash(message)
}

fn hash_variable_arity<F: PrimeField>(fields: &[F]) -> CryptoResult<F>
where
    P128Pow5T3: Spec<F, 3, 2>,
{
    // Runtime arity → const generic ConstantLength<L> (same pattern as vote-sdk / Orchard).
    match fields.len() {
        1 => Ok(hash_constant_length::<F, 1>([fields[0]])),
        2 => Ok(hash_constant_length::<F, 2>([fields[0], fields[1]])),
        3 => Ok(hash_constant_length::<F, 3>([
            fields[0], fields[1], fields[2],
        ])),
        4 => Ok(hash_constant_length::<F, 4>([
            fields[0], fields[1], fields[2], fields[3],
        ])),
        5 => Ok(hash_constant_length::<F, 5>([
            fields[0], fields[1], fields[2], fields[3], fields[4],
        ])),
        6 => Ok(hash_constant_length::<F, 6>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5],
        ])),
        7 => Ok(hash_constant_length::<F, 7>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6],
        ])),
        8 => Ok(hash_constant_length::<F, 8>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
        ])),
        9 => Ok(hash_constant_length::<F, 9>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8],
        ])),
        10 => Ok(hash_constant_length::<F, 10>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8], fields[9],
        ])),
        11 => Ok(hash_constant_length::<F, 11>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8], fields[9], fields[10],
        ])),
        12 => Ok(hash_constant_length::<F, 12>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8], fields[9], fields[10], fields[11],
        ])),
        13 => Ok(hash_constant_length::<F, 13>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8], fields[9], fields[10], fields[11], fields[12],
        ])),
        14 => Ok(hash_constant_length::<F, 14>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8], fields[9], fields[10], fields[11], fields[12], fields[13],
        ])),
        15 => Ok(hash_constant_length::<F, 15>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8], fields[9], fields[10], fields[11], fields[12], fields[13], fields[14],
        ])),
        16 => Ok(hash_constant_length::<F, 16>([
            fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8], fields[9], fields[10], fields[11], fields[12], fields[13], fields[14],
            fields[15],
        ])),
        n => Err(CryptoError::generic_err(format!(
            "poseidon pasta arity must be 1..={PASTA_MAX_ARITY}, got {n}"
        ))),
    }
}

/// Poseidon-Hash over **Pallas base field** (Zcash Orchard / vote-sdk default).
pub fn poseidon_hash_pallas(
    inputs: &[[u8; PASTA_FIELD_BYTES]],
) -> CryptoResult<[u8; PASTA_FIELD_BYTES]> {
    let fields = parse_inputs::<PallasBase>(inputs)?;
    let out = hash_variable_arity(&fields)?;
    Ok(field_to_bytes(out))
}

/// Same as [`poseidon_hash_pallas`] with concatenated input bytes.
pub fn poseidon_hash_pallas_bytes(inputs: &[u8]) -> CryptoResult<[u8; PASTA_FIELD_BYTES]> {
    let fields = parse_concatenated::<PallasBase>(inputs)?;
    let out = hash_variable_arity(&fields)?;
    Ok(field_to_bytes(out))
}

/// Poseidon-Hash over **Vesta base field** (Halo2 cycle dual of Pallas).
pub fn poseidon_hash_vesta(
    inputs: &[[u8; PASTA_FIELD_BYTES]],
) -> CryptoResult<[u8; PASTA_FIELD_BYTES]> {
    let fields = parse_inputs::<VestaBase>(inputs)?;
    let out = hash_variable_arity(&fields)?;
    Ok(field_to_bytes(out))
}

/// Same as [`poseidon_hash_vesta`] with concatenated input bytes.
pub fn poseidon_hash_vesta_bytes(inputs: &[u8]) -> CryptoResult<[u8; PASTA_FIELD_BYTES]> {
    let fields = parse_concatenated::<VestaBase>(inputs)?;
    let out = hash_variable_arity(&fields)?;
    Ok(field_to_bytes(out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use group::ff::Field;

    #[test]
    fn pallas_length2_matches_direct_orchard_style() {
        // Same check as halo2_poseidon orchard_spec_equivalence.
        let message = [PallasBase::from(6u64), PallasBase::from(42u64)];
        let via_hash =
            Hash::<PallasBase, P128Pow5T3, ConstantLength<2>, 3, 2>::init().hash(message);
        let bytes = [field_to_bytes(message[0]), field_to_bytes(message[1])];
        let wrapped = poseidon_hash_pallas(&bytes).unwrap();
        assert_eq!(wrapped, field_to_bytes(via_hash));
        assert_eq!(
            poseidon_hash_pallas(&bytes).unwrap(),
            poseidon_hash_pallas(&bytes).unwrap()
        );
    }

    #[test]
    fn pallas_bytes_concat_matches_array() {
        let a = field_to_bytes(PallasBase::from(1u64));
        let b = field_to_bytes(PallasBase::from(2u64));
        let arr = poseidon_hash_pallas(&[a, b]).unwrap();
        let mut concat = Vec::new();
        concat.extend_from_slice(&a);
        concat.extend_from_slice(&b);
        assert_eq!(arr, poseidon_hash_pallas_bytes(&concat).unwrap());
    }

    #[test]
    fn vesta_deterministic_and_differs() {
        let z = field_to_bytes(VestaBase::ZERO);
        let o = field_to_bytes(VestaBase::ONE);
        let h0 = poseidon_hash_vesta(&[z, z]).unwrap();
        let h1 = poseidon_hash_vesta(&[z, o]).unwrap();
        assert_ne!(h0, h1);
        assert_eq!(h0, poseidon_hash_vesta(&[z, z]).unwrap());
    }

    #[test]
    fn rejects_bad_length() {
        assert!(poseidon_hash_pallas_bytes(&[]).is_err());
        assert!(poseidon_hash_pallas_bytes(&[0u8; 31]).is_err());
        assert!(poseidon_hash_pallas_bytes(&[0u8; 17 * 32]).is_err());
    }

    #[test]
    fn rejects_non_canonical_field() {
        // 0xff… is not a valid Pasta field element.
        let bad = [0xffu8; 32];
        assert!(poseidon_hash_pallas(&[bad]).is_err());
    }

    #[test]
    fn length8_round_id_shape() {
        // vote-sdk derive_round_id uses ConstantLength<8> over pallas::Base.
        let elems: [[u8; 32]; 8] =
            std::array::from_fn(|i| field_to_bytes(PallasBase::from(i as u64)));
        let h = poseidon_hash_pallas(&elems).unwrap();
        assert_eq!(h.len(), 32);
        assert_ne!(h, [0u8; 32]);
    }
}
