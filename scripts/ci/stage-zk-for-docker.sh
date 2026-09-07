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
# crates/ibc-hooks-v11 is gitignored (crates/*). Prefer HOOKS_SRC (local tree).
# Until it is a submodule, fetch a pinned tarball (not a floating v6.0.0-dev object).
HOOKS_SRC="${HOOKS_SRC:-$ROOT/crates/ibc-hooks-v11}"
HOOKS_URL="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"
HOOKS_SHA256="${IBC_HOOKS_SHA256:-1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312}"

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
  rm -rf build/zk-deps/ibc-hooks-v11
  if [ -f "$HOOKS_SRC/go.mod" ]; then
    echo "==> stage ibc-hooks-v11 from HOOKS_SRC=$HOOKS_SRC"
    mkdir -p build/zk-deps/ibc-hooks-v11
    rsync -a --delete --exclude='.git/' "$HOOKS_SRC/" build/zk-deps/ibc-hooks-v11/
  else
    echo "==> fetch ibc-hooks-v11 tarball (sha256 pin $HOOKS_SHA256)"
    curl -fsSL -o /tmp/ibc-hooks-v11.tar.gz "$HOOKS_URL"
    got="$(shasum -a 256 /tmp/ibc-hooks-v11.tar.gz | awk '{print $1}')"
    if [ "$got" != "$HOOKS_SHA256" ]; then
      echo "ERROR: ibc-hooks-v11 tarball checksum $got != $HOOKS_SHA256" >&2
      echo "Set HOOKS_SRC to a local store/v2-patched tree, or IBC_HOOKS_URL + IBC_HOOKS_SHA256." >&2
      exit 1
    fi
    tar -C build/zk-deps -xzf /tmp/ibc-hooks-v11.tar.gz
  fi
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
