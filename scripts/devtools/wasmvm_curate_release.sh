#!/bin/bash
set -euo pipefail

# Pack host libs for a wasmvm release without deleting guest fixtures.
# Guest wasm/vk files live in x/wasm/wasmvm/artifacts. Host libs are copied
# beside them. The source archive and checksum file go to build/wasmvm-release.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VM="$ROOT/x/wasm/wasmvm"
GUEST="$VM/artifacts"
OUT="$ROOT/build/wasmvm-release"

mkdir -p "$GUEST" "$OUT"

echo "=== Creating source archives ==="
tar -C "$ROOT" -czf "$OUT/wasmvm-source.tar.gz" \
  --exclude='x/wasm/wasmvm/libwasmvm/target' \
  --exclude='x/wasm/wasmvm/internal/api/*.a' \
  x/wasm/wasmvm

echo "=== Copying compiled libraries (guest fixtures stay) ==="
copy_lib() {
  local name="$1"
  if [ -f "$VM/internal/api/$name" ]; then
    cp -f "$VM/internal/api/$name" "$GUEST/$name"
    cp -f "$VM/internal/api/$name" "$OUT/$name"
  else
    echo "Warning: $name not found"
  fi
}

copy_lib libwasmvm.aarch64.so
copy_lib libwasmvm.dylib
copy_lib libwasmvm.x86_64.so
copy_lib libwasmvm_muslc.aarch64.a
copy_lib libwasmvm_muslc.x86_64.a
if [ ! -f "$VM/internal/api/libwasmvmstatic_darwin.a" ]; then
  echo "ERROR: libwasmvmstatic_darwin.a missing (run builders/host/build_macos_static_arm64.sh)" >&2
  exit 1
fi
copy_lib libwasmvmstatic_darwin.a

echo "=== Generating checksums ==="
(
  cd "$OUT"
  if command -v sha256sum >/dev/null; then
    sha256sum libwasmvm* wasmvm-source.tar.gz > checksums.txt
  else
    shasum -a 256 libwasmvm* wasmvm-source.tar.gz > checksums.txt
  fi
  cat checksums.txt
)

echo "=== Done. Host pack is $OUT. Guest fixtures remain in $GUEST ==="
