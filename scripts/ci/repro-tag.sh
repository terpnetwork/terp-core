#!/usr/bin/env bash
# Proactive bit-for-bit checks for a release tag.
# - muslc sha256 must match ARTIFACT_LOCK / fetch_zk_muslc.sh
# - go.mod hasher replaces present
# - linux amd64 terpd build (muslc) hashes printed; compared if LOCK has a row
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

LOCK_A="${LOCK_A:-$ROOT/networks/upgrades/v6.3/ARTIFACT_LOCK}"
LOCK_B="${LOCK_B:-$ROOT/networks/upgrades/v6.4/ARTIFACT_LOCK}"
MUSLC_X86="$ROOT/crates/zk-wasmvm/internal/api/libwasmvm_muslc.x86_64.a"
MUSLC_ARM="$ROOT/crates/zk-wasmvm/internal/api/libwasmvm_muslc.aarch64.a"

./scripts/release/curate_v63.sh

eval "$(python3 - <<'PY'
import re
from pathlib import Path
t = Path("scripts/release/fetch_zk_muslc.sh").read_text()
x = re.search(r'WASMVM_MUSLC_X86_SHA:-\s*([0-9a-f]{64})', t)
a = re.search(r'WASMVM_MUSLC_AARCH64_SHA:-\s*([0-9a-f]{64})', t)
if not x or not a:
    raise SystemExit("ERROR: parse muslc SHAs")
print(f"want_x86={x.group(1)}")
print(f"want_arm={a.group(1)}")
PY
)"
[ -n "${want_x86:-}" ] && [ -n "${want_arm:-}" ] || { echo "ERROR: parse muslc SHAs"; exit 1; }

check_a() {
  local f="$1" want="$2" label="$3"
  [ -f "$f" ] || { echo "ERROR: missing $label $f"; exit 1; }
  got="$(shasum -a 256 "$f" | awk '{print $1}')"
  echo "$label $got"
  [ "$got" = "$want" ] || { echo "ERROR: $label want $want"; exit 1; }
}
check_a "$MUSLC_X86" "$want_x86" libwasmvm_muslc.x86_64.a
check_a "$MUSLC_ARM" "$want_arm" libwasmvm_muslc.aarch64.a
grep -a -q -F 'stwo: Dummy DSTW rejected' "$MUSLC_X86" \
  || { echo "ERROR: muslc missing Path A DSTW reject string"; exit 1; }

for lock in "$LOCK_A" "$LOCK_B"; do
  [ -f "$lock" ] || continue
  grep -q "$want_x86" "$lock" || { echo "ERROR: $lock missing x86 muslc sha"; exit 1; }
  grep -q "$want_arm" "$lock" || { echo "ERROR: $lock missing arm muslc sha"; exit 1; }
  echo "OK lock $lock muslc pins"
done

if [ "${REPRO_BUILD_TERPD:-1}" = "1" ]; then
  echo "==> go build -tags muslc linux (this host may not be linux; skip if not)"
  if [ "$(uname -s)" = Linux ]; then
    go build -tags muslc -o /tmp/terpd-repro ./cmd/terpd
    sha="$(shasum -a 256 /tmp/terpd-repro | awk '{print $1}')"
    echo "terpd-linux-local $sha"
    if grep -qE '^[0-9a-f]{64}  terpd-linux-amd64$' "$LOCK_A" 2>/dev/null; then
      locksha="$(awk '/terpd-linux-amd64$/{print $1}' "$LOCK_A")"
      if [ "$(uname -m)" = x86_64 ] && [ -n "$locksha" ]; then
        [ "$sha" = "$locksha" ] || { echo "ERROR: terpd sha $sha != lock $locksha"; exit 1; }
      fi
    else
      echo "OK ARTIFACT_LOCK terpd row still TBD (print-only)"
    fi
  else
    echo "skip terpd linux build on $(uname -s)"
  fi
fi
echo "OK repro-tag muslc + hasher packaging"
