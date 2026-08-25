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

# Static archives keep names in the ELF/Mach-O symbol table; `strings` on the
# .a often misses them. Prefer nm, then llvm-nm, then strings.
symtab=""
if command -v nm >/dev/null 2>&1; then
  symtab="$(nm -g "$FILE" 2>/dev/null || nm "$FILE" 2>/dev/null || true)"
fi
if [ -z "$symtab" ] && command -v llvm-nm >/dev/null 2>&1; then
  symtab="$(llvm-nm -g "$FILE" 2>/dev/null || true)"
fi
if [ -z "$symtab" ]; then
  symtab="$(strings -a "$FILE" 2>/dev/null || strings "$FILE" 2>/dev/null || true)"
fi

missing=0
for sym in "${REQUIRED[@]}"; do
  if ! printf '%s\n' "$symtab" | grep -Eq " (_)?${sym}$"; then
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
