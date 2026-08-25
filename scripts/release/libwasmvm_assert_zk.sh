#!/usr/bin/env bash
# Fail if a libwasmvm .so/.dylib/.a does not export the ZK FFI the Go bindings call.
# Used by ensure_source_deps, wasmvm-curate, and verify_artifacts.
set -euo pipefail

FILE="${1:?usage: libwasmvm_assert_zk.sh <libwasmvm.* >}"

# Go cgo in crates/zk-wasmvm/internal/api (lib.go, stwo_host.go).
REQUIRED=(
  store_param
  sync_pinned_circuits
  sync_pinned_codes
  verify_stwo_host_proof
)

if [ ! -f "$FILE" ]; then
  echo "ERROR: missing $FILE" >&2
  exit 1
fi

has_sym() {
  local sym="$1" st
  # grep -q closes the pipe early; with pipefail nm's SIGPIPE looks like failure.
  set +o pipefail
  # Defined text/data only (not U). Mach-O prefixes underscore.
  if command -v nm >/dev/null 2>&1; then
    nm -g "$FILE" 2>/dev/null | grep -E " [TDB] ${sym}$| [TDB] _${sym}$" >/dev/null && st=0 || st=1
    if [ "$st" -eq 0 ]; then set -o pipefail; return 0; fi
    nm -gD "$FILE" 2>/dev/null | grep -E " [TDB] ${sym}$| [TDB] _${sym}$" >/dev/null && st=0 || st=1
    if [ "$st" -eq 0 ]; then set -o pipefail; return 0; fi
  fi
  set -o pipefail
  return 1
}

missing=0
for sym in "${REQUIRED[@]}"; do
  if ! has_sym "$sym"; then
    echo "ERROR: $FILE missing ZK symbol $sym" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "ERROR: $FILE is not a ZK libwasmvm (stock CosmWasm shared object is not enough)." >&2
  echo "       Rebuild from crates/zk-wasmvm (same pin as SOURCE_DEPS muslc) or overlay" >&2
  echo "       the muslc archives from releases/zk-wasmvm/<tag>/." >&2
  exit 1
fi
echo "ok zk-ffi $FILE"
