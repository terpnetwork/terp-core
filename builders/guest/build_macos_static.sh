#!/bin/bash
set -o errexit -o nounset -o pipefail

export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
export TARGET_DIR="/target" # write to /target in the guest's file system to avoid writing to the host

# ref: https://wapl.es/rust/2019/02/17/rust-cross-compile-linux-to-macos.html
export PATH="/opt/osxcross/target/bin:$PATH"
export LIBZ_SYS_STATIC=1

# No stripping implemented (see https://github.com/CosmWasm/wasmvm/issues/222#issuecomment-2260007943).
#
# Terp: default aarch64 only (darwin-arm64 terpd). UNIVERSAL=1 also builds
# x86_64 and lipo a fat archive.

echo "Starting aarch64-apple-darwin build"
export CC=aarch64-apple-darwin20.4-clang
export CXX=aarch64-apple-darwin20.4-clang++
cargo build --release --target-dir="$TARGET_DIR" --target aarch64-apple-darwin --example wasmvmstatic

ARM_A="$TARGET_DIR/aarch64-apple-darwin/release/examples/libwasmvmstatic.a"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "Starting x86_64-apple-darwin build (UNIVERSAL=1)"
  export CC=o64-clang
  export CXX=o64-clang++
  cargo build --release --target-dir="$TARGET_DIR" --target x86_64-apple-darwin --example wasmvmstatic
  lipo -output artifacts/libwasmvmstatic_darwin.a -create \
    "$TARGET_DIR/x86_64-apple-darwin/release/examples/libwasmvmstatic.a" \
    "$ARM_A"
else
  cp -f "$ARM_A" artifacts/libwasmvmstatic_darwin.a
fi
