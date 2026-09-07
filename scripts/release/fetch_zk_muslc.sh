#!/usr/bin/env bash
# Fetch Path A STWO muslc into DEST. Do not rebuild rust; do not copy from a dirty tree.
# Pins match minio.terp.network/releases/zk-wasmvm/v3.0.7-zk/SHA256SUMS (linked into v6.1.0/v6.2.0).
set -euo pipefail
DEST="${1:-}"
if [ -z "$DEST" ]; then
  echo "usage: fetch_zk_muslc.sh <dest-dir>" >&2
  exit 2
fi
BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v3.0.7-zk}"
AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-0687e59140c967a752b0b0ede98e71a3c859fb4f6b94fc26883792d381eb4716}"
X86_SHA="${WASMVM_MUSLC_X86_SHA:-4f4880e1655d34c098729df52db22c9253bec87d2b3185669ff015a340b76d49}"
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
