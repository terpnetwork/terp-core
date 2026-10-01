#!/usr/bin/env bash
# setup.sh — clone han0110/bench-hash-in-snark into this directory if absent.
#
# This is the only checked-in file under bench-hash-in-snark/; everything else
# (the cloned repo) is gitignored. Self-contained: works from a fresh checkout
# where bench-hash-in-snark/ contains nothing but this script.
#
# The upstream repo is a multi-prover hash-in-SNARK benchmark suite (plonky3/,
# binius/, stwo/, expander/, hashcaster/ crates + its own bench.sh and
# render_table.py). After cloning, follow its README.md to run benchmarks.
#
# This script also patches the shared `bench` crate to record + report VERIFIER
# time (the upstream harness only reports prover time). The timing harness lives
# in bench/src/lib.rs (used by every prover via the main! macro), so patching it
# makes hashcaster/plonky3 (and the rest) emit a "verify time:" line.

set -euo pipefail

REPO_URL="https://github.com/han0110/bench-hash-in-snark"
# Pinned commit for reproducibility (the clone strips .git, so without this it
# would track whatever the default branch is at clone time). Its Cargo.lock in
# turn pins the transitive deps (hashcaster, binius, plonky3). Override with
# BHS_REV=<sha-or-ref> to use a different commit.
PIN="${BHS_REV:-1af6fc556202e2c389595ceb3787a3b656db96ca}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# README.md exists at the repo root and marks a completed checkout (the repo has
# no root Cargo.toml — it's a set of per-prover crates).
if [[ -e "$DIR/README.md" ]]; then
	echo "bench-hash-in-snark already present in $DIR, skipping clone."
else
	echo "Cloning $REPO_URL into $DIR ..."
	# Clone into a temp dir first, since DIR is non-empty (it holds this script),
	# then move the contents in.
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	git clone "$REPO_URL" "$TMP/repo"
	git -C "$TMP/repo" checkout --quiet "$PIN"   # pin to a fixed commit
	shopt -s dotglob          # include dotfiles (.cargo, .github, .gitignore, ...)
	mv "$TMP/repo"/* "$DIR"/
	shopt -u dotglob
	# Drop the nested .git so the outer flock-rust repo can track this script
	# (otherwise bench-hash-in-snark/ looks like an embedded git repo). It isn't
	# needed to build or run the benchmarks.
	rm -rf "$DIR/.git"
fi

# Patch the shared bench harness to also time + print the verifier (idempotent).
python3 - "$DIR/bench/src/lib.rs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
if "fn verify_time" in src:
    print("bench/src/lib.rs already records verifier time.")
    sys.exit(0)

old = '''            let num_permutations = 1 << args.log_permutations;
            let (_, time, throughput, proof_size) = match args.hash {
                $(Hash::$variant => $crate::bench::<$snark>(num_permutations, sample_size)),+
            };
            println!(
                "      time: {}\\nthroughput: {}\\nproof size: {}",
                $crate::util::human_time(time),
                $crate::util::human_throughput(throughput),
                $crate::util::human_size(proof_size),
            );'''
new = '''            let num_permutations = 1 << args.log_permutations;
            let (_, time, throughput, proof_size) = match args.hash {
                $(Hash::$variant => $crate::bench::<$snark>(num_permutations, sample_size)),+
            };
            let verify_time = match args.hash {
                $(Hash::$variant => $crate::verify_time::<$snark>(num_permutations)),+
            };
            println!(
                "      time: {}\\nverify time: {}\\nthroughput: {}\\nproof size: {}",
                $crate::util::human_time(time),
                $crate::util::human_time(verify_time),
                $crate::util::human_throughput(throughput),
                $crate::util::human_size(proof_size),
            );'''
assert old in src, "verify-time patch anchor not found in bench/src/lib.rs"
src = src.replace(old, new)
src += '''

/// Measure verifier time for one freshly-generated proof.
/// (Added by flock-rust benchmarks setup.sh.)
pub fn verify_time<H: HashInSnark>(num_permutations: usize) -> Duration {
    let snark = H::new(num_permutations);
    let input = snark.generate_input(StdRng::from_os_rng());
    let proof = snark.prove(input);
    let start = Instant::now();
    snark.verify(&proof).unwrap();
    start.elapsed()
}
'''
open(path, "w").write(src)
print("patched bench/src/lib.rs to record verifier time.")
PY

# Patch the harness to also print the TRUE permutation count (idempotent). The
# bench() tuple's first element is snark.num_permutations() — the actual number
# proven, which differs from the requested 2^log_permutations (e.g. hashcaster
# rounds to 3*2^k = 1.5x). It was discarded as `_`; capture it and print a
# "permutations:" line so the orchestrator reports the exact count instead of
# estimating it as throughput*time.
python3 - "$DIR/bench/src/lib.rs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
if "permutations: {}" in src:
    print("bench/src/lib.rs already prints the true permutation count.")
    sys.exit(0)

old = '''            let (_, time, throughput, proof_size) = match args.hash {
                $(Hash::$variant => $crate::bench::<$snark>(num_permutations, sample_size)),+
            };
            let verify_time = match args.hash {
                $(Hash::$variant => $crate::verify_time::<$snark>(num_permutations)),+
            };
            println!(
                "      time: {}\\nverify time: {}\\nthroughput: {}\\nproof size: {}",
                $crate::util::human_time(time),
                $crate::util::human_time(verify_time),
                $crate::util::human_throughput(throughput),
                $crate::util::human_size(proof_size),
            );'''
new = '''            let (n_perms, time, throughput, proof_size) = match args.hash {
                $(Hash::$variant => $crate::bench::<$snark>(num_permutations, sample_size)),+
            };
            let verify_time = match args.hash {
                $(Hash::$variant => $crate::verify_time::<$snark>(num_permutations)),+
            };
            println!(
                "permutations: {}\\n      time: {}\\nverify time: {}\\nthroughput: {}\\nproof size: {}",
                n_perms,
                $crate::util::human_time(time),
                $crate::util::human_time(verify_time),
                $crate::util::human_throughput(throughput),
                $crate::util::human_size(proof_size),
            );'''
assert old in src, "permutation-count patch anchor not found (run the verify-time patch first)"
src = src.replace(old, new)
open(path, "w").write(src)
print("patched bench/src/lib.rs to print the true permutation count.")
PY

# Best-of-3 instead of mean: upstream bench() reports the MEAN prove time over
# `sample_size` runs (after a 3s warm-up). Take the MIN (best) instead — matching
# how flock/binius64/plonky3 are measured in this repo (warm-up + best-of-N).
# Combined with bench.sh's --sample-size 3 (patched below), hashcaster becomes
# best-of-3. (bench/src/lib.rs is shared by every bhs prover via the main! macro,
# but only hashcaster is enabled here.) Idempotent via the `best_elapsed` grep.
python3 - "$DIR/bench/src/lib.rs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
if "best_elapsed" in src:
    print("bench/src/lib.rs already reports best-of-N (min) prove time.")
    sys.exit(0)
old = '''    let mut total_elapsed = Duration::default();
    let mut total_proof_size = 0;
    for _ in 0..sample_size {
        let (elapsed, proof_size) = routine(&snark, &mut rng);
        total_elapsed += elapsed;
        total_proof_size += proof_size;
    }

    let num_permutations = snark.num_permutations();
    let time = total_elapsed / sample_size as u32;
    let throughput = num_permutations as f64 / time.as_secs_f64();
    let proof_size = total_proof_size as f64 / sample_size as f64;'''
new = '''    let mut best_elapsed = Duration::MAX;
    let mut last_proof_size = 0;
    for _ in 0..sample_size {
        let (elapsed, proof_size) = routine(&snark, &mut rng);
        if elapsed < best_elapsed {
            best_elapsed = elapsed;
        }
        last_proof_size = proof_size;
    }

    let num_permutations = snark.num_permutations();
    let time = best_elapsed;
    let throughput = num_permutations as f64 / time.as_secs_f64();
    let proof_size = last_proof_size as f64;'''
assert old in src, "best-of-N patch anchor not found in bench/src/lib.rs::bench()"
src = src.replace(old, new)
open(path, "w").write(src)
print("patched bench/src/lib.rs to report best-of-N (min) prove time.")
PY

# Single warm-up run (not the upstream 3-second warm-up loop): match how
# flock/binius64/plonky3 are measured here (one warm-up run, then best-of-3).
# Idempotent: skip once the 3.0s loop anchor is gone.
python3 - "$DIR/bench/src/lib.rs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
old = '''fn warm_up<H: HashInSnark>(snark: &H, mut rng: impl RngCore) {
    let start = Instant::now();
    while Instant::now().duration_since(start).as_secs_f64() < 3.0 {
        routine(snark, &mut rng);
    }
}'''
new = '''fn warm_up<H: HashInSnark>(snark: &H, mut rng: impl RngCore) {
    routine(snark, &mut rng); // single warm-up run, like the other provers
}'''
if old not in src:
    print("bench/src/lib.rs warm_up already a single run (or anchor absent).")
    sys.exit(0)
src = src.replace(old, new)
open(path, "w").write(src)
print("patched bench/src/lib.rs: warm_up is now a single run.")
PY

# Use 3 timed samples (best-of-3, since bench() now takes the min) instead of 10.
python3 - "$DIR/bench.sh" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
if "--sample-size 3" in src:
    print("bench.sh already uses --sample-size 3.")
    sys.exit(0)
if "--sample-size 10" not in src:
    print("bench.sh: --sample-size 10 anchor not found; skipping.")
    sys.exit(0)
src = src.replace("--sample-size 10", "--sample-size 3")
open(path, "w").write(src)
print("patched bench.sh to --sample-size 3 (best-of-3).")
PY

# Retarget the plonky3 keccak config to ~100-bit PROVABLE security, no grinding
# (idempotent). Upstream uses num_queries = ceil(256/log_blowup) (its ~128-bit
# target; proof_of_work_bits is already 0). We change 256 → 245, which Plonky3's
# own analyzer rates ~101-bit proven (UDR) on BabyBear^4 at rate 1/2 — matching
# the benchmarks/plonky3 (real Plonky3 example) 100-bit-provable setup.
python3 - "$DIR/plonky3/src/config/keccak_mt.rs" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "usize::div_ceil(256, log_blowup)"
new = "usize::div_ceil(245, log_blowup)"   # ~100-bit provable at rate 1/2, no PoW
if old not in s:
    print("plonky3 keccak_mt.rs query count already retargeted (or anchor absent).")
else:
    s = s.replace(old, new)
    open(p, "w").write(s)
    print("patched plonky3/src/config/keccak_mt.rs: 256 -> 245 queries (~100-bit provable).")
PY

echo "Done. See $DIR/README.md for how to run the benchmarks."
