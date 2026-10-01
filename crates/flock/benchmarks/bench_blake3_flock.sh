#!/usr/bin/env bash
# bench_blake3_flock.sh — regenerate Flock's BLAKE3 benchmarks at fixed targets,
# both multi-threaded (P-cores) and single-threaded, and refresh the shared
# bench-blake3-cache so a later ./bench_blake3.sh reassembles the full table.
#
# Always runs fresh (regenerates) and OVERWRITES each cache row — it does not
# reuse cached results. A 30s cooldown is inserted between every benchmark so
# thermal throttling doesn't bias the (heat-sensitive) single-threaded points.
#
# Targets (2^h): 10 12 14 16 18, run multi-threaded then single-threaded — ten
# benchmarks, nine cooldowns. Cache rows land at
#   bench-blake3-cache/flock_2^<h>_t<threads>
# in the exact format bench_blake3.sh writes (so they're interchangeable).
#
# Knobs:
#   SIZES="10 12 14 16 18"   log2 targets to sweep
#   COOLDOWN=30              seconds between benchmarks (0 disables)
#   RAYON_NUM_THREADS=N      override the multi-threaded core count
#
# Usage: ./bench_blake3_flock.sh

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOCK_ROOT="$(cd "$BASE/.." && pwd)"
CACHE_DIR="$BASE/bench-blake3-cache"
mkdir -p "$CACHE_DIR"

SIZES="${SIZES:-10 12 14 16 18}"
COOLDOWN="${COOLDOWN:-30}"
[[ "$COOLDOWN" =~ ^[0-9]+$ ]] || { echo "COOLDOWN must be a non-negative integer (seconds), got '$COOLDOWN'" >&2; exit 1; }

# P-core count for the multi-threaded pass (matches the other scripts so the
# cache key _t<N> lines up); an explicit RAYON_NUM_THREADS wins.
if [[ -n "${RAYON_NUM_THREADS:-}" ]]; then
	PCORES="$RAYON_NUM_THREADS"
else
	if [[ "$(uname -s)" == "Darwin" ]]; then
		PCORES="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)"
	fi
	: "${PCORES:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
fi

# --- parsing helpers (identical to bench_blake3.sh so cache rows match byte-for-byte) ---
flock_field() { # N LOG TOKEN -> "value unit"
	awk -v want="$1" -v tok="$3" '
		/=== .* compressions/ { for (i=1;i<=NF;i++) if ($i=="compressions") { curN=$(i-1); break } }
		curN == want { for (i=1;i<=NF;i++) if ($i==tok) { print $(i+1)" "$(i+2); exit } }' "$2"
}
flock_secs() {   # N LOG -> prove seconds
	awk -v want="$1" '
		/=== .* compressions/ { for (i=1;i<=NF;i++) if ($i=="compressions") { curN=$(i-1); break } }
		curN == want && /best prove_fast:/ {
			for (i=1;i<=NF;i++) if ($i=="prove_fast:") { val=$(i+1); u=$(i+2); break }
			mult=(u=="s")?1:(u=="ms")?1e-3:(u=="µs"||u=="us")?1e-6:(u=="ns")?1e-9:0
			if (mult>0) { printf "%.6f", val*mult; exit }
		}' "$2"
}
flock_proof_bytes() { # N LOG -> bytes
	awk -v want="$1" '
		/=== .* compressions/ { for (i=1;i<=NF;i++) if ($i=="compressions") { curN=$(i-1); break } }
		curN == want && /proof size:/ { for (i=1;i<=NF;i++) if ($i=="size:") { print $(i+1); exit } }' "$2"
}
human_size() {
	awk -v b="${1:-}" 'BEGIN {
		if (b == "") { print "n/a"; exit }
		if (b+0 < 1024)         printf "%d B", b
		else if (b+0 < 1048576) printf "%.2f KiB", b/1024
		else                    printf "%.2f MiB", b/1048576
	}'
}
to_ms() {
	awk -v s="${1:-}" 'BEGIN {
		n = split(s, a, " "); if (n < 2) { print "n/a"; exit }
		v = a[1]; u = a[2]
		mult = (u=="s") ? 1000 : (u=="ms") ? 1 : (u=="µs"||u=="us") ? 0.001 : (u=="ns") ? 1e-6 : 0
		if (mult == 0) { print "n/a"; exit }
		printf "%.2f ms", v * mult
	}'
}

cache_file() { echo "$CACHE_DIR/flock_2^${1}_t${2}"; }   # h, threads

# summary_row LABEL THREADS CACHEFILE — one formatted line from a cached row.
SUMMARY_FMT='  %-9s %-4s %11s %9s %11s %12s %13s\n'
summary_row() {
	local label="$1" threads="$2" f="$3" key name target count thr prove vfy sz mem
	if [[ ! -s "$f" ]]; then printf '  %-9s %-4s %11s\n' "$label" "$threads" "(no result)"; return; fi
	IFS=$'\t' read -r key name target count thr prove vfy sz mem < "$f"
	# shellcheck disable=SC2059
	printf "$SUMMARY_FMT" "$label" "$threads" "$thr" "${prove}s" "$vfy" "$sz" "$mem"
}

run_one() {  # threads h
	local t="$1" h="$2" n=$(( 1 << h )) log v vfy mem sz key thr prove row
	echo
	echo "############### flock — blake3_proof 2^$h ($n), ${t} thread(s) ###############"
	log="$(mktemp)"
	( cd "$FLOCK_ROOT" && BLAKE3_LOG2S="$h" RAYON_NUM_THREADS="$t" cargo bench --bench blake3_proof ) 2>&1 | tee "$log"

	v="$(flock_secs "$n" "$log")"
	vfy="$(to_ms "$(flock_field "$n" "$log" "verify:")")"
	mem="$(flock_field "$n" "$log" "memory:")"; mem="${mem:-n/a}"
	sz="$(human_size "$(flock_proof_bytes "$n" "$log")")"
	key="$(printf '%03d%d' "$h" 0)"
	rm -f "$log"

	if [[ -z "$v" ]]; then
		echo "  WARN: could not parse prove time for 2^$h t$t — leaving its cache row unchanged." >&2
		return
	fi
	thr="$(awk -v v="$v" -v n="$n" 'BEGIN { printf "%.0f", n / v }')"
	prove="$(awk -v v="$v" 'BEGIN { printf "%.3f", v }')"
	row="$key"$'\t'"flock"$'\t'"2^$h ($n)"$'\t'"$n"$'\t'"$thr"$'\t'"$prove"$'\t'"$vfy"$'\t'"$sz"$'\t'"$mem"
	printf '%s\n' "$row" > "$(cache_file "$h" "$t")"
	echo "  cached -> $(cache_file "$h" "$t"):  thr=${thr}/s  prove=${prove}s  verify=$vfy  proof=$sz  peak=$mem"
}

echo "=== regenerating flock BLAKE3 benchmarks: 2^[$SIZES], MT (${PCORES}t) + ST (1t), ${COOLDOWN}s cooldowns ==="

first=true
for t in "$PCORES" 1; do
	for h in $SIZES; do
		if [[ "$first" == true ]]; then
			first=false
		elif (( COOLDOWN > 0 )); then
			echo
			echo "  cooldown: sleeping ${COOLDOWN}s before the next benchmark to let the machine cool..." >&2
			sleep "$COOLDOWN"
		fi
		run_one "$t" "$h"
	done
done

echo
echo "=== results (flock BLAKE3, from $CACHE_DIR) ==="
# shellcheck disable=SC2059
printf "$SUMMARY_FMT" "target" "thr" "throughput" "prove" "verify" "proof" "peak"
for t in "$PCORES" 1; do
	for h in $SIZES; do
		summary_row "2^$h" "$t" "$(cache_file "$h" "$t")"
	done
done

echo
echo "=== done: refreshed $(( $(echo $SIZES | wc -w) * 2 )) flock blake3 cache rows in $CACHE_DIR ==="
