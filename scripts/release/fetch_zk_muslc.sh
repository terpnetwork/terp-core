#!/usr/bin/env bash
# Fetch Path A STWO muslc into DEST. Do not rebuild rust; do not copy from a dirty tree.
# Pins for 4.0.0-zk muslc rebuilt 2026-10-13 in terpnetwork/zk-alpine-builder:4.0.0-zk
# from libwasmvm 10e7f662 (ruzstd 0.9.1, nam-wasm-instrument fa6735f).
# Do not reuse 4816a928 / b46a403c (ruzstd 0.9.0) or 3cb0e887 / c5d5dec1.
set -euo pipefail
DEST="${1:-}"
if [ -z "$DEST" ]; then
  echo "usage: fetch_zk_muslc.sh <dest-dir>" >&2
  exit 2
fi
BASE="${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v4.0.0-zk}"
AARCH64_SHA="${WASMVM_MUSLC_AARCH64_SHA:-4742d0c7758ee91bda4dd348d995115fe01e5e5dcefb9224b7670c9422a08fb9}"
X86_SHA="${WASMVM_MUSLC_X86_SHA:-34413179b94018383d664a547a25ff73a9a1f1152382a5155798eecaaecd9fcf}"
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
