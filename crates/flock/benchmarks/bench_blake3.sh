#!/usr/bin/env bash
# bench_blake3.sh — BLAKE3 compression proving: Flock vs binius64 vs plonky3,
# single- and multi-threaded, over per-prover, per-mode size lists (see below).
# The BLAKE3 sibling of bench_keccak.sh / bench_sha256.sh (same caching,
# prover-selection, sort-by-prover, dashed-separator two-table layout).
#
# - flock:     `cargo bench --bench blake3_proof` (N independent BLAKE3
#              compressions; prove_fast, incl. witness gen). Honors BLAKE3_LOG2S.
# - binius64:  `HASH=blake3 binius64/setup.sh` — N independent BLAKE3 compressions
#              via the tracked blake3_compressions.rs example (blake3_compress gadget).
# - plonky3:   `HASH=blake3 plonky3/setup.sh` — Plonky3 Blake3Air (1 row/compression),
#              ~100-bit-provable FRI params. Proof is large (very wide trace).
#
# hashcaster is excluded (no BLAKE3 circuit).
#
# Usage: bench_blake3.sh [PROVER ...]   (no args = all). PROVER ∈
#   flock | binius64 | plonky3   (alias: all). $ONLY works too.
#   e.g.  ./bench_blake3.sh flock        ./bench_blake3.sh plonky3
#
# Single-threaded comparison: after the main (P-core) pass, each selected prover
# is re-run single-threaded (RAYON_NUM_THREADS=1) over its per-mode size list and
# printed as a second table. DO_ST=0 skips it.
#
# Sizes are per-prover, per-mode lists ({FLOCK,B64,P3}_{MT,ST}_SIZES, defaults
# below): flock runs the large sizes, the competitors the small ones, and a
# prover's MT and ST lists can differ.
#
# Caching: every result is saved under bench-blake3-cache/<prover>_2^<h>_t<threads>.
# A plain `./bench_blake3.sh` reuses cached rows and only runs what's missing;
# naming a prover re-runs it fresh. USE_CACHE=1 reuses even with args; NO_CACHE=1
# forces fresh runs (still caching). Knobs: per-prover {FLOCK,B64,P3}_{MT,ST}_SIZES
# size lists, DO_ST=0 to skip the single-threaded pass, RAYON_NUM_THREADS. See
# ../CLAUDE.md "External Benchmarks".

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOCK_ROOT="$(cd "$BASE/.." && pwd)"

# Thread count — performance-core count by default (matches Flock's
# init_perf_thread_pool); RAYON_NUM_THREADS wins. Also part of cache keys.
if [[ -n "${RAYON_NUM_THREADS:-}" ]]; then
	THREADS="$RAYON_NUM_THREADS"
else
	if [[ "$(uname -s)" == "Darwin" ]]; then PCORES="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)"; fi
	: "${PCORES:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
	THREADS="$PCORES"
fi
PRIMARY_THREADS="$THREADS"

# Per-prover, per-mode size lists (log2 #compressions). Each prover runs exactly
# its own list in each pass (see sweep_provers) — there is no shared sweep, so the
# provers can cover different ranges: flock at the large sizes where it shines,
# the competitors at the small sizes where they peak. Sizes above a prover's cap
# (below) are still skipped as a safety net.
FLOCK_MT_SIZES="${FLOCK_MT_SIZES:-10 12 14 16 18}"
B64_MT_SIZES="${B64_MT_SIZES:-12 14}"
P3_MT_SIZES="${P3_MT_SIZES:-12 14 16}"
FLOCK_ST_SIZES="${FLOCK_ST_SIZES:-10 12 14 16 18}"
B64_ST_SIZES="${B64_ST_SIZES:-10 12 14}"
P3_ST_SIZES="${P3_ST_SIZES:-10 12 14}"
DO_ST="${DO_ST:-1}"   # set 0 to skip the single-threaded pass

# Per-prover max log2 size. A prover skips any sweep size above its cap (stderr
# notice). Raise on a bigger/faster box.
#   flock     19: BLAKE3 K_LOG=14, so memory is modest (~13 GB at 2^19's m=33).
#   binius64  14: limited by its single-threaded frontend CircuitBuilder::build()
#                 (builds N blake3 gadgets serially). 2^15 is *possible*
#                 (B64_MAX_LOG2=15) but off by default: ~112 s wall (build-
#                 dominated), with a ~29 GB transient build footprint that only
#                 finishes via the macOS compressor (~13 GB RSS). 2^16 won't fit.
#   plonky3   16: Blake3Air is 1 row/compression but very wide → large proofs.
# Ligerito's larger memory footprint thrashes at 2^19 (~16.9 GB) on a 24 GB box
# — throughput collapses there — so flock is capped at 2^18 (~8.5 GB).
FLOCK_MAX_LOG2="${FLOCK_MAX_LOG2:-18}"
B64_MAX_LOG2="${B64_MAX_LOG2:-14}"
P3_MAX_LOG2="${P3_MAX_LOG2:-16}"

# --cooldown N (seconds between sweeps; default 0 = off; also via COOLDOWN env).
# Stripped from positional args before prover selection / the cache-read check.
COOLDOWN="${COOLDOWN:-0}"
_pos=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--cooldown) shift; COOLDOWN="${1:-0}"; [[ $# -gt 0 ]] && shift ;;
		--cooldown=*) COOLDOWN="${1#*=}"; shift ;;
		*) _pos+=("$1"); shift ;;
	esac
done
set -- ${_pos[@]+"${_pos[@]}"}
[[ "$COOLDOWN" =~ ^[0-9]+$ ]] || { echo "--cooldown expects a non-negative integer (seconds), got '$COOLDOWN'" >&2; exit 1; }

# Prover selection (CLI args or $ONLY; default all three).
do_flock=false; do_b64=false; do_p3=false
if [[ $# -gt 0 ]]; then REQUESTED=("$@")
elif [[ -n "${ONLY:-}" ]]; then
	# shellcheck disable=SC2206
	REQUESTED=($ONLY)
else REQUESTED=(all); fi
for tok in "${REQUESTED[@]}"; do
	case "$tok" in
		flock)    do_flock=true ;;
		binius64) do_b64=true ;;
		plonky3)  do_p3=true ;;
		all)      do_flock=true; do_b64=true; do_p3=true ;;
		*) echo "unknown prover '$tok' (flock|binius64|plonky3|all)" >&2; exit 1 ;;
	esac
done

ROWS=()

# --- Result cache (mirrors bench_keccak.sh / bench_sha256.sh) -----------------
CACHE_DIR="$BASE/bench-blake3-cache"
mkdir -p "$CACHE_DIR"
if [[ -n "${NO_CACHE:-}" ]]; then cache_read=false
elif [[ -n "${USE_CACHE:-}" ]]; then cache_read=true
elif [[ $# -eq 0 && -z "${ONLY:-}" ]]; then cache_read=true
else cache_read=false; fi

# ---- Cooldowns (opt-in via --cooldown N / COOLDOWN=N) ------------------------
# Sleep before each benchmark (each prover x size, MT and ST) to let the machine
# cool; only fires when the preceding benchmark measured something fresh (cache
# hits / cap skips generate no heat, so they don't trigger a wait). The cooldown
# calls live inside run_flock / run_b64_size / run_p3_size, before the real run.
COOLDOWN_DID_FRESH=0
mark_fresh() { COOLDOWN_DID_FRESH=1; }
cooldown() {
	[[ "${COOLDOWN:-0}" -gt 0 && "$COOLDOWN_DID_FRESH" == 1 ]] || return 0
	echo "  cooldown: sleeping ${COOLDOWN}s before ${1:-the next sweep} to let the machine cool..." >&2
	sleep "$COOLDOWN"
	COOLDOWN_DID_FRESH=0
}

cache_file() { echo "$CACHE_DIR/${1}_2^${2}_t${THREADS}"; }
cache_lookup() {
	local f; f="$(cache_file "$1" "$2")"
	[[ "$cache_read" == true && -s "$f" ]] || return 1
	echo "  using cached result: $1 2^$2 ($(( 1 << $2 ))), ${THREADS}t"
	ROWS+=("$(cat "$f")")
}
add_row() {
	ROWS+=("$3")
	mark_fresh   # a fresh measurement ran (cache hits never reach add_row)
	case "$3" in
		*$'\t'FAILED$'\t'*) ;;
		*) printf '%s\n' "$3" > "$(cache_file "$1" "$2")" ;;
	esac
}

# --- formatting helpers ------------------------------------------------------
to_ms() {
	awk -v s="${1:-}" 'BEGIN {
		n = split(s, a, " "); if (n < 2) { print "n/a"; exit }
		v = a[1]; u = a[2]
		mult = (u=="s") ? 1000 : (u=="ms") ? 1 : (u=="µs"||u=="us") ? 0.001 : (u=="ns") ? 1e-6 : 0
		if (mult == 0) { print "n/a"; exit }
		printf "%.2f ms", v * mult
	}'
}
human_size() {
	awk -v b="${1:-}" 'BEGIN {
		if (b == "") { print "n/a"; exit }
		if (b+0 < 1024)         printf "%d B", b
		else if (b+0 < 1048576) printf "%.2f KiB", b/1024
		else                    printf "%.2f MiB", b/1048576
	}'
}

# --- flock (blake3_proof) ----------------------------------------------------
# Section header in the bench output: "=== <n> compressions  (m = ...) ===".
flock_secs() {   # N LOG
	awk -v want="$1" '
		/=== .* compressions/ { for (i=1;i<=NF;i++) if ($i=="compressions") { curN=$(i-1); break } }
		curN == want && /best prove_fast:/ {
			for (i=1;i<=NF;i++) if ($i=="prove_fast:") { val=$(i+1); u=$(i+2); break }
			mult=(u=="s")?1:(u=="ms")?1e-3:(u=="µs"||u=="us")?1e-6:(u=="ns")?1e-9:0
			if (mult>0) { printf "%.6f", val*mult; exit }
		}' "$2"
}
flock_field() { # N LOG TOKEN
	awk -v want="$1" -v tok="$3" '
		/=== .* compressions/ { for (i=1;i<=NF;i++) if ($i=="compressions") { curN=$(i-1); break } }
		curN == want { for (i=1;i<=NF;i++) if ($i==tok) { print $(i+1)" "$(i+2); exit } }' "$2"
}
flock_proof_bytes() { # N LOG
	awk -v want="$1" '
		/=== .* compressions/ { for (i=1;i<=NF;i++) if ($i=="compressions") { curN=$(i-1); break } }
		curN == want && /proof size:/ { for (i=1;i<=NF;i++) if ($i=="size:") { print $(i+1); exit } }' "$2"
}

# run_flock SIZES — sweep flock over the in-budget, uncached sizes in one bench run.
run_flock() {
	local sizes="$1" log status spec h n key v thr prove vfy mem sz specs ks
	specs=(); ks=""
	for h in $sizes; do
		if (( h > FLOCK_MAX_LOG2 )); then
			echo "skipping flock 2^$h: above FLOCK_MAX_LOG2=$FLOCK_MAX_LOG2 budget." >&2
			continue
		fi
		cache_lookup flock "$h" && continue
		specs+=("$h:$(( 1 << h ))"); ks="${ks:+$ks }$h"
	done
	[[ -z "$ks" ]] && return
	cooldown "flock 2^$ks"
	echo
	echo "############### flock — blake3_proof (2^[$ks]) ###############"
	log="$(mktemp)"
	set +e
	( cd "$FLOCK_ROOT" && BLAKE3_LOG2S="$ks" cargo bench --bench blake3_proof ) 2>&1 | tee "$log"
	status="${PIPESTATUS[0]}"
	set -e
	if [[ "$status" -ne 0 ]]; then
		for spec in "${specs[@]}"; do h="${spec%%:*}"; n="${spec##*:}"
			add_row flock "$h" "$(printf '%03d%d' "$h" 0)"$'\t'"flock"$'\t'"2^$h ($n)"$'\t'"-"$'\t'"FAILED"$'\t'"-"$'\t'"-"$'\t'"-"$'\t'"-"
		done
		rm -f "$log"; return
	fi
	for spec in "${specs[@]}"; do
		h="${spec%%:*}"; n="${spec##*:}"
		key="$(printf '%03d%d' "$h" 0)"
		vfy="$(to_ms "$(flock_field "$n" "$log" "verify:")")"
		mem="$(flock_field "$n" "$log" "memory:")"; mem="${mem:-n/a}"
		sz="$(human_size "$(flock_proof_bytes "$n" "$log")")"
		v="$(flock_secs "$n" "$log")"
		if [[ -z "$v" ]]; then
			ROWS+=("$key"$'\t'"flock"$'\t'"2^$h ($n)"$'\t'"$n"$'\t'"?"$'\t'"?"$'\t'"$vfy"$'\t'"$sz"$'\t'"$mem")  # parse failed; don't cache
		else
			thr="$(awk -v v="$v" -v n="$n" 'BEGIN { printf "%.0f", n / v }')"
			prove="$(awk -v v="$v" 'BEGIN { printf "%.3f", v }')"
			add_row flock "$h" "$key"$'\t'"flock"$'\t'"2^$h ($n)"$'\t'"$n"$'\t'"$thr"$'\t'"$prove"$'\t'"$vfy"$'\t'"$sz"$'\t'"$mem"
		fi
	done
	rm -f "$log"
}

# run_setup KEY NAME H N HASHENV EXTRAENV... — run a competitor setup.sh (binius64
# or plonky3) that prints a "throughput: N <unit>/s (...; N compressions / T s)"
# line plus verify/peak/proof-size, and record the parsed row. The sub-script is
# selected by $2 (binius64|plonky3); env is passed via the caller.
run_setup() {
	local key="$1" name="$2" h="$3" n="$4" script="$5" log status line thr kc prove vfy sz mem
	echo
	echo "############### $name — blake3 2^$h ($n) ###############"
	log="$(mktemp)"
	set +e
	# Use `env` so the per-prover assignment in $6 (e.g. N_COMPRESSIONS=4096) is
	# applied even though it comes from a variable (a bare `$6 cmd` would treat the
	# expanded VAR=val as a command, not a prefix assignment).
	# shellcheck disable=SC2086
	env HASH=blake3 RAYON_NUM_THREADS="$THREADS" $6 bash "$script" 2>&1 | tee "$log"
	status="${PIPESTATUS[0]}"
	set -e
	if [[ "$status" -ne 0 ]]; then
		add_row "$name" "$h" "$key"$'\t'"$name"$'\t'"2^$h ($n)"$'\t'"-"$'\t'"FAILED"$'\t'"-"$'\t'"-"$'\t'"-"$'\t'"-"
		rm -f "$log"; return
	fi
	line="$(grep -E 'throughput:' "$log" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"
	read -r thr kc prove < <(awk '{
		for (i = 1; i <= NF; i++) {
			if ($i == "throughput:")  t = $(i+1)
			if ($i == "compressions") k = $(i-1)
			if ($i == "/")            p = $(i+1)
		}
		print t, k, p
	}' <<< "$line")
	vfy="$(to_ms "$(awk '$0 ~ /verify:/ { for (i=1;i<=NF;i++) if ($i=="verify:") { print $(i+1)" "$(i+2); exit } }' "$log")")"
	mem="$(awk '/peak memory:/ { for (i=1;i<=NF;i++) if ($i=="memory:") { print $(i+1)" "$(i+2); exit } }' "$log")"
	sz="$(human_size "$(awk 'tolower($0) ~ /proof size/ { for (i=1;i<=NF;i++) if ($i=="bytes") { print $(i-1); exit } }' "$log")")"
	rm -f "$log"
	add_row "$name" "$h" "$key"$'\t'"$name"$'\t'"2^$h ($n)"$'\t'"${kc:-?}"$'\t'"${thr:-?}"$'\t'"${prove:-?}"$'\t'"$vfy"$'\t'"$sz"$'\t'"${mem:-n/a}"
}

# run_b64_size H — binius64 (N independent compressions; N_COMPRESSIONS=2^h).
run_b64_size() {
	local h="$1" n
	n=$(( 1 << h ))
	if (( h > B64_MAX_LOG2 )); then
		echo "skipping binius64 2^$h: above B64_MAX_LOG2=$B64_MAX_LOG2 budget." >&2
	elif cache_lookup binius64 "$h"; then :
	else run_setup "$(printf '%03d%d' "$h" 1)" binius64 "$h" "$n" "$BASE/binius64/setup.sh" "N_COMPRESSIONS=$n"; fi
}

# run_p3_size H — plonky3 (Blake3Air; 1 row/compression, so LOG_TRACE_LENGTH=h).
run_p3_size() {
	local h="$1" n
	n=$(( 1 << h ))
	if (( h > P3_MAX_LOG2 )); then
		echo "skipping plonky3 2^$h: above P3_MAX_LOG2=$P3_MAX_LOG2 budget." >&2
	elif cache_lookup plonky3 "$h"; then :
	else run_setup "$(printf '%03d%d' "$h" 2)" plonky3 "$h" "$n" "$BASE/plonky3/setup.sh" "LOG_TRACE_LENGTH=$h"; fi
}

# sweep_provers SIZES — run selected provers over the sizes at the current threads.
sweep_provers() {
	local mode="$1" fsz bsz psz h
	if [[ "$mode" == st ]]; then
		fsz="$FLOCK_ST_SIZES"; bsz="$B64_ST_SIZES"; psz="$P3_ST_SIZES"
	else
		fsz="$FLOCK_MT_SIZES"; bsz="$B64_MT_SIZES"; psz="$P3_MT_SIZES"
	fi
	# Per-size so each (prover, size) is its own run with a cooldown before it
	# (cooldowns live inside run_flock / run_b64_size / run_p3_size, right before
	# the real measurement, so cap/cache skips don't trigger a pointless wait).
	if [[ "$do_flock" == true ]]; then for h in $fsz; do run_flock "$h"; done; fi
	if [[ "$do_b64"   == true ]]; then for h in $bsz; do run_b64_size "$h"; done; fi
	if [[ "$do_p3"    == true ]]; then for h in $psz; do run_p3_size  "$h"; done; fi
}

# Main (multi-thread) pass, then the single-thread pass. sweep_provers takes a
# MODE (mt|st), not sizes — each prover's sizes come from its own *_MT_SIZES /
# *_ST_SIZES list.
sweep_provers mt

ST_START=${#ROWS[@]}
if [[ "$DO_ST" != 0 && "$PRIMARY_THREADS" != "1" ]]; then
	echo
	echo "=== single-threaded pass (RAYON_NUM_THREADS=1): flock 2^[$FLOCK_ST_SIZES], binius64 2^[$B64_ST_SIZES], plonky3 2^[$P3_ST_SIZES] ==="
	THREADS=1
	export RAYON_NUM_THREADS=1
	cooldown "the blake3 single-threaded pass"
	sweep_provers st
fi

# sec_label NAME — targeted provable-security bits (config property).
sec_label() {
	case "$1" in
		flock)    echo "~100" ;;
		binius64) echo "~96"  ;;   # FRI query-phase accounting
		plonky3)  echo "~101" ;;   # 245 queries, 0 PoW
		*)        echo "n/a"  ;;
	esac
}

# prover_order NAME — sort rank (table groups by prover); print_table re-derives
# the sort key from (name, target) so rows sort by prover then size.
prover_order() {
	case "$1" in
		flock)    echo 0 ;;
		binius64) echo 1 ;;
		plonky3)  echo 2 ;;
		*)        echo 9 ;;
	esac
}

# ---- Summary table(s) -------------------------------------------------------
fmt='  %-11s %-8s %-14s %12s %12s %9s %11s %11s %11s\n'
dashes() { local i s=""; for ((i = 0; i < $1; i++)); do s+="-"; done; printf '%s' "$s"; }
# rule — a full-width row of dashes (under the header and between provers).
# shellcheck disable=SC2059
rule() { printf "$fmt" "$(dashes 11)" "$(dashes 8)" "$(dashes 14)" "$(dashes 12)" "$(dashes 12)" "$(dashes 9)" "$(dashes 11)" "$(dashes 11)" "$(dashes 11)"; }
print_table() {
	local title="$1"; shift
	(( $# > 0 )) || return 0
	local row _key name target kc thr prove vfy sz mem prev
	echo
	echo "  $title"
	echo
	# shellcheck disable=SC2059
	printf "$fmt" "prover" "security" "target" "compressions" "throughput" "prove" "verify" "proof size" "peak mem"
	rule
	# Sort by prover, then target size ascending (key re-derived from name+target).
	local SORTED=() _n _t _h
	while IFS= read -r row; do SORTED+=("$row"); done < <(
		for row in "$@"; do
			IFS=$'\t' read -r _ _n _t _ <<< "$row"
			_h="${_t#2^}"; _h="${_h%% *}"   # "2^12 (4096)" -> "12"
			printf '%d%03d\t%s\n' "$(prover_order "$_n")" "$_h" "$row"
		done | sort | cut -f2-
	)
	prev=""
	for row in "${SORTED[@]}"; do
		IFS=$'\t' read -r _key name target kc thr prove vfy sz mem <<< "$row"
		[[ -n "$prev" && "$name" != "$prev" ]] && rule
		prev="$name"
		if [[ "$thr" == "FAILED" ]]; then
			# shellcheck disable=SC2059
			printf "$fmt" "$name" "$(sec_label "$name")" "$target" "$kc" "FAILED" "$prove" "$vfy" "$sz" "$mem"
		else
			# shellcheck disable=SC2059
			printf "$fmt" "$name" "$(sec_label "$name")" "$target" "$kc" "$thr h/s" "$prove s" "$vfy" "$sz" "$mem"
		fi
	done
}

if (( ST_START > 0 )); then
	print_table "blake3 compression proving (${PRIMARY_THREADS} threads) — security · throughput · prove/verify · proof size · peak memory" "${ROWS[@]:0:ST_START}"
fi
if (( ${#ROWS[@]} > ST_START )); then
	print_table "single-threaded (1 thread) — flock 2^[$FLOCK_ST_SIZES], binius64 2^[$B64_ST_SIZES], plonky3 2^[$P3_ST_SIZES]" "${ROWS[@]:ST_START}"
fi
echo
echo "  notes: N INDEPENDENT BLAKE3 compressions. 'security' = targeted provable-security bits"
echo "         (flock ~100 Johnson, plonky3 ~101 [245 queries, no PoW], binius64 ~96 FRI"
echo "         query-phase). 'prove' is prover time; throughput = compressions / prove; all are"
echo "         end-to-end incl. witness/trace gen. plonky3's Blake3Air packs a compression into one"
echo "         (very wide) row, so its proofs are much larger. Results cached under bench-blake3-cache/"
echo "         and reused on a plain default run; name a prover to re-measure, NO_CACHE=1 to refresh."
echo "         hashcaster is excluded (no BLAKE3 circuit)."
