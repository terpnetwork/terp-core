#!/usr/bin/env bash
# Collect every libwasmvm artifact we ship with a ZK-tagged terpd, write
# SHA256SUMS + VERSIONS.txt so CheckLibwasmVersion can match without
# --wasm.skip_wasmvm_version_check.
#
# Rust CARGO_PKG_VERSION must be a substring of the Go wasmvm module version
# (see zk-wasmd x/wasm CheckLibwasmVersion). Path replaces report "(devel)"
# which the check already accepts. Tagged releases must use a Go version
# that contains the rust string, e.g. rust 3.0.7-zk <-> go v3.0.7-zk.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ZK="${ZK_WASMVM_DIR:-$ROOT/crates/zk-wasmvm}"
OUT="${WASMVM_ARTIFACT_DIR:-$ROOT/build/wasmvm-release}"

mkdir -p "$OUT"
rm -f "$OUT"/libwasmvm* "$OUT"/SHA256SUMS "$OUT"/VERSIONS.txt

copied=0
for dir in "$ZK/internal/api" "$ZK/libwasmvm/artifacts"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/libwasmvm*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    # prefer internal/api (post update-bindings) over stale artifacts/
    if [ -e "$OUT/$base" ]; then
      continue
    fi
    cp -f "$f" "$OUT/$base"
    copied=$((copied + 1))
  done
done

if [ "$copied" -eq 0 ]; then
  echo "ERROR: no libwasmvm artifacts under $ZK" >&2
  exit 1
fi

# Prefer ZK muslc we just built (has store_code_with_circuit)
if command -v strings >/dev/null && ! strings "$OUT"/libwasmvm_muslc.aarch64.a 2>/dev/null | grep -q store_code_with_circuit; then
  echo "WARN: libwasmvm_muslc.aarch64.a missing store_code_with_circuit (not a ZK muslc)" >&2
fi

(
  cd "$OUT"
  if command -v sha256sum >/dev/null; then
    sha256sum libwasmvm* | sort > SHA256SUMS
  else
    shasum -a 256 libwasmvm* | sort > SHA256SUMS
  fi
)

rust_ver="$(awk -F'"' '/^version = /{print $2; exit}' "$ZK/libwasmvm/Cargo.toml")"
go_ver="$(awk '!/^[[:space:]]*\/\// && /github.com\/CosmWasm\/wasmvm/ && !/=>/ {print $2; exit}' "$ROOT/go.mod")"
{
  echo "rust_crate_version=$rust_ver"
  echo "go_mod_require=$go_ver"
  echo "note=CheckLibwasmVersion: rust version must be a substring of the Go module version"
  echo "note=path replace ./crates/zk-wasmvm reports (devel) and the check is a no-op"
} > "$OUT/VERSIONS.txt"

if [ -z "$rust_ver" ] || [ -z "$go_ver" ]; then
  echo "ERROR: missing rust ($rust_ver) or go ($go_ver) version" >&2
  exit 1
fi
if ! printf '%s' "$go_ver" | grep -q -F "$rust_ver"; then
  echo "ERROR: rust $rust_ver is not a substring of go $go_ver" >&2
  echo "       CheckLibwasmVersion fails on tagged builds (path-replace is (devel) only)." >&2
  exit 1
fi
echo "OK: rust $rust_ver is a substring of go $go_ver"

echo "==> curated $copied artifacts in $OUT"
ls -lh "$OUT"
echo "==> VERSIONS"
cat "$OUT/VERSIONS.txt"
echo "==> SHA256SUMS"
cat "$OUT/SHA256SUMS"
