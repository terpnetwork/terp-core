// Independent BLAKE3 compression benchmark for Binius64.
//
// Proves N INDEPENDENT BLAKE3 compression-function evaluations — one
// `blake3_compress(cv_i, block_i, counter_i, block_len_i, flags_i)` per i — in
// one circuit. This is the analog of Flock's `cargo bench --bench blake3_proof`
// (which proves N independent BLAKE3 compressions), and the BLAKE3 counterpart
// of this repo's keccak_permutations.rs / sha256_compressions.rs.
//
// Each compression is its own connected component of the gate graph (they share
// only constant wires), so witness generation parallelizes under the
// parallel_witness_gen patch — same as the keccak/sha256 examples.
//
// Config via env vars:
//   N_COMPRESSIONS  number of independent BLAKE3 compressions (default 4096)
//   LOG_INV_RATE    FRI log inverse rate (default 1)
use std::alloc::System;
use std::array;
use std::time::Instant;

use binius_circuits::blake3::blake3_compress;
use binius_core::word::Word;
use binius_frontend::{CircuitBuilder, Wire, WitnessFiller};
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

// splitmix64 — tiny dependency-free RNG so random inputs don't pin a rand version.
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

// One compression's input wires. The blake3_compress gadget masks the inputs
// internally (cf. Blake3CompressExample), so arbitrary 64-bit values are valid.
struct Comp {
	cv: [Wire; 8],
	block: [Wire; 16],
	counter: Wire,
	block_len: Wire,
	flags: Wire,
}
impl Comp {
	fn populate(&self, w: &mut WitnessFiller, rng: &mut Rng) {
		for &x in self.cv.iter() {
			w[x] = Word(rng.next());
		}
		for &x in self.block.iter() {
			w[x] = Word(rng.next());
		}
		w[self.counter] = Word(rng.next());
		w[self.block_len] = Word(rng.next());
		w[self.flags] = Word(rng.next());
	}
}

fn main() {
	let n = env_usize("N_COMPRESSIONS", 4096);
	let log_inv_rate = env_usize("LOG_INV_RATE", 1);
	println!("Proving {n} independent BLAKE3 compressions (log_inv_rate={log_inv_rate})");

	// Build the circuit: N independent compressions, each its own subcircuit.
	let builder = CircuitBuilder::new();
	let comps: Vec<Comp> = (0..n)
		.map(|i| {
			let sub = builder.subcircuit(format!("blake3[{i}]"));
			let cv: [Wire; 8] = array::from_fn(|_| sub.add_witness());
			let block: [Wire; 16] = array::from_fn(|_| sub.add_witness());
			let counter = sub.add_witness();
			let block_len = sub.add_witness();
			let flags = sub.add_witness();
			let _out = blake3_compress(&sub, cv, block, counter, block_len, flags);
			Comp { cv, block, counter, block_len, flags }
		})
		.collect();
	let circuit = builder.build();
	let cs = circuit.constraint_system().clone();

	let (verifier, prover) =
		binius_examples::setup::<StdHashSuite>(cs, log_inv_rate, None).unwrap();

	// Witness: fresh random inputs per compression.
	let fill = |seed: u64| {
		let mut rng = Rng(seed);
		let mut filler = circuit.new_witness_filler();
		for c in &comps {
			c.populate(&mut filler, &mut rng);
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

	// Best-of-3 timed witness generation (populate_wire_witness only — parallelized
	// across independent gate-graph components). Inputs filled first (untimed).
	let mut best_wit = f64::INFINITY;
	for run in 0..3 {
		let mut rng = Rng(0xD00D ^ (run as u64));
		let mut filler = circuit.new_witness_filler();
		for c in &comps {
			c.populate(&mut filler, &mut rng);
		}
		let t = Instant::now();
		circuit.populate_wire_witness(&mut filler).unwrap();
		best_wit = best_wit.min(t.elapsed().as_secs_f64());
	}
	println!(
		"      witness gen: {:.4} s  ({:.0} blake3/s)",
		best_wit,
		n as f64 / best_wit
	);

	// Best-of-3 timed end-to-end proofs: witness generation + proving, folded
	// together to match Flock's `prove_fast` (which includes witness gen). The
	// random input assignment is done untimed first.
	let mut best = f64::INFINITY;
	for run in 0..3 {
		let mut rng = Rng(0xBEEF ^ (run as u64));
		let mut filler = circuit.new_witness_filler();
		for c in &comps {
			c.populate(&mut filler, &mut rng);
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
		"      throughput: {:.0} blake3/s  (witness gen + proof; {} compressions / {:.3} s)",
		throughput, n, best
	);
	println!("      verify: {:.3} s", verify_s);
	println!("      proof size: {} bytes ({:.2} KiB)", proof_size, proof_size as f64 / 1024.0);
	println!("      peak memory: {:.2} MB", peak_bytes as f64 / (1024.0 * 1024.0));
}
