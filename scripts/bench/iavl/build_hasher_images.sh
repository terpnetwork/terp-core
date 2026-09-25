#!/usr/bin/env bash
# One hasher-capable terpd image, then three tags with TERP_IAVL_HASHER baked in.
# Gas/VM e2e can run on this host (arm64 Docker is fine).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
TAG="${TERP_IMAGE_VERSION:-v6.3.0-dev}"
REPO="${IMAGE_REPO:-registry.terp.network/terp-core}"
export TERP_IMAGE_VERSION="$TAG"
export IMAGE_REPO="$REPO"
export WASMVM_SOURCE="${WASMVM_SOURCE:-local}"

echo "==> base $REPO:$TAG (WASMVM_SOURCE=$WASMVM_SOURCE)"
make docker-build-zk TERP_IMAGE_VERSION="$TAG" IMAGE_REPO="$REPO" WASMVM_SOURCE="$WASMVM_SOURCE"

for m in blake3 hybrid sha256; do
  echo "==> tag $REPO:$TAG-$m ENV TERP_IAVL_HASHER=$m"
  docker build -t "$REPO:$TAG-$m" - <<EOF
FROM $REPO:$TAG
ENV TERP_IAVL_HASHER=$m
EOF
done
docker image ls "$REPO" --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep "$TAG" || true
