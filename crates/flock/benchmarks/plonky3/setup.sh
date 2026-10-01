#!/usr/bin/env bash
# setup.sh — clone Plonky3 and reproduce the keccak proving benchmark.
#
# This is the only checked-in file under plonky3/; everything else (the cloned
# repo) is gitignored. It is self-contained so it works from a fresh checkout
# where plonky3/ contains nothing but this script.
#
# Usage:
#   ./plonky3/setup.sh                       # clone (if needed) + run bench
#   LOG_TRACE_LENGTH=15 ./plonky3/setup.sh   # smaller/quicker run
#
# Benchmarks independent Keccak-f permutations (not chained). The trace height
# is 2^LOG_TRACE_LENGTH and keccak_count = trace_height / 24, so LOG=17 gives
# 131072/24 = 5461 keccaks. Plonky3 requires power-of-2 trace heights, so 5461
# is the nearest achievable count to Flock's K=4096 (1.33x more).
#
# Closest Flock comparison (independent permutations, 3-wide encoder):
#   cargo bench --bench keccak3_proof
# (the single-permutation keccak_proof bench was retired 2026-08-14)
# See ../CLAUDE.md "plonky3/ (Plonky3)" for the full comparison.

set -euo pipefail

REPO_URL="https://github.com/Plonky3/Plonky3.git"
# Pinned commit for reproducibility (the clone strips .git, so without this it
# would track whatever the default branch is at clone time). Override with
# PLONKY3_REV=<sha-or-ref> to use a different commit.
PIN="${PLONKY3_REV:-109e95c17070f914b694e628580cb0a620bd26e6}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clone the repo into DIR (alongside this script) if it isn't already there.
# Clone into a temp dir first, since DIR is non-empty (it holds this script).
if [[ ! -f "$DIR/Cargo.toml" ]]; then
	echo "Cloning $REPO_URL into $DIR ..."
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	git clone "$REPO_URL" "$TMP/plonky3"
	git -C "$TMP/plonky3" checkout --quiet "$PIN"   # pin to a fixed commit
	shopt -s dotglob          # include dotfiles (.github, .gitignore, ...)
	mv "$TMP/plonky3"/* "$DIR"/
	shopt -u dotglob
	# Drop the nested .git: a git repo inside plonky3/ would make the outer
	# flock-rust repo treat plonky3/ as an embedded repo and refuse to track
	# this script. It isn't needed to build/benchmark.
	rm -rf "$DIR/.git"
else
	echo "plonky3 already present in $DIR, skipping clone."
fi

# Patch the example's FRI parameters (idempotent): keep Plonky3's DEFAULT
# grinding (16-bit query PoW) but raise the query count so the security is
# ~100-bit *proven* (not just conjectured). Plonky3's default
# `new_benchmark_high_arity` is 100 queries + 16-bit PoW ≈ 113 conjectured / 65
# proven; the earlier apples-to-apples patch used 245 queries + 0 PoW ≈ 101
# proven. This config keeps the 16-bit grinding and uses 206 queries, which the
# 16-bit PoW makes ≈ the same ~101 proven as 245/0 but with a smaller proof.
# (Confirm against report_parameter_security's printed "proven" line; tune
# num_queries if the AIR/trace shifts it.)
python3 - "$DIR/examples/src/proofs.rs" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
custom = (
    "let fri_params = FriParameters {\n"
    "        log_blowup: 1,\n"
    "        log_final_poly_len: 0,\n"
    "        max_log_arity: 3,\n"
    "        num_queries: 206,            // ~100-bit PROVEN at rate 1/2 WITH 16-bit query PoW\n"
    "        commit_proof_of_work_bits: 0,\n"
    "        query_proof_of_work_bits: 16, // Plonky3's default grinding (kept)\n"
    "        mmcs: challenge_mmcs,\n"
    "    };"
)
default = "let fri_params = FriParameters::new_benchmark_high_arity(challenge_mmcs);"
if default in s:
    n = s.count(default)
    s = s.replace(default, custom)
    open(p, "w").write(s)
    print(f"patched {n} occurrence(s) of proofs.rs: 206 queries + 16-bit query PoW (~100-bit proven).")
else:
    print("proofs.rs FRI params already patched (206 queries + 16-bit query PoW).")
PY

# Run the keccak benchmark from the workspace root (so `--example` resolves).
cd "$DIR"

# Choose the rayon thread count the same way Flock's init_perf_thread_pool does:
# use only the performance cores. On Apple silicon the efficiency cores run at
# ~30-40% of P-core speed and become stragglers in compute-bound parallel work,
# holding up the P-cores at synchronization barriers; capping at P-cores is
# both faster and matches Flock's thread count for an apples-to-apples compare.
# An explicit RAYON_NUM_THREADS always wins (Plonky3 honors it via rayon's
# global pool, enabled by the `parallel` feature below).
if [[ -n "${RAYON_NUM_THREADS:-}" ]]; then
	THREADS_NOTE="user override"
else
	if [[ "$(uname -s)" == "Darwin" ]]; then
		# hw.perflevel0.physicalcpu = P-core count on Apple silicon.
		PCORES="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)"
	fi
	# Fallback (non-macOS, or sysctl unavailable): all logical CPUs, like
	# Flock's std::thread::available_parallelism() fallback.
	: "${PCORES:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
	export RAYON_NUM_THREADS="$PCORES"
	THREADS_NOTE="performance cores; matches Flock"
fi

# Hash function: keccak (default) or blake3. Plonky3's Keccak AIR uses 24 rows
# per permutation, whereas its Blake3 AIR packs a whole compression into ONE row
# (all 7 rounds in columns) — so hash_count = trace_height / ROWS_PER_HASH.
HASH="${HASH:-keccak}"
case "$HASH" in
	keccak) OBJECTIVE=keccak-f-permutations; ROWS_PER_HASH=24; UNIT=keccak; NOUN=permutations; DEFAULT_LOG=17 ;;
	blake3) OBJECTIVE=blake-3-permutations;  ROWS_PER_HASH=1;  UNIT=blake3; NOUN=compressions; DEFAULT_LOG=12 ;;
	*) echo "unknown HASH='$HASH' (expected 'keccak' or 'blake3')" >&2; exit 1 ;;
esac

COMMON_ARGS=(
	--field koala-bear
	--merkle-hash keccak-f
	--discrete-fourier-transform radix-2-dit-parallel
	--objective "$OBJECTIVE"
)

LOG_LEN="${LOG_TRACE_LENGTH:-$DEFAULT_LOG}"
HASH_COUNT=$(( (1 << LOG_LEN) / ROWS_PER_HASH ))
echo "=== $HASH: log_trace_length=$LOG_LEN  (~$HASH_COUNT $UNIT $NOUN) ==="
echo "=== RAYON_NUM_THREADS=$RAYON_NUM_THREADS ($THREADS_NOTE) ==="

# `--features parallel` is REQUIRED: Plonky3 gates all rayon parallelism behind
# this feature (off by default). Without it the prover runs single-threaded and
# is ~6-7x slower (e.g. ~780 vs ~5000 keccak/s at LOG=17 on an M4 Max). This is
# how Plonky3's own README runs the example. `-Ctarget-cpu=native` per README too.
BENCH_LOG="$(mktemp)"
# Build first (untimed), then run the prebuilt binary under /usr/bin/time so the
# peak-RSS measurement reflects the prover, not cargo/rustc.
RUSTFLAGS="-Ctarget-cpu=native" cargo build --release --features parallel --example prove_prime_field_31
P3_BIN="$DIR/target/release/examples/prove_prime_field_31"

# p3_run LOG — one example invocation, all output to LOG (under /usr/bin/time -l
# on macOS so peak RSS is recorded).
p3_run() {
	if [[ "$(uname -s)" == "Darwin" ]]; then
		/usr/bin/time -l "$P3_BIN" "${COMMON_ARGS[@]}" --log-trace-length "$LOG_LEN" >"$1" 2>&1
	else
		"$P3_BIN" "${COMMON_ARGS[@]}" --log-trace-length "$LOG_LEN" >"$1" 2>&1
	fi
}
# p3_total LOG — the run's trace+prove time in seconds (the spans we report), or empty.
p3_total() {
	awk '{
		l=$0; gsub(/\033\[[0-9;]*m/,"",l)
		if (l ~ /^INFO[ \t]+generate .* trace \[/ || l ~ /^INFO[ \t]+prove \[/) {
			tok=""; n=split(l,a,/[ \t]+/)
			for (i=1;i<=n;i++) if (a[i]=="[") { tok=a[i+1]; break }
			match(tok,/^[0-9.]+/); v=substr(tok,RSTART,RLENGTH)+0; u=substr(tok,RSTART+RLENGTH)
			mult=(u=="s")?1:(u=="ms")?1e-3:(u=="µs"||u=="us")?1e-6:(u=="ns")?1e-9:0
			s=(mult>0)?v*mult:0
			if (l ~ /generate/) { trace=s } else { print trace+s; exit }
		}
	}' "$1"
}

# 1 warm-up (untimed) + best-of-3 timed runs; keep the fastest (trace+prove) run
# in BENCH_LOG, which the parsing below reads. Matches flock/binius64, which also
# warm up then take the best of 3.
echo "=== $HASH: warm-up + best-of-3 (log_trace_length=$LOG_LEN, RAYON_NUM_THREADS=$RAYON_NUM_THREADS) ==="
P3_TMP="$(mktemp)"
p3_run "$P3_TMP"   # warm-up, discarded
best_s=""
for i in 1 2 3; do
	p3_run "$P3_TMP"
	tot="$(p3_total "$P3_TMP")"
	echo "  [run $i/3] trace+prove: ${tot:-?} s"
	if [[ -n "$tot" ]] && { [[ -z "$best_s" ]] || awk "BEGIN{exit !($tot < $best_s)}"; }; then
		best_s="$tot"; cp "$P3_TMP" "$BENCH_LOG"
	fi
done
rm -f "$P3_TMP"
cat "$BENCH_LOG"   # surface the best run's full output (incl. "Proof size:")

# Derive keccak-call throughput from the top-level `prove` tracing span, e.g.:
#   INFO    prove [ 439ms | 0.00% / 100.00% ]
# throughput = keccaks / prove_seconds. (The nested prove_with_preprocessed
# line carries a tree glyph, so anchoring on "^INFO<ws>prove [" skips it.)
awk -v hashes="$HASH_COUNT" -v unit="$UNIT" -v noun="$NOUN" '{
	l = $0; gsub(/\033\[[0-9;]*m/, "", l)          # strip ANSI color codes
	# Fold the top-level "generate <Hash> trace" span into the prover time:
	# trace generation is part of proving (and is parallelized just like the
	# prover), so include it for parity with flock/binius64, whose prove times
	# include witness generation. The trace span precedes the prove span.
	if (l ~ /^INFO[ \t]+generate .* trace \[/ || l ~ /^INFO[ \t]+prove \[/) {
		tok = ""
		n = split(l, a, /[ \t]+/)
		for (i = 1; i <= n; i++) if (a[i] == "[") { tok = a[i+1]; break }
		match(tok, /^[0-9.]+/); v = substr(tok, RSTART, RLENGTH) + 0; u = substr(tok, RSTART + RLENGTH)
		mult = (u=="s") ? 1 : (u=="ms") ? 1e-3 : (u=="µs"||u=="us") ? 1e-6 : (u=="ns") ? 1e-9 : 0
		s = (mult > 0) ? v * mult : 0
		if (l ~ /generate/) { trace = s }         # remember trace-gen time
		else {                                    # the prove span: emit + stop
			total = trace + s
			if (s > 0 && total > 0)
				printf "\n=== throughput: %.0f %s/s  (prove+trace; %d %s / %.3g s) ===\n", \
					hashes / total, unit, hashes, noun, total
			exit
		}
	}
}' "$BENCH_LOG"

# Emit the verifier time from the top-level `verify` tracing span, e.g.:
#   INFO    verify [ 11.0ms | 0.10% / 100.00% ]
# as a normalized "verify: <value> <unit>" line for the orchestrator to pick up.
awk '{
	l = $0; gsub(/\033\[[0-9;]*m/, "", l)
	if (l ~ /^INFO[ \t]+verify \[/) {
		n = split(l, a, /[ \t]+/)
		for (i = 1; i <= n; i++) if (a[i] == "[") { tok = a[i+1]; break }
		match(tok, /^[0-9.]+/); v = substr(tok, RSTART, RLENGTH); u = substr(tok, RSTART + RLENGTH)
		if (v != "") print "verify: " v " " u
		exit
	}
}' "$BENCH_LOG"

# Emit peak memory from /usr/bin/time -l's "maximum resident set size" (bytes on
# macOS), as a "peak memory: <value> <unit>" line for the orchestrator.
awk '/maximum resident set size/ {
	b = $1 + 0
	if (b >= 1073741824) printf "peak memory: %.2f GB\n", b / 1073741824
	else                 printf "peak memory: %.2f MB\n", b / 1048576
	exit
}' "$BENCH_LOG"
rm -f "$BENCH_LOG"
