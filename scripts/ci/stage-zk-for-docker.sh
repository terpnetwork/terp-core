#!/usr/bin/env bash
# Stage zk muslc + Go forks so `docker build --build-arg WASMVM_SOURCE=local` works
# on a fresh terp-core clone (crates/ is gitignored).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
BASE="${WASMVM_BASE_URL:-https://minio.terp.network/releases/zk-wasmvm}"
VER="$(awk '/^[[:space:]]*github.com\/CosmWasm\/wasmvm\/v3/ && !/=>/ {print $2; exit}' go.mod)"
# These refs must exist on origin. A local-only branch name will fail CI.
WASMD_REPO="${WASMD_REPO:-https://github.com/permissionlessweb/wasmd.git}"
WASMD_REF="${WASMD_REF:-merge/upstream-wasmd-v0.70}"
WASMVM_REPO="${WASMVM_REPO:-https://github.com/permissionlessweb/wasmvm.git}"
ARCH="${WASMVM_ARCH:-x86_64}"
# ibc-hooks-v11: git tree or in-repo tarball. MinIO only if IBC_HOOKS_ALLOW_FETCH=1.

if [ -z "$VER" ]; then
  echo "ERROR: could not parse wasmvm version from go.mod" >&2
  exit 1
fi

echo "==> preflight remote refs (wasmvm=$VER wasmd=$WASMD_REF)"
git ls-remote --exit-code --heads "$WASMVM_REPO" "$VER" >/dev/null
git ls-remote --exit-code --heads "$WASMD_REPO" "$WASMD_REF" >/dev/null

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
  echo "==> clone $WASMVM_REPO @$VER"
  rm -rf build/zk-deps/zk-wasmvm
  git clone --depth 1 --branch "$VER" "$WASMVM_REPO" build/zk-deps/zk-wasmvm
fi
if [ ! -f build/zk-deps/zk-wasmd/go.mod ]; then
  echo "==> clone $WASMD_REPO @$WASMD_REF"
  rm -rf build/zk-deps/zk-wasmd
  git clone --depth 1 --branch "$WASMD_REF" "$WASMD_REPO" build/zk-deps/zk-wasmd
fi
if [ ! -f build/zk-deps/ibc-hooks-v11/go.mod ]; then
  echo "==> resolve ibc-hooks-v11 (git-locked, not a floating MinIO object)"
  hooks_dir="$(bash "$ROOT/scripts/ci/resolve-ibc-hooks.sh")"
  rm -rf build/zk-deps/ibc-hooks-v11
  mkdir -p build/zk-deps/ibc-hooks-v11
  rsync -a --delete --exclude='.git/' "$hooks_dir/" build/zk-deps/ibc-hooks-v11/
fi
mkdir -p build/zk-deps/zk-wasmvm/internal/api
cp -f "build/wasmvm/libwasmvm_muslc.$ARCH.a" \
  "build/zk-deps/zk-wasmvm/internal/api/libwasmvm_muslc.$ARCH.a"
echo "==> staged"
ls -lh "build/wasmvm/libwasmvm_muslc.$ARCH.a"
test -f build/zk-deps/zk-wasmvm/go.mod
test -f build/zk-deps/zk-wasmd/go.mod
test -f build/zk-deps/ibc-hooks-v11/go.mod
if ! grep -q "const CircuitKeyLen" build/zk-deps/zk-wasmvm/lib.go; then
  echo "ERROR: staged wasmvm has no CircuitKeyLen (origin/v3.0.7-zk is behind local 5aab589+)." >&2
  exit 1
fi
if ! grep -a -q -F 'stwo: Dummy DSTW rejected' "build/wasmvm/libwasmvm_muslc.$ARCH.a"; then
  echo "ERROR: muslc missing Path A STWO host — MinIO/object is older than Go bindings (need alpine-custom rebuild, not August artifacts)." >&2
  exit 1
fi
