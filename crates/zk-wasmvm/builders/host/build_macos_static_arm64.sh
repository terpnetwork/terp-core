#!/usr/bin/env bash
# Native Darwin aarch64 static libwasmvm (no Docker / osxcross).
# Produces internal/api/libwasmvmstatic_darwin.a for `go build -tags static_wasm`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/libwasmvm"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

echo "==> native aarch64-apple-darwin wasmvmstatic (MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
cargo build --release --target aarch64-apple-darwin --example wasmvmstatic

SRC="target/aarch64-apple-darwin/release/examples/libwasmvmstatic.a"
if [ ! -f "$SRC" ]; then
  SRC="target/release/examples/libwasmvmstatic.a"
fi
test -f "$SRC" || {
  echo "ERROR: cargo did not produce libwasmvmstatic.a" >&2
  exit 1
}

mkdir -p "$ROOT/internal/api" "$ROOT/libwasmvm/artifacts"
cp -f "$SRC" "$ROOT/internal/api/libwasmvmstatic_darwin.a"
cp -f "$SRC" "$ROOT/libwasmvm/artifacts/libwasmvmstatic_darwin.a"
if [ -f bindings.h ]; then
  cp -f bindings.h "$ROOT/internal/api/bindings.h"
fi

ls -lh "$ROOT/internal/api/libwasmvmstatic_darwin.a"
echo "==> ok libwasmvmstatic_darwin.a (aarch64)"
