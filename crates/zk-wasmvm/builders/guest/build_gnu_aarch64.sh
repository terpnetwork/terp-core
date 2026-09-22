#!/bin/bash
set -o errexit -o nounset -o pipefail

export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
export TARGET_DIR="/target" # write to /target in the guest's file system to avoid writing to the host

# No stripping implemented (see https://github.com/CosmWasm/wasmvm/issues/222#issuecomment-2260007943).

echo "Starting aarch64-unknown-linux-gnu build"
export qemu_aarch64="qemu-aarch64 -L /usr/aarch64-linux-gnu"
export CC_aarch64_unknown_linux_gnu=clang
# Our debian-nightly installs binutils-aarch64-linux-gnu + libc6-dev-arm64-cross.
# llvm-ar is not always on PATH; fall back to the cross binutils ar.
# clang --sysroot needs /usr/aarch64-linux-gnu/include/assert.h (libc6-dev-arm64-cross).
if command -v llvm-ar >/dev/null; then
  export AR_aarch64_unknown_linux_gnu=llvm-ar
else
  export AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar
fi
if [ ! -f /usr/aarch64-linux-gnu/include/assert.h ]; then
  echo "ERROR: missing aarch64 sysroot headers. Use terpnetwork/zk-debian-builder:4.0.0-zk (not cosmwasm/libwasmvm-builder:0103-debian)." >&2
  exit 1
fi
export CFLAGS_aarch64_unknown_linux_gnu="--sysroot=/usr/aarch64-linux-gnu"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER="$qemu_aarch64"
cargo build --release --target-dir="$TARGET_DIR" --target aarch64-unknown-linux-gnu
cp "$TARGET_DIR/aarch64-unknown-linux-gnu/release/libwasmvm.so" artifacts/libwasmvm.aarch64.so
