//! Arkworks-backed BN254 primitives.
//!
//! The three public functions in this module are the full implementation
//! surface that would be exposed to guest contracts via
//! `cosmwasm-std::Api::bn254_*`. Each one takes the exact byte layout used
//! by Ethereum's precompiles at addresses `0x06`, `0x07`, and `0x08` so
//! that existing Groth16 tooling (`snarkjs`, `circom`, `gnark`) can target
//! the CosmWasm VM with zero adaptation.

use alloc::vec::Vec;

use ark_bn254::{Bn254, Fq, Fq2, Fr, G1Affine, G2Affine};
use ark_ec::{pairing::Pairing, AffineRepr, CurveGroup};
use ark_ff::{BigInteger, PrimeField, Zero};

use crate::errors::Bn254Error;
use crate::{FQ_BYTES, FR_BYTES, G1_BYTES, G2_BYTES, PAIR_BYTES};

// ── Public API ─────────────────────────────────────────────────────────────

/// G1 point addition (Ethereum ECADD `0x06`).
///
/// # Input
///
/// `128` bytes: `g1_point_a || g1_point_b`, each point encoded as 64
/// big-endian bytes `x || y` with `(0, 0)` denoting the point at infinity.
///
/// # Output
///
/// `64` bytes: the sum encoded the same way.
///
/// # Errors
///
/// - [`Bn254Error::InvalidInputLength`] if `input.len() != 128`.
/// - [`Bn254Error::InvalidFieldElement`] if any coordinate is ≥ p.
/// - [`Bn254Error::NotOnCurve`] if either summand is not on the curve.
pub fn bn254_add(input: &[u8]) -> Result<[u8; G1_BYTES], Bn254Error> {
    if input.len() != 2 * G1_BYTES {
        return Err(Bn254Error::InvalidInputLength {
            expected: 2 * G1_BYTES,
            actual: input.len(),
        });
    }
    let a = decode_g1(&input[..G1_BYTES])?;
    let b = decode_g1(&input[G1_BYTES..])?;
    let sum = (a.into_group() + b.into_group()).into_affine();
    Ok(encode_g1(&sum))
}

/// G1 scalar multiplication (Ethereum ECMUL `0x07`).
///
/// # Input
///
/// `96` bytes: `g1_point || scalar_be`. The scalar is reduced mod `r`
/// before multiplication — matching EIP-196 semantics. Non-reduced input
/// does **not** error.
///
/// # Output
///
/// `64` bytes: `scalar · point`.
///
/// # Errors
///
/// - [`Bn254Error::InvalidInputLength`] if `input.len() != 96`.
/// - [`Bn254Error::InvalidFieldElement`] if a point coordinate is ≥ p.
/// - [`Bn254Error::NotOnCurve`] if the input point is not on the curve.
pub fn bn254_scalar_mul(input: &[u8]) -> Result<[u8; G1_BYTES], Bn254Error> {
    if input.len() != G1_BYTES + FR_BYTES {
        return Err(Bn254Error::InvalidInputLength {
            expected: G1_BYTES + FR_BYTES,
            actual: input.len(),
        });
    }
    let p = decode_g1(&input[..G1_BYTES])?;
    let s = decode_fr_reduced(&input[G1_BYTES..]);
    let product = (p.into_group() * s).into_affine();
    Ok(encode_g1(&product))
}

/// Pairing equality check (Ethereum ECPAIRING `0x08`).
///
/// Returns `true` iff `Π_i e(G1_i, G2_i) = 1` in the target group `Gt`.
///
/// # Input
///
/// `192 · n` bytes, each 192-byte chunk being one `(g1, g2)` pair:
///
/// ```text
///   [0..64)   G1    (x || y)
///   [64..192) G2    (x.c1 || x.c0 || y.c1 || y.c0)
/// ```
///
/// Empty input (`n == 0`) returns `Ok(true)` — this matches EIP-197 and is
/// relied on by some circuit tooling to short-circuit vacuous checks.
///
/// # Errors
///
/// - [`Bn254Error::InvalidPairingInputLength`] if `input.len() % 192 != 0`.
/// - [`Bn254Error::InvalidFieldElement`] / [`Bn254Error::NotOnCurve`] /
///   [`Bn254Error::NotInSubgroup`] if any component is malformed.
pub fn bn254_pairing_equality(input: &[u8]) -> Result<bool, Bn254Error> {
    if input.len() % PAIR_BYTES != 0 {
        return Err(Bn254Error::InvalidPairingInputLength(input.len()));
    }
    let n = input.len() / PAIR_BYTES;
    if n == 0 {
        return Ok(true);
    }

    let mut g1s = Vec::with_capacity(n);
    let mut g2s = Vec::with_capacity(n);
    for i in 0..n {
        let off = i * PAIR_BYTES;
        g1s.push(decode_g1(&input[off..off + G1_BYTES])?);
        g2s.push(decode_g2(&input[off + G1_BYTES..off + PAIR_BYTES])?);
    }

    // arkworks represents Gt additively: the multiplicative identity 1_Gt
    // is the additive zero of PairingOutput<Bn254>, so `is_zero()` is the
    // correct predicate for "product equals 1".
    let result = Bn254::multi_pairing(g1s, g2s);
    Ok(result.is_zero())
}

// ── Field-element decoders ────────────────────────────────────────────────

/// Parse a canonical big-endian 32-byte base-field element.
///
/// Rejects values ≥ `p`, which is what lets us guarantee deterministic
/// consensus across implementations that might otherwise reduce silently.
fn decode_fq(bytes: &[u8]) -> Result<Fq, Bn254Error> {
    debug_assert_eq!(bytes.len(), FQ_BYTES);
    // Unpack 32 BE bytes into the 4 little-endian u64 limbs of BigInteger256.
    let mut limbs = [0u64; 4];
    for (i, chunk) in bytes.chunks_exact(8).enumerate() {
        let mut buf = [0u8; 8];
        buf.copy_from_slice(chunk);
        // Most-significant 8 BE bytes go into the top limb (index 3).
        limbs[3 - i] = u64::from_be_bytes(buf);
    }
    let bi = ark_ff::BigInt::<4>::new(limbs);
    // from_bigint returns None iff bi >= p — exactly the rejection we want.
    Fq::from_bigint(bi).ok_or(Bn254Error::InvalidFieldElement)
}

/// Parse a 32-byte scalar, reducing mod `r` silently (matches EIP-196).
fn decode_fr_reduced(bytes: &[u8]) -> Fr {
    debug_assert_eq!(bytes.len(), FR_BYTES);
    Fr::from_be_bytes_mod_order(bytes)
}

// ── Point decoders ────────────────────────────────────────────────────────

/// Parse a 64-byte G1 point. `(0, 0)` is the point at infinity.
fn decode_g1(bytes: &[u8]) -> Result<G1Affine, Bn254Error> {
    debug_assert_eq!(bytes.len(), G1_BYTES);
    if bytes.iter().all(|&b| b == 0) {
        return Ok(G1Affine::zero());
    }
    let x = decode_fq(&bytes[..FQ_BYTES])?;
    let y = decode_fq(&bytes[FQ_BYTES..])?;
    let p = G1Affine::new_unchecked(x, y);
    if !p.is_on_curve() {
        return Err(Bn254Error::NotOnCurve);
    }
    // BN254 G1 has cofactor 1: on-curve implies in-subgroup.
    Ok(p)
}

/// Parse a 128-byte G2 point in EIP-197 coordinate order:
/// `(x.c1, x.c0, y.c1, y.c0)`. `all zeros` is the point at infinity.
fn decode_g2(bytes: &[u8]) -> Result<G2Affine, Bn254Error> {
    debug_assert_eq!(bytes.len(), G2_BYTES);
    if bytes.iter().all(|&b| b == 0) {
        return Ok(G2Affine::zero());
    }
    let x_c1 = decode_fq(&bytes[0..FQ_BYTES])?;
    let x_c0 = decode_fq(&bytes[FQ_BYTES..2 * FQ_BYTES])?;
    let y_c1 = decode_fq(&bytes[2 * FQ_BYTES..3 * FQ_BYTES])?;
    let y_c0 = decode_fq(&bytes[3 * FQ_BYTES..4 * FQ_BYTES])?;
    let x = Fq2::new(x_c0, x_c1);
    let y = Fq2::new(y_c0, y_c1);
    let p = G2Affine::new_unchecked(x, y);
    if !p.is_on_curve() {
        return Err(Bn254Error::NotOnCurve);
    }
    // BN254 G2 has cofactor ≠ 1: explicit prime-order-subgroup check is
    // required for pairing soundness.
    if !p.is_in_correct_subgroup_assuming_on_curve() {
        return Err(Bn254Error::NotInSubgroup);
    }
    Ok(p)
}

// ── Point encoder ─────────────────────────────────────────────────────────

fn encode_g1(p: &G1Affine) -> [u8; G1_BYTES] {
    let mut out = [0u8; G1_BYTES];
    if p.is_zero() {
        return out; // (0, 0) = point at infinity
    }
    encode_fq(&p.x, &mut out[..FQ_BYTES]);
    encode_fq(&p.y, &mut out[FQ_BYTES..]);
    out
}

fn encode_fq(fq: &Fq, dst: &mut [u8]) {
    debug_assert_eq!(dst.len(), FQ_BYTES);
    // into_bigint() -> LE limbs; to_bytes_be() gives the canonical BE encoding.
    let be = fq.into_bigint().to_bytes_be();
    // to_bytes_be on BigInteger256 emits exactly 32 bytes, but we pad just
    // in case a future arkworks change trims leading zeros.
    let pad = FQ_BYTES.saturating_sub(be.len());
    dst[..pad].fill(0);
    dst[pad..].copy_from_slice(&be);
}

// ── Unit tests ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_infinity_is_identity() {
        // O + O = O
        let input = [0u8; 2 * G1_BYTES];
        let out = bn254_add(&input).unwrap();
        assert_eq!(out, [0u8; G1_BYTES]);
    }

    #[test]
    fn add_generator_and_infinity_is_generator() {
        // G + O = G
        let g = G1Affine::generator();
        let g_bytes = encode_g1(&g);
        let mut input = [0u8; 2 * G1_BYTES];
        input[..G1_BYTES].copy_from_slice(&g_bytes);
        // right half stays zero (infinity)
        let out = bn254_add(&input).unwrap();
        assert_eq!(out, g_bytes);
    }

    #[test]
    fn scalar_mul_by_zero_is_infinity() {
        let g = G1Affine::generator();
        let mut input = [0u8; G1_BYTES + FR_BYTES];
        input[..G1_BYTES].copy_from_slice(&encode_g1(&g));
        // scalar is already zero
        let out = bn254_scalar_mul(&input).unwrap();
        assert_eq!(out, [0u8; G1_BYTES]);
    }

    #[test]
    fn scalar_mul_by_one_is_self() {
        let g = G1Affine::generator();
        let mut input = [0u8; G1_BYTES + FR_BYTES];
        input[..G1_BYTES].copy_from_slice(&encode_g1(&g));
        input[G1_BYTES + FR_BYTES - 1] = 1; // s = 1 (big-endian)
        let out = bn254_scalar_mul(&input).unwrap();
        assert_eq!(out, encode_g1(&g));
    }

    #[test]
    fn pairing_empty_input_is_true() {
        assert!(bn254_pairing_equality(&[]).unwrap());
    }

    #[test]
    fn pairing_single_e_g_g_is_not_one() {
        // e(G1, G2) is a non-trivial element of Gt, so the equality check
        // should return false.
        let g1 = G1Affine::generator();
        let g2 = G2Affine::generator();
        let mut input = [0u8; PAIR_BYTES];
        input[..G1_BYTES].copy_from_slice(&encode_g1(&g1));
        input[G1_BYTES..].copy_from_slice(&encode_g2(&g2));
        assert!(!bn254_pairing_equality(&input).unwrap());
    }

    #[test]
    fn pairing_bilinearity_e_a_g1_b_g2_eq_e_g1_ab_g2() {
        // e(a·G1, b·G2) * e(-a·b·G1, G2) = 1
        // Equivalent 2-pair input should pass pairing_equality.
        let a = Fr::from(3u64);
        let b = Fr::from(5u64);
        let ab = a * b;

        let g1 = G1Affine::generator();
        let g2 = G2Affine::generator();

        let p1 = (g1.into_group() * a).into_affine();
        let q1 = (g2.into_group() * b).into_affine();

        let p2 = (g1.into_group() * (-ab)).into_affine();
        let q2 = g2;

        let mut input = [0u8; 2 * PAIR_BYTES];
        input[..G1_BYTES].copy_from_slice(&encode_g1(&p1));
        input[G1_BYTES..PAIR_BYTES].copy_from_slice(&encode_g2(&q1));
        input[PAIR_BYTES..PAIR_BYTES + G1_BYTES].copy_from_slice(&encode_g1(&p2));
        input[PAIR_BYTES + G1_BYTES..].copy_from_slice(&encode_g2(&q2));

        assert!(bn254_pairing_equality(&input).unwrap());
    }

    #[test]
    fn add_rejects_wrong_length() {
        let err = bn254_add(&[0u8; 127]).unwrap_err();
        assert!(matches!(
            err,
            Bn254Error::InvalidInputLength {
                expected: 128,
                actual: 127
            }
        ));
    }

    #[test]
    fn scalar_mul_rejects_wrong_length() {
        let err = bn254_scalar_mul(&[0u8; 95]).unwrap_err();
        assert!(matches!(
            err,
            Bn254Error::InvalidInputLength {
                expected: 96,
                actual: 95
            }
        ));
    }

    #[test]
    fn pairing_rejects_non_multiple_of_192() {
        let err = bn254_pairing_equality(&[0u8; 191]).unwrap_err();
        assert!(matches!(err, Bn254Error::InvalidPairingInputLength(191)));
    }

    #[test]
    fn add_rejects_point_not_on_curve() {
        // y² = x³ + 3 is the BN254 curve. (1, 1) -> 1 != 4, not on curve.
        let mut input = [0u8; 2 * G1_BYTES];
        input[FQ_BYTES - 1] = 1; // a.x = 1
        input[2 * FQ_BYTES - 1] = 1; // a.y = 1
        let err = bn254_add(&input).unwrap_err();
        assert!(matches!(err, Bn254Error::NotOnCurve));
    }

    // ── Helper: encode a G2 point for test inputs. Not part of the public API
    //    because the VM only ever decodes G2 (the circuit emits G1 outputs).
    fn encode_g2(p: &G2Affine) -> [u8; G2_BYTES] {
        let mut out = [0u8; G2_BYTES];
        if p.is_zero() {
            return out;
        }
        encode_fq(&p.x.c1, &mut out[0..FQ_BYTES]);
        encode_fq(&p.x.c0, &mut out[FQ_BYTES..2 * FQ_BYTES]);
        encode_fq(&p.y.c1, &mut out[2 * FQ_BYTES..3 * FQ_BYTES]);
        encode_fq(&p.y.c0, &mut out[3 * FQ_BYTES..]);
        out
    }
}
