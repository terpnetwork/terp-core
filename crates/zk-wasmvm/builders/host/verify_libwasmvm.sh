#!/usr/bin/env bash
# Fail if internal/api is a mixed-generation set (the 4.0.0-zk trip:
# muslc .a recut, glibc .so still 3.0.7 → Linux go test undefined store_param).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API="$ROOT/internal/api"

need() {
  [ -f "$API/$1" ] || { echo "ERROR: missing $API/$1 — make release-build" >&2; exit 1; }
}

need libwasmvm_muslc.x86_64.a
need libwasmvm_muslc.aarch64.a
need libwasmvm.x86_64.so
need libwasmvm.aarch64.so
need libwasmvm.dylib

for f in libwasmvm_muslc.x86_64.a libwasmvm_muslc.aarch64.a; do
  grep -a -q -F store_code_with_circuit "$API/$f" \
    || { echo "ERROR: $f missing store_code_with_circuit" >&2; exit 1; }
  grep -a -q -F 'stwo: Dummy DSTW rejected' "$API/$f" \
    || { echo "ERROR: $f missing Path A DSTW reject" >&2; exit 1; }
  grep -a -q -F store_param "$API/$f" \
    || { echo "ERROR: $f missing store_param (not 4.0.0-zk)" >&2; exit 1; }
  echo "OK muslc $f"
done

for f in libwasmvm.x86_64.so libwasmvm.aarch64.so; do
  grep -a -q -F store_param "$API/$f" \
    || { echo "ERROR: $f is stale (no store_param). Ran muslc only? make release-build-linux" >&2; exit 1; }
  echo "OK glibc $f"
done

grep -a -q -F store_param "$API/libwasmvm.dylib" \
  || { echo "ERROR: libwasmvm.dylib missing store_param — make release-build-macos" >&2; exit 1; }
echo "OK darwin libwasmvm.dylib"

echo "==> sha256"
if command -v sha256sum >/dev/null; then
  (cd "$API" && sha256sum libwasmvm_muslc.x86_64.a libwasmvm_muslc.aarch64.a libwasmvm.x86_64.so libwasmvm.aarch64.so libwasmvm.dylib)
else
  (cd "$API" && shasum -a 256 libwasmvm_muslc.x86_64.a libwasmvm_muslc.aarch64.a libwasmvm.x86_64.so libwasmvm.aarch64.so libwasmvm.dylib)
fi
echo "OK libwasmvm artifacts are one generation (4.0.0-zk FFI)"
