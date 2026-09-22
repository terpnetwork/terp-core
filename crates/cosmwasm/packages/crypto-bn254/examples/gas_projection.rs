//! Standalone gas-projection report for the BN254 precompile.
//!
//! Renders a markdown table that the governance proposal can cite when
//! the on-chain devnet measurement is in flight or unavailable. Combines:
//!
//!   1. The gas constants from `gas.rs` (EIP-1108-grounded ceilings).
//!   2. A wall-clock micro-measurement of each primitive on the local
//!      machine, so reviewers can see the schedule has comfortable headroom.
//!   3. The published `uni-7` measurement of the pure-Wasm path
//!      (371,486 SDK gas, tx F6D5774E… on block 12,673,217).
//!
//! Run with:
//!
//!     cargo run --release -p cosmwasm-crypto-bn254 --example gas_projection
//!
//! Output goes to stdout (and to `docs/BN254_BENCHMARK_PROJECTED.md` in
//! the repo if the env var `OUT` is set to the absolute path of that file).
//!
//! This is *not* a substitute for the devnet measurement. It is a
//! reviewer-friendly cross-check: once the devnet measurement lands, the
//! projection here should be within ~5% of it.

use std::env;
use std::fs;
use std::time::Instant;

use ark_bn254::{Fr, G1Affine, G2Affine};
use ark_ec::{AffineRepr, CurveGroup};
use ark_ff::{BigInteger, PrimeField};

use cosmwasm_crypto_bn254::{
    bn254_add, bn254_pairing_equality, bn254_scalar_mul,
    gas::{
        pairing_cost, BN254_ADD_COST, BN254_PAIRING_BASE_COST, BN254_PAIRING_PER_PAIR_COST,
        BN254_SCALAR_MUL_COST,
    },
    FQ_BYTES, FR_BYTES, G1_BYTES, G2_BYTES, PAIR_BYTES,
};

// Cosmos SDK gas multiplier used by `wasmd` for cosmwasm-vm gas → SDK gas.
// Matches `DefaultGasMultiplier = 100`.
const SDK_GAS_MULTIPLIER: u64 = 100;

// Published uni-7 measurement of the pure-Wasm Groth16 verification.
// Source: tx F6D5774EE2073E2DD011399A7E96889BA026ED67C6A510D208FD5C575080F4DA,
// block 12,673,217, contract juno1ydxksvr…lse7ekem (code_id 64).
const MEASURED_PURE_WASM_SDK_GAS: u64 = 371_486;

// ── Primitive-level wall-clock benchmarks ──────────────────────────────────

/// Run `body` `iters` times and return the mean nanoseconds per iteration.
fn bench_ns<F: FnMut()>(iters: u32, mut body: F) -> u64 {
    // Warm the i-cache and any one-shot init in the backend.
    for _ in 0..iters / 16 {
        body();
    }
    let start = Instant::now();
    for _ in 0..iters {
        body();
    }
    let elapsed = start.elapsed().as_nanos() as u64;
    elapsed / u64::from(iters)
}

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

struct Measurements {
    add_ns: u64,
    scalar_mul_ns: u64,
    pairing_3_ns: u64,
}

fn measure() -> Measurements {
    // ── add ─────────────────────────────────────────────────────────────
    let g = encode_g1(&G1Affine::generator());
    let mut add_input = [0u8; 2 * G1_BYTES];
    add_input[..G1_BYTES].copy_from_slice(&g);
    add_input[G1_BYTES..].copy_from_slice(&g);
    let add_ns = bench_ns(20_000, || {
        let _ = bn254_add(&add_input).unwrap();
    });

    // ── scalar_mul ──────────────────────────────────────────────────────
    let k = Fr::from(u64::MAX).into_bigint().to_bytes_be();
    let mut mul_input = [0u8; G1_BYTES + FR_BYTES];
    mul_input[..G1_BYTES].copy_from_slice(&g);
    let pad = FR_BYTES - k.len();
    mul_input[G1_BYTES + pad..].copy_from_slice(&k);
    let scalar_mul_ns = bench_ns(2_000, || {
        let _ = bn254_scalar_mul(&mul_input).unwrap();
    });

    // ── pairing (Groth16-shape, 3 pairs that satisfy the equality) ──────
    let a = Fr::from(7u64);
    let b = Fr::from(11u64);
    let c = Fr::from(13u64);
    let d = Fr::from(17u64);
    let close = -(a * b + c * d);
    let g1 = G1Affine::generator();
    let g2 = G2Affine::generator();
    let p1 = (g1.into_group() * a).into_affine();
    let q1 = (g2.into_group() * b).into_affine();
    let p2 = (g1.into_group() * c).into_affine();
    let q2 = (g2.into_group() * d).into_affine();
    let p3 = (g1.into_group() * close).into_affine();
    let q3 = g2;
    let mut pair_input = vec![0u8; 3 * PAIR_BYTES];
    let slots = [(p1, q1), (p2, q2), (p3, q3)];
    for (i, (g1p, g2p)) in slots.iter().enumerate() {
        let off = i * PAIR_BYTES;
        pair_input[off..off + G1_BYTES].copy_from_slice(&encode_g1(g1p));
        pair_input[off + G1_BYTES..off + PAIR_BYTES].copy_from_slice(&encode_g2(g2p));
    }
    let pairing_3_ns = bench_ns(200, || {
        let ok = bn254_pairing_equality(&pair_input).unwrap();
        assert!(ok);
    });

    Measurements {
        add_ns,
        scalar_mul_ns,
        pairing_3_ns,
    }
}

// ── Gas projection ─────────────────────────────────────────────────────────

/// CPU rate the cosmwasm-vm host expects: ~1 Tera-gas per millisecond
/// (1 ns ≈ 1 wasm gas). This is the conversion `wasmd` operates with for
/// host-side metering on the existing BLS12-381 functions; we mirror it
/// for headroom estimation, not as the dispatch cost (which uses the
/// constants from `gas.rs` directly).
const WASM_GAS_PER_NS: u64 = 1;

fn ns_to_sdk_gas(ns: u64) -> u64 {
    // wasm_gas = ns × WASM_GAS_PER_NS, and SDK gas = wasm_gas / 100.
    // Manual ceil-div keeps us compatible with the crate's MSRV (1.70).
    let wasm = ns * WASM_GAS_PER_NS;
    (wasm + SDK_GAS_MULTIPLIER - 1) / SDK_GAS_MULTIPLIER
}

/// Projected SDK gas for one `verify_proof` call on the precompile path
/// with `n_pub` public inputs. Matches the algebra in
/// `contracts/zk-verifier/src/bn254_backend.rs::precompile`:
///
///   * `n_pub` scalar muls + `n_pub` adds for the `vk_x` lincomb
///   * 1 pairing equality of 4 pairs
///   * a small contract-level overhead (entry, decode, emit events)
fn projected_precompile_sdk_gas(n_pub: usize) -> u64 {
    let lincomb = (BN254_SCALAR_MUL_COST + BN254_ADD_COST) * n_pub as u64;
    let pairing = pairing_cost(4);
    let host_total_wasm = lincomb + pairing;
    let host_total_sdk = host_total_wasm / SDK_GAS_MULTIPLIER;
    // Empirical contract-level overhead measured against the deployed
    // pure-Wasm contract minus the BN254-attributable Wasm metering.
    // 30k SDK gas covers entry, JSON deserialisation, attribute emission,
    // and the dispatch overhead that survives feature-gating.
    let contract_overhead_sdk = 30_000;
    host_total_sdk + contract_overhead_sdk
}

// ── Markdown rendering ────────────────────────────────────────────────────

fn render(m: &Measurements, n_pub: usize) -> String {
    let projected = projected_precompile_sdk_gas(n_pub);
    let measured_pure = MEASURED_PURE_WASM_SDK_GAS;
    let ratio = (measured_pure as f64) / (projected as f64);
    let absolute_saved = measured_pure.saturating_sub(projected);

    let add_proj_sdk = ns_to_sdk_gas(m.add_ns);
    let mul_proj_sdk = ns_to_sdk_gas(m.scalar_mul_ns);
    let pair_proj_sdk = ns_to_sdk_gas(m.pairing_3_ns);

    let add_sched_sdk = BN254_ADD_COST / SDK_GAS_MULTIPLIER;
    let mul_sched_sdk = BN254_SCALAR_MUL_COST / SDK_GAS_MULTIPLIER;
    let pair_sched_sdk = pairing_cost(3) / SDK_GAS_MULTIPLIER;

    let mut s = String::new();
    s.push_str("# BN254 precompile — projected gas (interim)\n\n");
    s.push_str(
        "> Auto-generated by `cargo run --release -p cosmwasm-crypto-bn254 --example gas_projection`. \
        This is the **interim** report cited by the governance proposal while the on-chain \
        devnet measurement is in flight. When `devnet/scripts/benchmark.sh` produces \
        `BN254_BENCHMARK_RESULTS.md`, the headline number there supersedes this projection.\n\n",
    );
    s.push_str(&format!("Generated: {}\n\n", chrono_like_now()));

    s.push_str("## Headline\n\n");
    s.push_str("| Path | SDK gas per `VerifyProof` | Source |\n");
    s.push_str("|---|---:|---|\n");
    s.push_str(&format!(
        "| Pure-Wasm (arkworks) | **{measured_pure}** | measured on `uni-7` (tx `F6D5774E…5080F4DA`, block 12 673 217) |\n"
    ));
    s.push_str(&format!(
        "| **BN254 precompile** | **~{projected}** | projected from `gas.rs` schedule + 30k SDK overhead |\n"
    ));
    s.push_str(&format!(
        "| Reduction factor | **{ratio:.2}×** | absolute saving ≈ {absolute_saved} SDK gas |\n\n"
    ));

    s.push_str("## Per-primitive sanity check (wall-clock vs schedule)\n\n");
    s.push_str(
        "Schedule values are the EIP-1108-grounded ceilings from `gas.rs`. \
        Wall-clock projections use `wasm_gas ≈ ns × 1` and the wasmd default \
        `SDK_gas = wasm_gas / 100` multiplier. The schedule should always be \
        ≥ the wall-clock projection — that's the headroom that lets the gas \
        ceiling absorb future arkworks / hardware variance.\n\n",
    );
    s.push_str(
        "| Primitive | wall-clock (ns) | wall-clock SDK gas | scheduled SDK gas | headroom |\n",
    );
    s.push_str("|---|---:|---:|---:|---:|\n");
    s.push_str(&format!(
        "| `bn254_add` | {add_ns} | ~{add_proj} | {add_sched} | {add_head:.1}× |\n",
        add_ns = m.add_ns,
        add_proj = add_proj_sdk,
        add_sched = add_sched_sdk,
        add_head = (add_sched_sdk as f64) / (add_proj_sdk.max(1) as f64),
    ));
    s.push_str(&format!(
        "| `bn254_scalar_mul` | {mul_ns} | ~{mul_proj} | {mul_sched} | {mul_head:.1}× |\n",
        mul_ns = m.scalar_mul_ns,
        mul_proj = mul_proj_sdk,
        mul_sched = mul_sched_sdk,
        mul_head = (mul_sched_sdk as f64) / (mul_proj_sdk.max(1) as f64),
    ));
    s.push_str(&format!(
        "| `bn254_pairing_equality` (3 pairs) | {pair_ns} | ~{pair_proj} | {pair_sched} | {pair_head:.1}× |\n\n",
        pair_ns = m.pairing_3_ns,
        pair_proj = pair_proj_sdk,
        pair_sched = pair_sched_sdk,
        pair_head = (pair_sched_sdk as f64) / (pair_proj_sdk.max(1) as f64),
    ));

    s.push_str("## Algebra of the projection\n\n");
    s.push_str(&format!(
        "For `n_pub = {n_pub}` public inputs, the precompile path executes:\n\n\
         * `n_pub × bn254_scalar_mul` ({sm_w} wasm gas each) for the `vk_x` lincomb\n\
         * `n_pub × bn254_add` ({add_w} wasm gas each) to fold the lincomb terms\n\
         * one pairing equality over 4 pairs ({base_w} + 4·{per_w} = {pair_total_w} wasm gas)\n\
         * a `~30 000` SDK-gas contract overhead (entry, decode, attribute emission)\n\n",
        sm_w = BN254_SCALAR_MUL_COST,
        add_w = BN254_ADD_COST,
        base_w = BN254_PAIRING_BASE_COST,
        per_w = BN254_PAIRING_PER_PAIR_COST,
        pair_total_w = pairing_cost(4),
    ));
    s.push_str(&format!(
        "Total: ({n_pub}·{sm_w} + {n_pub}·{add_w} + {pair_total_w}) / {mult} + 30 000 = **{projected} SDK gas**.\n\n",
        sm_w = BN254_SCALAR_MUL_COST,
        add_w = BN254_ADD_COST,
        pair_total_w = pairing_cost(4),
        mult = SDK_GAS_MULTIPLIER,
    ));

    s.push_str(
        "## When this number is replaced\n\n\
         When `devnet/scripts/benchmark.sh` succeeds and writes \
         `BN254_BENCHMARK_RESULTS.md`, the **measured** median of \
         N `VerifyProof` calls supersedes the headline above. The two \
         numbers should agree to within ~5%; a wider gap indicates the \
         contract-overhead constant in this file should be re-fit.\n\n\
         A reasonable convergence check is:\n\n\
         * measured precompile gas / measured pure-Wasm gas ≈ projected reduction\n\
         * measured pure-Wasm gas / 371 486 ≈ 1.0 (cross-check vs uni-7)\n\n",
    );

    s
}

// `chrono` is not in the dep set; this keeps the example self-contained.
fn chrono_like_now() -> String {
    use std::time::SystemTime;
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{} (unix epoch seconds)", now.as_secs())
}

// ── Entry ──────────────────────────────────────────────────────────────────

fn main() {
    let n_pub: usize = env::var("N_PUBLIC_INPUTS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(2); // task_type + data_hash, the JunoClaw shape

    let m = measure();
    let md = render(&m, n_pub);

    print!("{md}");

    if let Ok(out) = env::var("OUT") {
        if let Some(parent) = std::path::Path::new(&out).parent() {
            let _ = fs::create_dir_all(parent);
        }
        fs::write(&out, md).expect("write OUT");
        eprintln!("\nwrote {out}");
    }
}
