#!/usr/bin/env bash
# Fetch Path A STWO muslc into DEST. Do not rebuild rust; do not copy from a dirty tree.
# Pins for 4.0.0-zk muslc recut 2026-09-21 (Path A fail-closed DSTW).
# Built with terpnetwork/zk-alpine-builder:4.0.0-zk (never CosmWasm 0103).
# Do not reuse v3.0.7-zk 0687e591 / 4f4880e1.
# Default BASE is s3/minio releases/zk-wasmvm/v4.0.0-zk/ after publish_zk_wasmvm.sh.
set -euo pipefail
DEST="${1:-}"
if [ -z "$DEST" ]; then
  echo "usage: fetch_zk_muslc.sh <dest-dir>" >&2
  exit 2
fi
BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v4.0.0-zk}"
AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-4adc7b3ca25340a18f38cf313d6cd6d9a8bac0e86cd31799534a04eec1c75ea2}"
X86_SHA="${WASMVM_MUSLC_X86_SHA:-892b623f7a8df2caf40c038461f7a9f9545a381aef3de35c0e4a297f25c98bd7}"
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
  echo "OK $name $got"
}
fetch_one aarch64 "$AARCH64_SHA"
fetch_one x86_64 "$X86_SHA"
