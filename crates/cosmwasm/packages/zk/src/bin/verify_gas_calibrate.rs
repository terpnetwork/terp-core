//! One-shot ZK verify gas calibration harness.
//!
//! Measures wall-clock host verify (and related) work on committed fixtures,
//! models CosmWasm gas as µs × GAS_PER_US with a resource vector, and prints
//! recommended `LinearGasCost` weights with safety margins.
//!
//! ## Resource model (aligned with AIR/STARK fee practice)
//!
//! | Resource | Metered as | Why |
//! |----------|------------|-----|
//! | Fixed verify overhead | `base` | Pairing/IPA setup, deserial, always-on work |
//! | Proof size | `ceil(proof_len/1024)` units | Trace/FRI-ish growth proxy for Halo2; cheap for Groth16 |
//! | Public inputs | `ceil(instances_len/32)` units | Constraint evaluation / gamma_abc work |
//!
//! Static bound for UX: `estimate_gas(proof_len, instances_len)` before execute.
//! Dynamic charge: same formula at runtime on actual region lengths (reverts still pay).
//!
//! ```text
//! cargo run -p zk-cosmwasm --features bn254 --bin verify_gas_calibrate --release
//! ```

use std::path::PathBuf;
use std::time::Instant;

use zk_cosmwasm::{AnyInstance, AnyVerifyingKey, Proof};

/// CosmWasm host crypto unit: 10^12 gas/s ⇒ 1 µs = 1e6 gas.
const GAS_PER_US: f64 = 1_000_000.0;

/// DoS / measurement noise safety margin (20–50% typical in L2 designs).
const SAFETY_MARGIN: f64 = 1.35;

/// Minimum base even if a micro-circuit is sub-ms (liveness floor).
const MIN_BASE_US: f64 = 2_000.0; // 2 ms

struct Workload {
    name: &'static str,
    curve: &'static str,
    proof: Vec<u8>,
    instances: Vec<u8>,
    /// Full circuit blob (footer + body) for VK load.
    circuit: Vec<u8>,
}

#[derive(Clone, Debug)]
struct ResourceVec {
    proof_len: usize,
    instances_len: usize,
    circuit_len: usize,
}

impl ResourceVec {
    fn proof_kib(&self) -> u64 {
        (self.proof_len as u64).div_ceil(1024).max(1)
    }
    fn pi_limbs(&self) -> u64 {
        (self.instances_len as u64).div_ceil(32)
    }
    /// Dynamic unit count used by production meter (imports.rs).
    fn units(&self) -> u64 {
        1u64.saturating_add(self.proof_kib())
            .saturating_add(self.pi_limbs())
    }
}

#[derive(Debug)]
struct Timed {
    name: String,
    resources: ResourceVec,
    median_us: f64,
    p95_us: f64,
    mean_us: f64,
    iters: usize,
    verify_ok: bool,
}

fn testdata() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

fn load_square() -> Option<Workload> {
    let td = testdata();
    let circuit = std::fs::read(td.join("square_vk.bin")).ok()?;
    let proof = std::fs::read(td.join("square_proof.bin")).ok()?;
    let instances = std::fs::read(td.join("square_public.bin")).ok()?;
    Some(Workload {
        name: "square_groth16_bn254",
        curve: "bn254_groth16",
        proof,
        instances,
        circuit,
    })
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((p / 100.0) * (sorted.len() as f64 - 1.0)).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

fn time_verify(w: &Workload, warmup: usize, iters: usize) -> Timed {
    let resources = ResourceVec {
        proof_len: w.proof.len(),
        instances_len: w.instances.len(),
        circuit_len: w.circuit.len(),
    };

    let vk = AnyVerifyingKey::try_from(w.circuit.as_slice()).expect("load circuit blob");
    let curve_id = vk.curve_id() as u32;
    let inst = AnyInstance::try_from_bytes(curve_id, &w.instances).expect("decode instances");
    let proof = Proof::new(w.proof.clone());

    // Warmup (JIT / caches)
    let mut ok = true;
    for _ in 0..warmup {
        if vk.verify(&proof, std::slice::from_ref(&inst)).is_err() {
            ok = false;
        }
    }

    let mut samples = Vec::with_capacity(iters);
    for _ in 0..iters {
        let t0 = Instant::now();
        let r = vk.verify(&proof, std::slice::from_ref(&inst));
        let us = t0.elapsed().as_secs_f64() * 1_000_000.0;
        samples.push(us);
        if r.is_err() {
            ok = false;
        }
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mean = samples.iter().sum::<f64>() / samples.len() as f64;

    Timed {
        name: w.name.to_string(),
        resources,
        median_us: percentile(&samples, 50.0),
        p95_us: percentile(&samples, 95.0),
        mean_us: mean,
        iters,
        verify_ok: ok,
    }
}

/// Time circuit deserial only (large Halo2-style VK load proxy).
fn time_circuit_load(name: &str, blob: &[u8], warmup: usize, iters: usize) -> Timed {
    let resources = ResourceVec {
        proof_len: 0,
        instances_len: 0,
        circuit_len: blob.len(),
    };
    for _ in 0..warmup {
        let _ = AnyVerifyingKey::try_from(blob);
    }
    let mut samples = Vec::with_capacity(iters);
    let mut ok = true;
    for _ in 0..iters {
        let t0 = Instant::now();
        let r = AnyVerifyingKey::try_from(blob);
        let us = t0.elapsed().as_secs_f64() * 1_000_000.0;
        samples.push(us);
        if r.is_err() {
            ok = false;
        }
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mean = samples.iter().sum::<f64>() / samples.len() as f64;
    Timed {
        name: name.to_string(),
        resources,
        median_us: percentile(&samples, 50.0),
        p95_us: percentile(&samples, 95.0),
        mean_us: mean,
        iters,
        verify_ok: ok,
    }
}

/// Fit production formula: gas = base + per_item * units, with base/per in CosmWasm gas.
/// We require gas_model / (t_us * GAS_PER_US) >= SAFETY_MARGIN on p95 for each workload.
struct Weights {
    base_us: f64,
    per_unit_us: f64,
}

fn recommend_weights(rows: &[&Timed]) -> Weights {
    // Verify rows only set base/per_item. Load-only is reported separately
    // (cold deserial is not charged under verify gas today).
    //
    // Literature floor for proof-size scaling (Halo2 IPA growth proxy when we
    // lack large-circuit verify fixtures): ~200 µs / KiB of proof.
    const LITERATURE_US_PER_KIB: f64 = 200.0;

    let mut base_us: f64 = MIN_BASE_US;
    let mut per_unit_us: f64 = LITERATURE_US_PER_KIB;

    for r in rows {
        if r.resources.proof_len == 0 {
            continue;
        }
        let units = r.resources.units() as f64;
        let need = r.p95_us * SAFETY_MARGIN;
        // Prefer putting fixed work into base for small circuits.
        base_us = base_us.max(need * 0.85);
        let residual = (need - base_us).max(0.0);
        if units > 1.0 {
            per_unit_us = per_unit_us.max(residual / units);
        }
        // Require model ≥ need × 1.2 so post-margin headroom stays ≥20%.
        let covered = base_us + per_unit_us * units;
        let target = need * 1.2;
        if covered < target {
            base_us += target - covered;
        }
    }
    // Never go below literature Halo2 size scale (DoS when attackers post huge proofs).
    per_unit_us = per_unit_us.max(LITERATURE_US_PER_KIB);
    Weights {
        base_us,
        per_unit_us,
    }
}

fn gas_for(w: &Weights, units: u64) -> f64 {
    (w.base_us + w.per_unit_us * units as f64) * GAS_PER_US
}

fn main() {
    let warmup = std::env::var("ZK_GAS_WARMUP")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(20usize);
    let iters = std::env::var("ZK_GAS_ITERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(100usize);

    println!("# ZK verify gas calibration");
    println!();
    println!("host: {}", std::env::consts::ARCH);
    println!("GAS_PER_US = {GAS_PER_US}");
    println!("SAFETY_MARGIN = {SAFETY_MARGIN}");
    println!("warmup = {warmup}, iters = {iters}");
    println!();

    let mut timed: Vec<Timed> = Vec::new();

    if let Some(w) = load_square() {
        println!("## Workload `{}` (curve={})", w.name, w.curve);
        println!(
            "- proof_len={} instances_len={} circuit_len={}",
            w.proof.len(),
            w.instances.len(),
            w.circuit.len()
        );
        let t = time_verify(&w, warmup, iters);
        println!(
            "- verify median={:.1} µs  p95={:.1} µs  mean={:.1} µs  ok={}",
            t.median_us, t.p95_us, t.mean_us, t.verify_ok
        );
        println!(
            "- resources: proof_kib={} pi_limbs={} units={}",
            t.resources.proof_kib(),
            t.resources.pi_limbs(),
            t.resources.units()
        );
        timed.push(t);
    } else {
        eprintln!("WARN: square fixtures missing under packages/zk/testdata/");
    }

    // Large Halo2-style deserial (norick from sibling zk-wasmvm testdata if present)
    let norick_paths = [
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../zk-wasmvm/testdata/norick_vk.bin"),
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../zk-wasmvm/testdata/norick_vk.bin"),
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata/norick_vk.bin"),
    ];
    for p in &norick_paths {
        if let Ok(blob) = std::fs::read(p) {
            println!();
            println!(
                "## Workload `norick_vk_load` (Halo2 deserial proxy, {} B)",
                blob.len()
            );
            let t = time_circuit_load("norick_vk_load", &blob, warmup.min(5), iters.min(40));
            println!(
                "- load median={:.1} µs  p95={:.1} µs  mean={:.1} µs  ok={}",
                t.median_us, t.p95_us, t.mean_us, t.verify_ok
            );
            timed.push(t);
            break;
        }
    }

    let refs: Vec<&Timed> = timed.iter().collect();
    let w = recommend_weights(&refs);

    println!();
    println!("## Recommended weights (from this host)");
    println!();
    println!("| Parameter | µs | CosmWasm gas |");
    println!("|-----------|---:|-------------:|");
    println!(
        "| `base` | {:.1} | {:.3e} |",
        w.base_us,
        w.base_us * GAS_PER_US
    );
    println!(
        "| `per_item` (per unit) | {:.1} | {:.3e} |",
        w.per_unit_us,
        w.per_unit_us * GAS_PER_US
    );
    println!();
    println!("units = 1 + ceil(proof_len/1024) + ceil(instances_len/32)");
    println!("gas   = base + per_item * units");
    println!();
    println!("### Coverage vs p95 × safety");
    println!();
    println!("| workload | units | p95_us | need_us (×margin) | model_us | ratio |");
    println!("|----------|------:|-------:|------------------:|---------:|------:|");
    for r in &timed {
        if r.resources.proof_len == 0 {
            continue;
        }
        let units = r.resources.units();
        let need = r.p95_us * SAFETY_MARGIN;
        let model = w.base_us + w.per_unit_us * units as f64;
        let ratio = model / need.max(1.0);
        println!(
            "| {} | {} | {:.1} | {:.1} | {:.1} | {:.2} |",
            r.name, units, r.p95_us, need, model, ratio
        );
    }

    println!();
    println!("### Suggested Rust snippet");
    println!();
    let base_gas = (w.base_us * GAS_PER_US).round() as u64;
    let per_gas = (w.per_unit_us * GAS_PER_US).round() as u64;
    // Express as multiples of GAS_PER_US for readability in environment.rs
    let base_mult = (w.base_us).round() as u64;
    let per_mult = (w.per_unit_us).round() as u64;
    println!("```rust");
    println!("// Calibrated by: cargo run -p zk-cosmwasm --features bn254 --bin verify_gas_calibrate --release");
    println!("halo2_proof_instance_verify_cost: LinearGasCost {{");
    println!("    base: {base_mult} * GAS_PER_US,     // ~{base_mult} µs  ({base_gas} gas)");
    println!("    per_item: {per_mult} * GAS_PER_US,  // ~{per_mult} µs / unit");
    println!("}},");
    println!("```");

    // Machine-readable line for CI parsers
    println!();
    println!(
        "CALIBRATION_JSON={{\"base_us\":{:.3},\"per_unit_us\":{:.3},\"safety\":{},\"gas_per_us\":{}}}",
        w.base_us, w.per_unit_us, SAFETY_MARGIN, GAS_PER_US as u64
    );
}
