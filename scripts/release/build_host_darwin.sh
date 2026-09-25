#!/usr/bin/env bash
# Host darwin/arm64 terpd for the public installer.
# Same step as linux `make create-binaries` on a Darwin builder — not a sidecar job.
#
# Links crates/zk-wasmvm/internal/api/libwasmvmstatic_darwin.a (`static_wasm`)
# so the ELF does not rpath libwasmvm.dylib to this clone.
#
#   RELEASE_TAG=v6.0.1 ./scripts/release/build_host_darwin.sh
#   make create-binaries   # calls this on Darwin after linux docker ELFs
set -euo pipefail
ROOT="${BUILD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "ERROR: darwin/arm64 host required (got $(uname -s)/$(uname -m))" >&2
  exit 1
fi

TAG="${RELEASE_TAG:-${TAG:-}}"
if [ -z "$TAG" ]; then
  echo "ERROR: set RELEASE_TAG=vX.Y.Z" >&2
  exit 1
fi
if ! echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: RELEASE_TAG must be vX.Y.Z (got '$TAG')" >&2
  exit 1
fi
VER="${TAG#v}"
COMMIT="$(git rev-parse HEAD)"
STATIC_A="$ROOT/crates/zk-wasmvm/internal/api/libwasmvmstatic_darwin.a"
if [ ! -f "$STATIC_A" ]; then
  echo "ERROR: missing $STATIC_A" >&2
  echo "Build it with: crates/zk-wasmvm/builders/host/build_macos_static_arm64.sh" >&2
  exit 1
fi
if command -v lipo >/dev/null; then
  info="$(lipo -info "$STATIC_A" 2>/dev/null || true)"
  echo "$info" | grep -q arm64 || {
    echo "ERROR: $STATIC_A is not arm64 ($info)" >&2
    exit 1
  }
fi

GO_MODULE="$(awk '/^module /{print $2; exit}' go.mod)"
mkdir -p "$ROOT/build"
OUT="$ROOT/build/terpd-darwin-arm64"

ldflags="-X github.com/cosmos/cosmos-sdk/version.Name=terp-core"
ldflags="$ldflags -X github.com/cosmos/cosmos-sdk/version.AppName=terpd"
ldflags="$ldflags -X github.com/cosmos/cosmos-sdk/version.Version=${VER}"
ldflags="$ldflags -X github.com/cosmos/cosmos-sdk/version.Commit=${COMMIT}"
ldflags="$ldflags -X github.com/cosmos/cosmos-sdk/version.BuildTags=netgo,ledger,static_wasm"

echo "==> darwin/arm64 static wasmvm  TAG=$TAG COMMIT=$COMMIT"
GOWORK=off CGO_ENABLED=1 go build -mod=mod \
  -tags "netgo ledger static_wasm" \
  -ldflags "$ldflags" \
  -o "$OUT" \
  "${GO_MODULE}/cmd/terpd"

if otool -L "$OUT" | grep -q libwasmvm.dylib; then
  echo "ERROR: $OUT still links libwasmvm.dylib" >&2
  otool -L "$OUT" >&2
  exit 1
fi
got="$("$OUT" version 2>/dev/null | head -1 | tr -d '[:space:]')"
if [ "$got" != "$VER" ]; then
  echo "ERROR: $OUT version='$got' want '$VER'" >&2
  exit 1
fi
echo "ok $OUT  version=$got  (no libwasmvm.dylib)"
