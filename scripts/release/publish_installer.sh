#!/usr/bin/env bash
# Publish get/terp-installer.sh (and .py, config checksums) to the static bucket
# that serves https://terp.network/get/terp-installer.sh
#
#   ./scripts/release/publish_installer.sh
#   DRY_RUN=1 ./scripts/release/publish_installer.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SITE="$ROOT/websites/terp.network"
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.terp.network}"
MINIO_ALIAS="${MINIO_ALIAS:-s3terp}"
S3_BUCKET="${S3_BUCKET:-static}"
PREFIX="${PREFIX:-terp.network/dist}"
DRY_RUN="${DRY_RUN:-0}"

[ -f "$SITE/dist/get/terp-installer.sh" ] || {
  echo "ERROR: missing $SITE/dist/get/terp-installer.sh" >&2
  exit 1
}
if ! grep -q 'MAINNET_VERSION="${MAINNET_VERSION:-6.0.1}"' "$SITE/dist/get/terp-installer.sh"; then
  echo "ERROR: dist installer is not the v6.0.1 / v6.2.0 script" >&2
  exit 1
fi
if grep -q 'TERPD_VERSION="${TERPD_VERSION:-6.0.0}"' "$SITE/dist/get/terp-installer.sh"; then
  echo "ERROR: dist installer still pins 6.0.0" >&2
  exit 1
fi

if [ -n "${AWS_ACCESS_KEY_ID:-}${MINIO_ROOT_USER:-}" ]; then
  key="${AWS_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-}}"
  secret="${AWS_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-}}"
  [ "$DRY_RUN" = "1" ] || mc alias set "$MINIO_ALIAS" "$S3_ENDPOINT" "$key" "$secret" >/dev/null
fi

DEST="${MINIO_ALIAS}/${S3_BUCKET}/${PREFIX}"
echo "=== publish_installer DEST=$DEST DRY_RUN=$DRY_RUN ==="

put() {
  local src="$1" rel="$2"
  [ -f "$src" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN: mc cp $src ${DEST}/$rel"
  else
    mc cp "$src" "${DEST}/$rel"
  fi
}

put "$SITE/dist/get/terp-installer.sh" "get/terp-installer.sh"
put "$SITE/dist/get/terp-installer.py" "get/terp-installer.py"
put "$SITE/dist/public/config.json" "public/config.json"

echo "Verify:"
echo "  curl -fsSL https://terp.network/get/terp-installer.sh | grep MAINNET_VERSION"
