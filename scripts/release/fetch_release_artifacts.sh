#!/usr/bin/env bash
# Download a tagged release pack from MinIO/S3. Does not compile.
# Layout: $HOST/releases/terp-core/<tag>/
set -euo pipefail
TAG="${1:-${RELEASE_TAG:-v6.0.0}}"
DEST="${2:-${DEST:-/tmp/terp-release-$TAG}}"
HOST="${PREBUILT_HOST:-https://s3.terp.network}"
BASE="${HOST}/releases/terp-core/${TAG}"
VER="${TAG#v}"
mkdir -p "$DEST"
echo "==> fetch $BASE"
curl -fsSL -o "$DEST/sha256sum.txt" "$BASE/sha256sum.txt"
curl -fsSL -o "$DEST/SOURCE_DEPS.txt" "$BASE/SOURCE_DEPS.txt"
curl -fsSL -o "$DEST/binaries.json" "$BASE/binaries.json"
curl -fsSL -o "$DEST/terpd-linux-amd64" "$BASE/terpd-linux-amd64"
curl -fsSL -o "$DEST/terpd-linux-arm64" "$BASE/terpd-linux-arm64"
curl -fsSL -o "$DEST/terpd-${VER}-linux-amd64.tar.gz" "$BASE/terpd-${VER}-linux-amd64.tar.gz"
curl -fsSL -o "$DEST/terpd-${VER}-linux-arm64.tar.gz" "$BASE/terpd-${VER}-linux-arm64.tar.gz"
chmod +x "$DEST/terpd-linux-amd64" "$DEST/terpd-linux-arm64"
if curl -fsSL -o "$DEST/terp-core-local-linux-amd64.tar.sha256" "$BASE/terp-core-local-linux-amd64.tar.sha256"; then
  curl -fsSL -o "$DEST/terp-core-local-linux-amd64.tar" "$BASE/terp-core-local-linux-amd64.tar"
fi
echo "ok $DEST"
