#!/usr/bin/env bash
# Fetch Path A STWO muslc into DEST. Do not rebuild rust; do not copy from a dirty tree.
# Pins for 4.0.0-zk muslc rebuilt 2026-09-29 from wasmvm e799f70
# and CosmWasm 5f141e70 (stack limiter + CallDepthExceeded).
# Built with terpnetwork/zk-alpine-builder:4.0.0-zk.
# Do not reuse 892b623f / 4adc7b3c or the 2026-09-25 0500dd2e / 963ba7d9 pins.
set -euo pipefail
DEST="${1:-}"
if [ -z "$DEST" ]; then
  echo "usage: fetch_zk_muslc.sh <dest-dir>" >&2
  exit 2
fi
BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v4.0.0-zk}"
AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-ec9afa36668bcdccbfce99d7529a59556403f0456a5fe00b898a05c19dd7b06c}"
X86_SHA="${WASMVM_MUSLC_X86_SHA:-927ce262d5e06735f77cd304e48e15c003c00ec93b57b5fbc277ad319010e771}"
mkdir -p "$DEST"
sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
fetch_one() {
  local arch="$1" want="$2"
  local name="libwasmvm_muslc.${arch}.a"
  local out="$DEST/$name"
  echo "fetch muslc $name from $BASE/"
  curl -fsSL -o "$out" "$BASE/$name"
  local got
  got="$(sha256_file "$out")"
  if [ "$got" != "$want" ]; then
    echo "ERROR: $name sha256=$got want=$want" >&2
    exit 1
  fi
  if ! grep -a -q -F 'stwo: Dummy DSTW rejected' "$out"; then
    echo "ERROR: $name missing Path A STWO host (proof_instance_verify)" >&2
    exit 1
  fi
  if ! grep -a -q -F 'CallDepthExceeded' "$out"; then
    echo "ERROR: $name missing CallDepthExceeded (muslc predates the call-depth cap)" >&2
    exit 1
  fi
  echo "OK $name $got"
}
fetch_one aarch64 "$AARCH64_SHA"
fetch_one x86_64 "$X86_SHA"
