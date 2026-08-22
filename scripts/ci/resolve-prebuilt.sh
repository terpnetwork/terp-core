#!/usr/bin/env bash
# Resolve prebuilt artifact URLs for a git commit.
# Layout: $PREBUILT_HOST/releases/terp-core/commits/<full-sha>/
#
# Pin order: existing PREBUILT_COMMIT env > scripts/ci/terp-prebuilt.env >
# GITHUB_SHA > git HEAD. Do not default CI to github.sha until that folder
# exists on MinIO.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$ROOT/scripts/ci/terp-prebuilt.env"
if [ -z "${PREBUILT_COMMIT:-}" ] && [ -f "$PIN" ]; then
  # shellcheck disable=SC1090
  . "$PIN"
fi
PREBUILT_HOST="${PREBUILT_HOST:-https://minio.terp.network}"
COMMIT="${PREBUILT_COMMIT:-${GITHUB_SHA:-}}"
if [ -z "$COMMIT" ]; then
  COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
fi
COMMIT="$(printf '%s' "$COMMIT" | tr '[:upper:]' '[:lower:]')"
BASE="${PREBUILT_HOST}/releases/terp-core/commits/${COMMIT}"
echo "PREBUILT_COMMIT=${COMMIT}"
echo "PREBUILT_HOST=${PREBUILT_HOST}"
echo "PREBUILT_BASE=${BASE}"
echo "PREBUILT_TERPD_URL=${BASE}/terpd-linux-amd64"
echo "PREBUILT_TERPD_SHA_URL=${BASE}/terpd-linux-amd64.sha256"
echo "PREBUILT_IMAGE_URL=${BASE}/terp-core-local-linux-amd64.tar"
echo "PREBUILT_MANIFEST_URL=${BASE}/manifest.json"
