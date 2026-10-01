// Independent SHA-256 compression benchmark for Binius64.
//
// Proves N INDEPENDENT SHA-256 compression-function evaluations — `compress(IV, m_i)`
// for a fresh random 64-byte block m_i — in one circuit. This is the analog of
// Flock's `cargo bench --bench sha2_proof` (which proves N independent SHA-256
// compressions), and the SHA-256 counterpart of this repo's keccak_permutations.rs.
//
// Each compression is its own connected component of the gate graph (they share
// only the constant IV wires), so witness generation parallelizes under the
// parallel_witness_gen patch — same as the keccak permutation example.
//
// Config via env vars:
//   N_COMPRESSIONS  number of independent SHA-256 compressions (default 4096)
//   LOG_INV_RATE    FRI log inverse rate (default 1)
use std::alloc::System;
use std::array;
use std::time::Instant;

use binius_circuits::sha256::{Compress, State};
use binius_frontend::{CircuitBuilder, Wire};
use binius_hash::StdHashSuite;
use binius_verifier::config::StdChallenger;
use binius_verifier::transcript::{ProverTranscript, VerifierTranscript};
use peakmem_alloc::*;

// Track peak heap usage (high-water mark of outstanding bytes).
#[global_allocator]
static ALLOC: PeakMemAlloc<System> = PeakMemAlloc::new(System);

fn env_usize(key: &str, default: usize) -> usize {
	std::env::var(key).ok().and_then(|s| s.parse().ok()).unwrap_or(default)
}

// splitmix64 — tiny dependency-free RNG so random blocks don't pin a rand version.
struct Rng(u64);
impl Rng {
	fn next(&mut self) -> u64 {
		self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
		let mut z = self.0;
		z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
		z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
		z ^ (z >> 31)
	}
	fn next_block(&mut self) -> [u8; 64] {
		let mut b = [0u8; 64];
		for chunk in b.chunks_mut(8) {
			chunk.copy_from_slice(&self.next().to_le_bytes());
		}
		b
	}
}

fn main() {
	let n = env_usize("N_COMPRESSIONS", 4096);
	let log_inv_rate = env_usize("LOG_INV_RATE", 1);
	println!("Proving {n} independent SHA-256 compressions (log_inv_rate={log_inv_rate})");

	// Build the circuit: N independent compressions, each compress(IV, m_i).
	let builder = CircuitBuilder::new();
	let comps: Vec<Compress> = (0..n)
		.map(|i| {
			let sub = builder.subcircuit(format!("sha256[{i}]"));
			let state = State::iv(&sub);
			let m: [Wire; 16] = array::from_fn(|_| sub.add_witness());
			Compress::new(&sub, state, m)
		})
		.collect();
	let circuit = builder.build();
	let cs = circuit.constraint_system().clone();

	let (verifier, prover) =
		binius_examples::setup::<StdHashSuite>(cs, log_inv_rate, None).unwrap();

	// Witness: a fresh random 64-byte message block per compression.
	let fill = |seed: u64| {
		let mut rng = Rng(seed);
		let mut filler = circuit.new_witness_filler();
		for c in &comps {
			c.populate_m(&mut filler, rng.next_block());
		}
		circuit.populate_wire_witness(&mut filler).unwrap();
		filler.into_value_vec()
	};

	// Warm up; measure peak heap over witness-gen + prove, capture one proof for
	// size, and time the verify.
	ALLOC.reset_peak_memory();
	let witness = fill(0xC0FFEE);
	let mut transcript = ProverTranscript::new(StdChallenger::default());
	prover.prove(witness.clone(), &mut transcript).unwrap();
	let peak_bytes = ALLOC.get_peak_memory();
	let proof_bytes = transcript.finalize();
	let proof_size = proof_bytes.len();

	let mut vt = VerifierTranscript::new(StdChallenger::default(), proof_bytes.clone());
	let t_v = Instant::now();
	verifier.verify(witness.public(), &mut vt).unwrap();
	vt.finalize().unwrap();
	let verify_s = t_v.elapsed().as_secs_f64();

	// Best-of-3 timed witness generation (populate_wire_witness only — the step
	// parallelized across independent gate-graph components). Blocks are filled
	// first (untimed) so we isolate the evaluator.
	let mut best_wit = f64::INFINITY;
	for run in 0..3 {
		let mut rng = Rng(0xD00D ^ (run as u64));
		let mut filler = circuit.new_witness_filler();
		for c in &comps {
			c.populate_m(&mut filler, rng.next_block());
		}
		let t = Instant::now();
		circuit.populate_wire_witness(&mut filler).unwrap();
		best_wit = best_wit.min(t.elapsed().as_secs_f64());
	}
	println!(
		"      witness gen: {:.4} s  ({:.0} sha256/s)",
		best_wit,
		n as f64 / best_wit
	);

	// Best-of-3 timed end-to-end proofs: witness generation + proving, folded
	// together to match Flock's `prove_fast` (which includes witness gen). The
	// random block assignment is done untimed first.
	let mut best = f64::INFINITY;
	for run in 0..3 {
		let mut rng = Rng(0xBEEF ^ (run as u64));
		let mut filler = circuit.new_witness_filler();
		for c in &comps {
			c.populate_m(&mut filler, rng.next_block());
		}
		let t = Instant::now();
		circuit.populate_wire_witness(&mut filler).unwrap();
		let w = filler.into_value_vec();
		let mut tr = ProverTranscript::new(StdChallenger::default());
		prover.prove(w, &mut tr).unwrap();
		let _ = tr.finalize();
		best = best.min(t.elapsed().as_secs_f64());
	}

	let throughput = n as f64 / best;
	println!("      prove time: {:.3} s  (incl. witness gen)", best);
	println!(
		"      throughput: {:.0} sha256/s  (witness gen + proof; {} compressions / {:.3} s)",
		throughput, n, best
	);
	println!("      verify: {:.3} s", verify_s);
	println!("      proof size: {} bytes ({:.2} KiB)", proof_size, proof_size as f64 / 1024.0);
	println!("      peak memory: {:.2} MB", peak_bytes as f64 / (1024.0 * 1024.0));
}
