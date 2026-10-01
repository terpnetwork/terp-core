// Independent Keccak-f[1600] permutation benchmark for Binius64.
//
// Unlike the built-in `keccak` example (which proves a single Keccak-256 sponge
// hash of a message — sequentially-dependent permutations), this proves N
// INDEPENDENT keccak-f permutations in one circuit, with no sponge/XOR/padding.
// Directly comparable to Flock's `cargo bench --bench keccak3_proof` (3-wide) and
// plonky3's `keccak-f-permutations` objective.
//
// Config via env vars:
//   N_PERMUTATIONS  number of independent keccak-f permutations (default 4096)
//   LOG_INV_RATE    FRI log inverse rate (default 1)
use std::alloc::System;
use std::array;
use std::time::Instant;

use binius_circuits::keccak::permutation::{Permutation, State};
use binius_frontend::CircuitBuilder;
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

// splitmix64 — tiny dependency-free RNG so random states don't pin a rand version.
struct Rng(u64);
impl Rng {
	fn next(&mut self) -> u64 {
		self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
		let mut z = self.0;
		z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
		z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
		z ^ (z >> 31)
	}
}

fn main() {
	let n = env_usize("N_PERMUTATIONS", 4096);
	let log_inv_rate = env_usize("LOG_INV_RATE", 1);
	println!("Proving {n} independent Keccak-f[1600] permutations (log_inv_rate={log_inv_rate})");

	// Build the circuit: N independent permutations, each over its own input state.
	let builder = CircuitBuilder::new();
	let perms: Vec<Permutation> = (0..n)
		.map(|_| {
			let words: [_; 25] = array::from_fn(|_| builder.add_witness());
			Permutation::new(&builder, State { words })
		})
		.collect();
	let circuit = builder.build();
	let cs = circuit.constraint_system().clone();

	let (verifier, prover) =
		binius_examples::setup::<StdHashSuite>(cs, log_inv_rate, None).unwrap();

	// Witness: a fresh random input state per permutation.
	let fill = |seed: u64| {
		let mut rng = Rng(seed);
		let mut filler = circuit.new_witness_filler();
		for p in &perms {
			let state: [u64; 25] = array::from_fn(|_| rng.next());
			p.populate_state(&mut filler, state);
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
	// parallelized across independent gate-graph components). States are filled
	// first (untimed) so we isolate the evaluator.
	let mut best_wit = f64::INFINITY;
	for run in 0..3 {
		let mut rng = Rng(0xD00D ^ (run as u64));
		let mut filler = circuit.new_witness_filler();
		for p in &perms {
			let state: [u64; 25] = array::from_fn(|_| rng.next());
			p.populate_state(&mut filler, state);
		}
		let t = Instant::now();
		circuit.populate_wire_witness(&mut filler).unwrap();
		best_wit = best_wit.min(t.elapsed().as_secs_f64());
	}
	println!(
		"      witness gen: {:.4} s  ({:.0} keccak/s)",
		best_wit,
		n as f64 / best_wit
	);

	// Best-of-3 timed end-to-end proofs: witness generation (populate_wire_witness)
	// + proving. We fold witness gen into the headline time to match Flock's
	// `prove_fast`, which includes witness generation. The random input states are
	// assigned first (untimed), as Flock doesn't time input generation either; the
	// `witness gen:` line above still reports the witness step in isolation.
	let mut best = f64::INFINITY;
	for run in 0..3 {
		let mut rng = Rng(0xBEEF ^ (run as u64));
		let mut filler = circuit.new_witness_filler();
		for p in &perms {
			let state: [u64; 25] = array::from_fn(|_| rng.next());
			p.populate_state(&mut filler, state);
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
	println!("      throughput: {:.0} keccak/s  (witness gen + proof; {} permutations / {:.3} s)", throughput, n, best);
	println!("      verify: {:.3} s", verify_s);
	println!("      proof size: {} bytes ({:.2} KiB)", proof_size, proof_size as f64 / 1024.0);
	println!("      peak memory: {:.2} MB", peak_bytes as f64 / (1024.0 * 1024.0));
}
