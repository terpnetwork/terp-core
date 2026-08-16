#!/usr/bin/env bash
# Stage zk muslc + Go forks so `docker build --build-arg WASMVM_SOURCE=local` works
# on a fresh terp-core clone (crates/ is gitignored).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
BASE="${WASMVM_BASE_URL:-https://minio.terp.network/releases/zk-wasmvm}"
VER="$(awk '/^[[:space:]]*github.com\/CosmWasm\/wasmvm\/v3/ && !/=>/ {print $2; exit}' go.mod)"
ARCH="${WASMVM_ARCH:-x86_64}"
HOOKS_URL="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"

mkdir -p build/wasmvm build/zk-deps
echo "==> muslc $VER $ARCH from $BASE"
curl -fsSL -o "build/wasmvm/libwasmvm_muslc.$ARCH.a" "$BASE/$VER/libwasmvm_muslc.$ARCH.a"
curl -fsSL -o /tmp/SHA256SUMS.zk "$BASE/$VER/SHA256SUMS"
got="$(shasum -a 256 "build/wasmvm/libwasmvm_muslc.$ARCH.a" | awk '{print $1}')"
want="$(awk -v a="$ARCH" '$2 ~ a {print $1; exit}' /tmp/SHA256SUMS.zk)"
if [ "$got" != "$want" ]; then
  echo "ERROR: muslc checksum $got != $want" >&2
  exit 1
fi

if [ ! -f build/zk-deps/zk-wasmvm/go.mod ]; then
  echo "==> clone permissionlessweb/wasmvm @$VER"
  rm -rf build/zk-deps/zk-wasmvm
  git clone --depth 1 --branch "$VER" https://github.com/permissionlessweb/wasmvm.git build/zk-deps/zk-wasmvm
fi
if [ ! -f build/zk-deps/zk-wasmd/go.mod ]; then
  echo "==> clone permissionlessweb/wasmd"
  rm -rf build/zk-deps/zk-wasmd
  git clone --depth 1 --branch merge/upstream-wasmd-v0.70 https://github.com/permissionlessweb/wasmd.git build/zk-deps/zk-wasmd
fi
if [ ! -f build/zk-deps/ibc-hooks-v11/go.mod ]; then
  echo "==> fetch ibc-hooks-v11 tarball"
  rm -rf build/zk-deps/ibc-hooks-v11
  curl -fsSL -o /tmp/ibc-hooks-v11.tar.gz "$HOOKS_URL"
  tar -C build/zk-deps -xzf /tmp/ibc-hooks-v11.tar.gz
fi
cp -f "build/wasmvm/libwasmvm_muslc.$ARCH.a"
  "build/zk-deps/zk-wasmvm/internal/api/libwasmvm_muslc.$ARCH.a" 2>/dev/null || true
echo "==> staged"
ls -lh "build/wasmvm/libwasmvm_muslc.$ARCH.a"
test -f build/zk-deps/zk-wasmvm/go.mod
test -f build/zk-deps/zk-wasmd/go.mod
test -f build/zk-deps/ibc-hooks-v11/go.mod
