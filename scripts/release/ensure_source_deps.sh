#!/usr/bin/env bash
# Populate go.mod path-replaces (zk-wasmd, zk-wasmvm, ibc-hooks-v11)
# so `make install` / CI `go build ./...` work after a plain `git clone`.
#
# Do NOT init crates/cosmwasm here. That tree is Cargo plus packages/go-gen
# fixtures that are not valid Go (no package clause). Nested under this
# module they make `go build ./...` fail with:
#   expected 'package', found 'type'
# CosmWasm is optional (ENSURE_COSMWASM=1). terpd links libwasmvm via zk-wasmvm.
#
# Pins: scripts/release/SOURCE_DEPS.txt (same SHAs as the v6.0.0 release pack).
# Skip: SKIP_SOURCE_DEPS=1
set -euo pipefail

if [ "${SKIP_SOURCE_DEPS:-0}" = "1" ]; then
  echo "ensure-source-deps: SKIP_SOURCE_DEPS=1"
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DEPS_FILE="${SOURCE_DEPS_FILE:-$ROOT/scripts/release/SOURCE_DEPS.txt}"

need_gomod() {
  [ -f "$1/go.mod" ]
}

need_cosmwasm() {
  [ -f "$1/Cargo.toml" ] || [ -f "$1/packages/std/Cargo.toml" ]
}

pin_sha() {
  local name="$1"
  awk -v n="$name" '$1==n {print $NF; exit}' "$DEPS_FILE"
}

pin_url() {
  local name="$1"
  awk -v n="$name" '$1==n {print $2; exit}' "$DEPS_FILE"
}

pin_ref() {
  local name="$1"
  awk -v n="$name" '$1==n {print $3; exit}' "$DEPS_FILE"
}

checkout_sha() {
  local dest="$1" url="$2" sha="$3" ref="${4:-}"
  if need_gomod "$dest"; then
    local cur
    cur="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$cur" ] && [ "$cur" = "$sha" ]; then
      echo "ensure-source-deps: $dest already at $sha"
      return 0
    fi
    if [ -n "$cur" ] && [ -n "$sha" ]; then
      echo "ensure-source-deps: $dest at $cur (want $sha); fetching pin"
      git -C "$dest" fetch --depth 1 origin "$sha" 2>/dev/null || git -C "$dest" fetch origin "$sha" || true
      git -C "$dest" checkout --detach "$sha" 2>/dev/null && return 0
    fi
    if need_gomod "$dest"; then
      echo "ensure-source-deps: WARN $dest present but not at $sha; using existing tree"
      return 0
    fi
  fi

  echo "ensure-source-deps: clone $url @ $sha -> $dest"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  if [ -n "$ref" ] && git clone --filter=blob:none --branch "$ref" --single-branch "$url" "$dest" 2>/dev/null; then
    git -C "$dest" checkout --detach "$sha" 2>/dev/null || git -C "$dest" checkout "$sha"
  else
    git clone --filter=blob:none "$url" "$dest"
    git -C "$dest" fetch --depth 1 origin "$sha" 2>/dev/null || git -C "$dest" fetch origin "$sha"
    git -C "$dest" checkout --detach "$sha"
  fi
  need_gomod "$dest" || {
    echo "ERROR: $dest missing go.mod after checkout $sha" >&2
    exit 1
  }
}

# ibc-hooks lives in cosmos/ibc-apps (monorepo). Do not vendor it in terp-core;
# clone the pin and copy modules/ibc-hooks into the go.mod replace path.
checkout_ibc_hooks() {
  local dest="$1" url="$2" sha="$3" ref="${4:-}" subdir="${5:-modules/ibc-hooks}"
  if need_gomod "$dest"; then
    echo "ensure-source-deps: $dest already present"
    return 0
  fi
  echo "ensure-source-deps: clone $url @ $sha ($subdir) -> $dest"
  local tmp
  tmp="$(mktemp -d)"
  if [ -n "$ref" ] && git clone --filter=blob:none --branch "$ref" --single-branch "$url" "$tmp" 2>/dev/null; then
    git -C "$tmp" checkout --detach "$sha" 2>/dev/null || git -C "$tmp" checkout "$sha"
  else
    git clone --filter=blob:none "$url" "$tmp"
    git -C "$tmp" fetch --depth 1 origin "$sha" 2>/dev/null || git -C "$tmp" fetch origin "$sha"
    git -C "$tmp" checkout --detach "$sha"
  fi
  if [ ! -f "$tmp/$subdir/go.mod" ]; then
    echo "ERROR: $url @ $sha missing $subdir/go.mod" >&2
    rm -rf "$tmp"
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  cp -a "$tmp/$subdir" "$dest"
  rm -rf "$tmp"
  need_gomod "$dest" || {
    echo "ERROR: $dest missing go.mod after checkout" >&2
    exit 1
  }
}

echo "ensure-source-deps: using $DEPS_FILE"

if [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ]; then
  echo "ensure-source-deps: git submodule update --init (zk-wasmd, zk-wasmvm)"
  git -C "$ROOT" submodule update --init --depth 1 -- crates/zk-wasmd crates/zk-wasmvm || true
fi

WASMD_SHA="$(pin_sha wasmd)"
WASMVM_SHA="$(pin_sha wasmvm)"
WASMD_URL="$(pin_url wasmd)"
WASMVM_URL="$(pin_url wasmvm)"

need_gomod crates/zk-wasmd || checkout_sha crates/zk-wasmd "$WASMD_URL" "$WASMD_SHA" "merge/upstream-wasmd-v0.70"
need_gomod crates/zk-wasmvm || checkout_sha crates/zk-wasmvm "$WASMVM_URL" "$WASMVM_SHA" "v3.0.7-zk"

if [ "${ENSURE_COSMWASM:-0}" = "1" ]; then
  COSMWASM_SHA="$(pin_sha cosmwasm)"
  COSMWASM_URL="$(pin_url cosmwasm)"
  git -C "$ROOT" submodule update --init --depth 1 -- crates/cosmwasm || true
  if ! need_cosmwasm crates/cosmwasm; then
    echo "ensure-source-deps: WARN crates/cosmwasm not checked out"
  fi
fi

# Overlay release muslc (ZK FFI) and drop stale glibc shared objects.
# Default `go build` on Linux links -lwasmvm.x86_64; that .so at the wasmvm
# git pin is stock CosmWasm. Linux builds must use -tags muslc + these .a files.
install_muslc() {
  local name="$1" dest="$2"
  local url sha tmp got
  url="$(pin_url "$name")"
  sha="$(pin_sha "$name")"
  [ -n "$url" ] && [ -n "$sha" ] || {
    echo "ERROR: no SOURCE_DEPS pin for $name" >&2
    exit 1
  }
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp)"
  echo "ensure-source-deps: fetch $name"
  curl -fsSL -o "$tmp" "$url"
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$sha" ]; then
    echo "ERROR: $name checksum $got != $sha" >&2
    exit 1
  fi
  mv "$tmp" "$dest"
  bash "$ROOT/scripts/release/libwasmvm_assert_zk.sh" "$dest"
}

if need_gomod crates/zk-wasmvm; then
  install_muslc wasmvm-muslc-x86_64 crates/zk-wasmvm/internal/api/libwasmvm_muslc.x86_64.a
  install_muslc wasmvm-muslc-aarch64 crates/zk-wasmvm/internal/api/libwasmvm_muslc.aarch64.a
  for so in crates/zk-wasmvm/internal/api/libwasmvm.x86_64.so \
            crates/zk-wasmvm/internal/api/libwasmvm.aarch64.so; do
    if [ -f "$so" ] && ! bash "$ROOT/scripts/release/libwasmvm_assert_zk.sh" "$so" >/dev/null 2>&1; then
      echo "ensure-source-deps: removing stale $so (use muslc .a + -tags muslc on Linux)"
      rm -f "$so"
    fi
  done
  if [ "$(uname -s)" = Darwin ] && [ -f crates/zk-wasmvm/internal/api/libwasmvm.dylib ]; then
    bash "$ROOT/scripts/release/libwasmvm_assert_zk.sh" crates/zk-wasmvm/internal/api/libwasmvm.dylib \
      || echo "ensure-source-deps: WARN dylib missing ZK symbols"
  fi
fi

need_gomod crates/ibc-hooks-v11 || checkout_ibc_hooks \
  crates/ibc-hooks-v11 \
  "$(pin_url ibc-hooks)" \
  "$(pin_sha ibc-hooks)" \
  "$(pin_ref ibc-hooks)" \
  modules/ibc-hooks

echo "ensure-source-deps: ok"
echo "  zk-wasmd       $(git -C crates/zk-wasmd rev-parse --short HEAD 2>/dev/null || echo present)"
echo "  zk-wasmvm      $(git -C crates/zk-wasmvm rev-parse --short HEAD 2>/dev/null || echo present)"
echo "  cosmwasm       $(git -C crates/cosmwasm rev-parse --short HEAD 2>/dev/null || echo skipped)"
echo "  ibc-hooks-v11  $(test -f crates/ibc-hooks-v11/go.mod && echo present)"
