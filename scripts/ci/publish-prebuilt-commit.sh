#!/usr/bin/env bash
# Upload prebuilt terpd + docker image tar for this commit to MinIO.
# Run locally after recure, before opening the release PR.
#   TERPD=... IMAGE_TAR=... scripts/ci/publish-prebuilt-commit.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMIT="${PREBUILT_COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"
COMMIT="$(printf '%s' "$COMMIT" | tr '[:upper:]' '[:lower:]')"
TERPD="${TERPD:?set TERPD to the linux-amd64 terpd binary}"
IMAGE_TAR="${IMAGE_TAR:?set IMAGE_TAR to docker save terpnetwork/terp-core:local}"
MINIO_ALIAS="${MINIO_ALIAS:-usb2}"
DEST="${MINIO_ALIAS}/releases/terp-core/commits/${COMMIT}"
test -f "$TERPD"
test -f "$IMAGE_TAR"
STAGE="$(mktemp -d)"
cp "$TERPD" "$STAGE/terpd-linux-amd64"
sha256sum "$STAGE/terpd-linux-amd64" | awk '{print $1"  terpd-linux-amd64"}' > "$STAGE/terpd-linux-amd64.sha256"
cp "$IMAGE_TAR" "$STAGE/terp-core-local-linux-amd64.tar"
cat > "$STAGE/manifest.json" <<EOF
{"commit":"${COMMIT}","terpd":"terpd-linux-amd64","image":"terp-core-local-linux-amd64.tar"}
EOF
echo "$COMMIT" > "$STAGE/SOURCE_COMMIT"
mc cp "$STAGE/terpd-linux-amd64" "$STAGE/terpd-linux-amd64.sha256" \
  "$STAGE/terp-core-local-linux-amd64.tar" "$STAGE/manifest.json" "$STAGE/SOURCE_COMMIT" \
  "${DEST}/"
echo "published ${DEST}"
echo "public https://minio.terp.network/releases/terp-core/commits/${COMMIT}/manifest.json"
rm -rf "$STAGE"
