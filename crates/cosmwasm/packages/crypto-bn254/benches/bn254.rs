//! Microbenchmarks for the BN254 primitives.
//!
//! Run with:
//!
//! ```bash
//! cargo bench -p cosmwasm-crypto-bn254
//! ```
//!
//! The numbers feed two things:
//!
//! 1. The gas-schedule ceiling in `src/gas.rs` (we want the 99th-percentile
//!    runtime to be comfortably under the gas budget divided by the VM's
//!    nanosecond-per-gas rate).
//! 2. The "2× reduction" claim in the Juno governance proposal — we
//!    compare wall-clock for a 3-pair pairing here against the equivalent
//!    pure-Wasm `Groth16::verify_proof` run under the VM, which is
//!    dominated by exactly this operation.

use ark_bn254::{Fr, G1Affine, G2Affine};
use ark_ec::{AffineRepr, CurveGroup};
use ark_ff::{BigInteger, PrimeField};
use criterion::{criterion_group, criterion_main, Criterion};

use cosmwasm_crypto_bn254::{
    bn254_add, bn254_pairing_equality, bn254_scalar_mul, FQ_BYTES, FR_BYTES, G1_BYTES, G2_BYTES,
    PAIR_BYTES,
};

// ── local encoders (mirroring tests/vectors.rs) ─────────────────────────────

fn fq_to_be_32(fq: &ark_bn254::Fq) -> [u8; FQ_BYTES] {
    let be = fq.into_bigint().to_bytes_be();
    let mut out = [0u8; FQ_BYTES];
    let pad = FQ_BYTES.saturating_sub(be.len());
    out[pad..].copy_from_slice(&be);
    out
}

fn encode_g1(p: &G1Affine) -> [u8; G1_BYTES] {
    let mut out = [0u8; G1_BYTES];
    if p.is_zero() {
        return out;
    }
    out[..FQ_BYTES].copy_from_slice(&fq_to_be_32(&p.x));
    out[FQ_BYTES..].copy_from_slice(&fq_to_be_32(&p.y));
    out
}

fn encode_g2(p: &G2Affine) -> [u8; G2_BYTES] {
    let mut out = [0u8; G2_BYTES];
    if p.is_zero() {
        return out;
    }
    out[0..FQ_BYTES].copy_from_slice(&fq_to_be_32(&p.x.c1));
    out[FQ_BYTES..2 * FQ_BYTES].copy_from_slice(&fq_to_be_32(&p.x.c0));
    out[2 * FQ_BYTES..3 * FQ_BYTES].copy_from_slice(&fq_to_be_32(&p.y.c1));
    out[3 * FQ_BYTES..].copy_from_slice(&fq_to_be_32(&p.y.c0));
    out
}

// ── benchmarks ─────────────────────────────────────────────────────────────

fn bench_add(c: &mut Criterion) {
    let g = encode_g1(&G1Affine::generator());
    let mut input = [0u8; 2 * G1_BYTES];
    input[..G1_BYTES].copy_from_slice(&g);
    input[G1_BYTES..].copy_from_slice(&g);
    c.bench_function("bn254_add (G + G)", |b| {
        b.iter(|| bn254_add(&input).unwrap())
    });
}

fn bench_scalar_mul(c: &mut Criterion) {
    // Large scalar to exercise the full double-and-add ladder.
    let g = encode_g1(&G1Affine::generator());
    let k = Fr::from(u64::MAX).into_bigint().to_bytes_be();
    let mut input = [0u8; G1_BYTES + FR_BYTES];
    input[..G1_BYTES].copy_from_slice(&g);
    let pad = FR_BYTES - k.len();
    input[G1_BYTES + pad..].copy_from_slice(&k);
    c.bench_function("bn254_scalar_mul (k·G, k=u64::MAX)", |b| {
        b.iter(|| bn254_scalar_mul(&input).unwrap())
    });
}

fn bench_pairing_groth16_shape(c: &mut Criterion) {
    // 3 pairs = typical Groth16 verification shape.
    // We build e(aG1, bG2) · e(cG1, dG2) · e(-(ab+cd)G1, G2) = 1 so the
    // check returns true — mirrors the hot path of a successful proof.
    let a = Fr::from(7u64);
    let b = Fr::from(11u64);
    let c_sc = Fr::from(13u64);
    let d = Fr::from(17u64);
    let close = -(a * b + c_sc * d);

    let g1 = G1Affine::generator();
    let g2 = G2Affine::generator();

    let p1 = (g1.into_group() * a).into_affine();
    let q1 = (g2.into_group() * b).into_affine();
    let p2 = (g1.into_group() * c_sc).into_affine();
    let q2 = (g2.into_group() * d).into_affine();
    let p3 = (g1.into_group() * close).into_affine();
    let q3 = g2;

    let mut input = [0u8; 3 * PAIR_BYTES];
    let slots = [(p1, q1), (p2, q2), (p3, q3)];
    for (i, (g1p, g2p)) in slots.iter().enumerate() {
        let off = i * PAIR_BYTES;
        input[off..off + G1_BYTES].copy_from_slice(&encode_g1(g1p));
        input[off + G1_BYTES..off + PAIR_BYTES].copy_from_slice(&encode_g2(g2p));
    }

    c.bench_function("bn254_pairing_equality (3 pairs, Groth16 shape)", |b_c| {
        b_c.iter(|| {
            let ok = bn254_pairing_equality(&input).unwrap();
            assert!(ok);
        });
    });
}

criterion_group!(
    benches,
    bench_add,
    bench_scalar_mul,
    bench_pairing_groth16_shape
);
criterion_main!(benches);
