#!/usr/bin/env bash
# setup.sh — clone Binius64 and reproduce the keccak proving benchmark.
#
# This is the only checked-in file under binius64/; everything else (the cloned
# repo) is gitignored. It is self-contained so it works from a fresh checkout
# where binius64/ contains nothing but this script.
#
# Hash function via HASH (default keccak): keccak or sha256.
#
# keccak — two modes (KECCAK_MODE):
#   perm  (default)  N INDEPENDENT keccak-f[1600] permutations, no sponge/chain.
#                    binius64 ships no such bench, so this script emits a small
#                    self-contained example (keccak_permutations.rs) that uses
#                    binius64's public keccak-f permutation gadget. Directly
#                    comparable to Flock `cargo bench --bench keccak3_proof`
#                    (3-wide encoder; the single-permutation bench was retired)
#                    (K=4096) and plonky3's `keccak-f-permutations`.
#   hash             The built-in Keccak-256 bench: one sponge hash of an
#                    HASH_MAX_BYTES-byte message = ceil(bytes/136) sequentially-
#                    dependent permutations. (The Flock keccak_chain_proof
#                    comparison bench was retired with the chain product, 2026-08-14.)
#
# sha256 — N INDEPENDENT SHA-256 compressions via a tracked example
#   (sha256_compressions.rs, on binius64's public sha256::Compress gadget).
#   Directly comparable to Flock `cargo bench --bench sha2_proof`. Knob:
#   N_COMPRESSIONS (default 4096).
#
# Usage:
#   ./binius64/setup.sh                         # keccak perm mode, 4096 permutations
#   N_PERMUTATIONS=16384 ./binius64/setup.sh    # more independent permutations
#   KECCAK_MODE=hash HASH_MAX_BYTES=8192 ./binius64/setup.sh   # message-hash bench
#   HASH=sha256 ./binius64/setup.sh             # 4096 independent SHA-256 compressions
#   HASH=sha256 N_COMPRESSIONS=16384 ./binius64/setup.sh
#   RAYON_NUM_THREADS=12 ./binius64/setup.sh    # override thread count
#
# By default the bench is pinned to the performance-core count (see below),
# mirroring Flock's init_perf_thread_pool so the two are compared at the same
# thread count; set RAYON_NUM_THREADS to override.
# See ../CLAUDE.md "binius64/ (Binius64)" for the full comparison.

set -euo pipefail

REPO_URL="https://github.com/binius-zk/binius64"
# Pinned commit for reproducibility (the clone strips .git, so without this it
# would track whatever the default branch is at clone time). Override with
# BINIUS64_REV=<sha-or-ref> to use a different commit.
PIN="${BINIUS64_REV:-8f21b348fe8e8327b63ffa06884bf1783d40635f}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clone the repo into DIR (alongside this script) if it isn't already there.
# Clone into a temp dir first, since DIR is non-empty (it holds this script).
if [[ ! -f "$DIR/Cargo.toml" ]]; then
	echo "Cloning $REPO_URL into $DIR ..."
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	git clone "$REPO_URL" "$TMP/binius64"
	git -C "$TMP/binius64" checkout --quiet "$PIN"   # pin to a fixed commit
	shopt -s dotglob          # include dotfiles (.cargo, .github, ...)
	mv "$TMP/binius64"/* "$DIR"/
	shopt -u dotglob
	# Drop the nested .git: a git repo inside binius64/ would make the outer
	# flock-rust repo treat binius64/ as an embedded repo and refuse to track
	# this script. It isn't needed to build/benchmark.
	rm -rf "$DIR/.git"
else
	echo "binius64 already present in $DIR, skipping clone."
fi

# Apply the parallel witness-generation patch (idempotent). Stock binius64
# evaluates the witness with a single-threaded bytecode interpreter. This patch
# partitions the gate graph into independent connected components (each
# independent keccak-f permutation is its own component, sharing only constant
# wires) and evaluates them in parallel with rayon — mirroring Flock's parallel
# witness generation. Witness gen is ~6-7x faster on an 8 P-core M4 Max. The
# clone's .git was stripped above, so apply with `patch`, not `git apply`.
# Sentinel: the patch adds `run_with_store` to the interpreter.
PATCH="$DIR/parallel_witness_gen.patch"
SENTINEL="$DIR/crates/frontend/src/compiler/eval_form/interpreter.rs"
if grep -q "run_with_store" "$SENTINEL" 2>/dev/null; then
	echo "parallel witness-gen patch already applied, skipping."
elif [[ -f "$PATCH" ]]; then
	echo "Applying parallel witness-gen patch ..."
	patch -p1 -d "$DIR" < "$PATCH"
else
	echo "WARNING: $PATCH not found; running with stock single-threaded witness gen." >&2
fi

# Choose the rayon thread count the same way Flock's init_perf_thread_pool does:
# use only the performance cores. On Apple silicon the efficiency cores run at
# ~30-40% of P-core speed and become stragglers in compute-bound parallel work,
# holding up the P-cores at synchronization barriers; capping at P-cores is
# both faster and matches Flock's thread count for an apples-to-apples compare.
# An explicit RAYON_NUM_THREADS always wins (binius64 honors it natively).
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

echo "=== RAYON_NUM_THREADS=$RAYON_NUM_THREADS ($THREADS_NOTE) ==="

# Hash function to benchmark: keccak (default) or sha256.
HASH="${HASH:-keccak}"

if [[ "$HASH" == "sha256" ]]; then
	# N INDEPENDENT SHA-256 compressions via a tracked self-contained example
	# (sha256_compressions.rs, built on binius64's public sha256::Compress gadget).
	# Installed into the cloned tree as `--example sha256_compressions`; copied only
	# when it differs (cmp-guarded) so cargo's build cache stays warm. Directly
	# comparable to Flock `cargo bench --bench sha2_proof` (N independent SHA-256
	# compressions). Knobs: N_COMPRESSIONS (default 4096), LOG_INV_RATE (default 1).
	SRC="$DIR/sha256_compressions.rs"
	DEST="$DIR/crates/examples/examples/sha256_compressions.rs"
	if [[ ! -f "$DEST" ]] || ! cmp -s "$SRC" "$DEST"; then
		echo "Installing sha256_compressions.rs into the examples crate."
		cp "$SRC" "$DEST"
	fi
	NCOMP="${N_COMPRESSIONS:-4096}"
	echo "=== HASH=sha256  N_COMPRESSIONS=$NCOMP (independent; cf. Flock sha2_proof) ==="
	RUSTFLAGS="-Ctarget-cpu=native" N_COMPRESSIONS="$NCOMP" RAYON_NUM_THREADS="$RAYON_NUM_THREADS" \
		cargo run --release --manifest-path "$DIR/Cargo.toml" -p binius-examples \
		--example sha256_compressions
	exit 0
elif [[ "$HASH" == "blake3" ]]; then
	# N INDEPENDENT BLAKE3 compressions via a tracked self-contained example
	# (blake3_compressions.rs, built on binius64's public blake3::blake3_compress
	# gadget). Installed as `--example blake3_compressions`, cmp-guarded like the
	# sha256 one. Directly comparable to Flock `cargo bench --bench blake3_proof`.
	# Knobs: N_COMPRESSIONS (default 4096), LOG_INV_RATE (default 1).
	SRC="$DIR/blake3_compressions.rs"
	DEST="$DIR/crates/examples/examples/blake3_compressions.rs"
	if [[ ! -f "$DEST" ]] || ! cmp -s "$SRC" "$DEST"; then
		echo "Installing blake3_compressions.rs into the examples crate."
		cp "$SRC" "$DEST"
	fi
	NCOMP="${N_COMPRESSIONS:-4096}"
	echo "=== HASH=blake3  N_COMPRESSIONS=$NCOMP (independent; cf. Flock blake3_proof) ==="
	RUSTFLAGS="-Ctarget-cpu=native" N_COMPRESSIONS="$NCOMP" RAYON_NUM_THREADS="$RAYON_NUM_THREADS" \
		cargo run --release --manifest-path "$DIR/Cargo.toml" -p binius-examples \
		--example blake3_compressions
	exit 0
elif [[ "$HASH" != "keccak" ]]; then
	echo "unknown HASH='$HASH' (expected 'keccak', 'sha256', or 'blake3')" >&2
	exit 1
fi

MODE="${KECCAK_MODE:-perm}"

if [[ "$MODE" == "perm" ]]; then
	# Install the independent-permutation example (a tracked file next to this
	# script) into the cloned tree, where cargo auto-discovers it as
	# `--example keccak_permutations`. Only copy when it differs (or is missing),
	# so cargo's build cache stays warm and we don't recompile on every run.
	SRC="$DIR/keccak_permutations.rs"
	DEST="$DIR/crates/examples/examples/keccak_permutations.rs"
	if [[ ! -f "$DEST" ]] || ! cmp -s "$SRC" "$DEST"; then
		echo "Installing keccak_permutations.rs into the examples crate."
		cp "$SRC" "$DEST"
	fi

	NPERM="${N_PERMUTATIONS:-4096}"
	echo "=== KECCAK_MODE=perm  N_PERMUTATIONS=$NPERM (independent; cf. Flock keccak3_proof) ==="
	RUSTFLAGS="-Ctarget-cpu=native" N_PERMUTATIONS="$NPERM" RAYON_NUM_THREADS="$RAYON_NUM_THREADS" \
		cargo run --release --manifest-path "$DIR/Cargo.toml" -p binius-examples \
		--example keccak_permutations
else
	# Built-in Keccak-256 message-hash criterion bench (sequentially-dependent).
	BYTES="${HASH_MAX_BYTES:-557056}"
	PERMS=$(( (BYTES + 135) / 136 ))
	echo "=== KECCAK_MODE=hash  HASH_MAX_BYTES=$BYTES (~$PERMS perms; the Flock chain bench is retired) ==="

	BENCH_LOG="$(mktemp)"
	RUSTFLAGS="-Ctarget-cpu=native" HASH_MAX_BYTES="$BYTES" RAYON_NUM_THREADS="$RAYON_NUM_THREADS" \
		cargo bench --manifest-path "$DIR/Cargo.toml" --bench keccak -- \
		--warm-up-time 1 --measurement-time 3 --sample-size 10 \
		2>&1 | tee "$BENCH_LOG"

	# Derive keccak-call throughput from the criterion proof-generation median.
	# The result block looks like:
	#   keccak_proof_generation/message_bytes_<n>_...
	#                           time:   [<low> <u> <mid> <u> <high> <u>]
	# throughput = permutations / median_seconds.
	awk -v perms="$PERMS" '
		/^keccak_proof_generation\//          { f = 1 }
		f && /time:/ {
			gsub(/[][]/, "")
			for (i = 1; i <= NF; i++) if ($i == "time:") { v = $(i+3) + 0; u = $(i+4); break }
			mult = (u=="s") ? 1 : (u=="ms") ? 1e-3 : (u=="µs"||u=="us") ? 1e-6 : (u=="ns") ? 1e-9 : 0
			if (mult > 0 && v > 0)
				printf "\n=== throughput: %.0f keccak/s  (proof generation; %d permutations / %.3g s) ===\n", \
					perms / (v * mult), perms, v * mult
			exit
		}' "$BENCH_LOG"
	rm -f "$BENCH_LOG"
fi
