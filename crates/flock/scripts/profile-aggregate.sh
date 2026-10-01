#!/bin/bash
# Aggregate top-N hot symbols from a samply profile.
#
# Usage:
#   scripts/profile-aggregate.sh <profile.json> <binary> [thread_index] [top_n]
#
# Example:
#   scripts/profile-aggregate.sh /tmp/prover.json $(ls -t target/release/deps/profile_prover-* | grep -v '\.d$' | head -1) 1 30
set -e

PROFILE_JSON="${1:?usage: profile-aggregate.sh <profile.json> <binary> [thread] [top_n]}"
BINARY="${2:?need binary path}"
THREAD="${3:-1}"          # default to worker thread 1 (main is 0, usually empty for our benches)
TOP_N="${4:-30}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Extract addresses + counts from the samply profile for the given thread.
python3 << PYEOF > "$TMPDIR/addrs.txt"
import json
from collections import Counter

with open('$PROFILE_JSON') as f:
    data = json.load(f)

t = data['threads'][$THREAD]
frames = t.get('frameTable', {})
stacks = t.get('stackTable', {})
samples = t['samples']
frame_addr = frames.get('address', [])
stack_frame = stacks.get('frame', [])

self_counter = Counter()
total = 0
for s_idx in samples['stack']:
    if s_idx is None or s_idx < 0: continue
    frame_idx = stack_frame[s_idx]
    addr = frame_addr[frame_idx] if frame_idx < len(frame_addr) else 0
    self_counter[addr] += 1
    total += 1

import sys
print(f"# Thread $THREAD: {total} samples ({t.get('name', '')})", file=sys.stderr)
for addr, count in self_counter.most_common($TOP_N * 5):
    print(f"0x{addr + 0x100000000:x} {count}")
PYEOF

awk '{print $1}' "$TMPDIR/addrs.txt" > "$TMPDIR/just_addrs.txt"
atos -o "$BINARY" -arch arm64 --inlineFrames -d "@" -f "$TMPDIR/just_addrs.txt" 2>/dev/null > "$TMPDIR/inline.txt"

paste -d'|' "$TMPDIR/addrs.txt" "$TMPDIR/inline.txt" | python3 -c "
import sys, re
from collections import defaultdict

totals = defaultdict(int)
for line in sys.stdin:
    parts = line.strip().split('|')
    if len(parts) < 2: continue
    ac = parts[0].split()
    if len(ac) < 2: continue
    count = int(ac[1])
    chain = parts[1].split('@')

    # Pick first 'interesting' frame: prefer flock/sha/blake3 frames over generic.
    chosen = None
    for f in chain:
        if 'flock::' in f or 'sha2::' in f or 'blake3::' in f or 'vsha256' in f or 'binius' in f.lower():
            chosen = f
            break
    if not chosen:
        chosen = chain[0]

    sym = chosen
    sym = re.sub(r'::h[0-9a-f]+', '', sym)
    sym = re.sub(r' \(in .*?\)', '', sym)
    sym = re.sub(r' \(.*?\.rs:[0-9]+\)', '', sym)
    while True:
        nsym = re.sub(r'<[^<>]*>', '', sym)
        if nsym == sym: break
        sym = nsym
    sym = re.sub(r' \([^)]+\)', '', sym).strip()
    sym = (sym.replace('flock::','f::')
              .replace('zerocheck::','zc::')
              .replace('univariate_skip_optimized::','urm::')
              .replace('ring_switch::','rs::')
              .replace('additive_ntt_f128::','antt::'))
    totals[sym] += count

total = sum(totals.values())
print(f'\nTop $TOP_N hot symbols (worker thread, inline chain resolved):')
print(f'  samples=$total samples_summed={total}')
print()
for sym, count in sorted(totals.items(), key=lambda x: -x[1])[:$TOP_N]:
    pct = 100.0 * count / total
    print(f'  {count:5d}  {pct:5.1f}%  {sym[:95]}')
"
