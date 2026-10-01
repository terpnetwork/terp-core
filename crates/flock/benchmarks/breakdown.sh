#!/usr/bin/env bash
# breakdown.sh — per-phase percentage breakdown of Flock's fast prover for the
# three hash circuits (3-wide keccak, SHA-256, BLAKE3) at a fixed batch target
# (default 2^14).
#
# For each hash it runs the corresponding `*_proof` bench's inline
# `[prove_fast breakdown]` (a single, non-best-of-N prove that times the five
# prover phases: witness gen, PCS commit, zerocheck, lincheck, PCS open) and
# reports each phase as a percentage of the breakdown total, side by side.
#
# Note the 3-wide keccak encoder proves 3·2^(h-1) permutations for a 2^h target
# (= 1.5× the count at the same committed size m), matching how bench_keccak.sh
# drives `flock`; SHA-256 and BLAKE3 prove exactly 2^h.
#
# Knobs:
#   TARGET_LOG2        log2 batch target h (default 14)
#   RAYON_NUM_THREADS  thread count (default: Flock's P-core pool, like the
#                      other scripts; set 1 for the single-threaded breakdown)
#
# Usage:
#   ./benchmarks/breakdown.sh
#   TARGET_LOG2=16 ./benchmarks/breakdown.sh
#   RAYON_NUM_THREADS=1 ./benchmarks/breakdown.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

H="${TARGET_LOG2:-14}"
if (( H < 1 )); then
	echo "TARGET_LOG2 must be >= 1 (got $H)" >&2
	exit 1
fi
KECCAK_N=$(( 3 * (1 << (H - 1)) ))   # 3-wide proves 3·2^(h-1) for target 2^h
HASH_N=$(( 1 << H ))                  # sha256/blake3 prove exactly 2^h

THREADS_NOTE="${RAYON_NUM_THREADS:+RAYON_NUM_THREADS=$RAYON_NUM_THREADS}"
: "${THREADS_NOTE:=Flock P-core pool}"

echo "=== Flock fast-prover phase breakdown  (target 2^$H; threads: $THREADS_NOTE) ==="
echo "    3-wide keccak: $KECCAK_N permutations   sha256/blake3: $HASH_N compressions"
echo

# Build the three benches up front so build chatter doesn't pollute the parse
# and a build failure is surfaced clearly.
echo "building benches ..." >&2
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
if ! cargo build --release --bench keccak3_proof --bench sha2_proof --bench blake3_proof \
		>/dev/null 2>"$BUILD_LOG"; then
	echo "build failed:" >&2
	cat "$BUILD_LOG" >&2
	exit 1
fi

# parse: read a bench's stdout, emit "w% c% z% l% o% total_ms" for the five
# phases inside the [prove_fast breakdown] block. Times are normalized to ms.
parse() {
	awk '
		/\[prove_fast breakdown\]/ { inb = 1; next }
		inb {
			val = $(NF - 1) + 0; unit = $NF
			mult = -1
			if (unit == "s") mult = 1000
			else if (unit == "ms") mult = 1
			else if (unit == "µs" || unit == "us") mult = 0.001
			else if (unit == "ns") mult = 0.000001
			if (mult < 0) next
			ms = val * mult
			if      ($0 ~ /gen_witness/)     w = ms
			else if ($0 ~ /pcs::commit/)     c = ms
			else if ($0 ~ /zerocheck/)       z = ms
			else if ($0 ~ /lincheck::prove/) l = ms
			else if ($0 ~ /pcs::open/)       o = ms
		}
		END {
			tot = w + c + z + l + o
			if (tot <= 0) { print "ERR"; exit 1 }
			printf "%.1f %.1f %.1f %.1f %.1f %.1f\n",
				100*w/tot, 100*c/tot, 100*z/tot, 100*l/tot, 100*o/tot, tot
		}
	'
}

KEC="$(KECCAK3_KS="$KECCAK_N" cargo bench --bench keccak3_proof 2>/dev/null | parse)"
SHA="$(SHA2_LOG2S="$H"        cargo bench --bench sha2_proof   2>/dev/null | parse)"
BLA="$(BLAKE3_LOG2S="$H"      cargo bench --bench blake3_proof 2>/dev/null | parse)"

for v in "$KEC" "$SHA" "$BLA"; do
	if [[ "$v" == "ERR" || -z "$v" ]]; then
		echo "error: a bench produced no [prove_fast breakdown] output" >&2
		exit 1
	fi
done

read -r kw kc kz kl ko kt <<< "$KEC"
read -r sw sc sz sl so st <<< "$SHA"
read -r bw bc bz bl bo bt <<< "$BLA"

rule() { printf '%s\n' "------------------------------+----------+----------+----------"; }

printf '%-30s|%9s |%9s |%9s\n' "phase" "keccak3" "sha256" "blake3"
rule
printf '%-30s|%8s%% |%8s%% |%8s%%\n' "gen_witness + lincheck" "$kw" "$sw" "$bw"
printf '%-30s|%8s%% |%8s%% |%8s%%\n' "pcs::commit"            "$kc" "$sc" "$bc"
printf '%-30s|%8s%% |%8s%% |%8s%%\n' "zerocheck::prove_packed" "$kz" "$sz" "$bz"
printf '%-30s|%8s%% |%8s%% |%8s%%\n' "lincheck::prove"        "$kl" "$sl" "$bl"
printf '%-30s|%8s%% |%8s%% |%8s%%\n' "pcs::open (ligerito)"   "$ko" "$so" "$bo"
rule
printf '%-30s|%7s ms |%7s ms |%7s ms\n' "breakdown total" "$kt" "$st" "$bt"
