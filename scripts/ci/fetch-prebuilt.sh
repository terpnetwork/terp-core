#!/usr/bin/env bash
# Download prebuilt terpd + image tar for PREBUILT_COMMIT (default HEAD).
# Does not compile. Fails loud if the commit folder is missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${1:-/tmp/terp-prebuilt}"
# shellcheck disable=SC1091
eval "$("$ROOT/scripts/ci/resolve-prebuilt.sh")"
mkdir -p "$DEST"
echo "==> fetch $PREBUILT_BASE"
curl -fsSL -o "$DEST/manifest.json" "$PREBUILT_MANIFEST_URL"
curl -fsSL -o "$DEST/terpd-linux-amd64.sha256" "$PREBUILT_TERPD_SHA_URL"
curl -fsSL -o "$DEST/terpd-linux-amd64" "$PREBUILT_TERPD_URL"
curl -fsSL -o "$DEST/terp-core-local-linux-amd64.tar" "$PREBUILT_IMAGE_URL"
got="$(sha256sum "$DEST/terpd-linux-amd64" | awk '{print $1}')"
want="$(awk '{print $1}' "$DEST/terpd-linux-amd64.sha256")"
if [ "$got" != "$want" ]; then
  echo "ERROR: terpd sha256 $got != $want" >&2
  exit 1
fi
chmod +x "$DEST/terpd-linux-amd64"
echo "PREBUILT_COMMIT=$PREBUILT_COMMIT" > "$DEST/SOURCE_COMMIT"
echo "ok $DEST terpd=$got"
