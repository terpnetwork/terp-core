#!/usr/bin/env bash
# Upload versioned terpd tarballs into releases/terp-core/<tag>/ (same folder as
# linux ELFs). Merges sha256sum.txt — never drops existing linux lines.
#
#   RELEASE_TAG=v6.0.1 ./scripts/release/publish_s3_binaries.sh
#   RELEASE_TAG=v6.0.1 DRY_RUN=1 ./scripts/release/publish_s3_binaries.sh
#
# Default alias is public https://s3.terp.network (S3_ENDPOINT / mc alias s3terp).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TAG="${RELEASE_TAG:-${TAG:-}}"
if ! echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: RELEASE_TAG must be vX.Y.Z (got '${TAG:-<empty>}')" >&2
  exit 1
fi
VER="${TAG#v}"
PROJECT="${PROJECT:-terp-core}"
S3_BUCKET="${S3_BUCKET:-releases}"
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.terp.network}"
MINIO_ALIAS="${MINIO_ALIAS:-s3terp}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DRY_RUN="${DRY_RUN:-0}"
PUBLIC="${PUBLIC:-https://s3.terp.network}"

if ! command -v mc >/dev/null; then
  echo "ERROR: mc not on PATH" >&2
  exit 1
fi

# Point alias at the public origin when creds are in the environment.
if [ -n "${AWS_ACCESS_KEY_ID:-}${MINIO_ROOT_USER:-}" ]; then
  key="${AWS_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-}}"
  secret="${AWS_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-}}"
  if [ "$DRY_RUN" != "1" ]; then
    mc alias set "$MINIO_ALIAS" "$S3_ENDPOINT" "$key" "$secret" >/dev/null
  fi
fi

DEST="${MINIO_ALIAS}/${S3_BUCKET}/${PROJECT}/${TAG}"
echo "=== publish_s3_binaries TAG=$TAG DEST=$DEST DRY_RUN=$DRY_RUN ==="

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ONLY=darwin skips linux (do not overwrite published muslc ELFs from this Mac).
ONLY="${ONLY:-}"
uploads=()
for name in \
  "terpd-${VER}-linux-amd64.tar.gz" \
  "terpd-${VER}-linux-arm64.tar.gz" \
  "terpd-${VER}-darwin-arm64.tar.gz" \
  "terpd-linux-amd64" \
  "terpd-linux-arm64" \
  "terpd-darwin-arm64"
do
  [ -f "$BUILD_DIR/$name" ] || continue
  case "$ONLY" in
    darwin) echo "$name" | grep -q darwin || continue ;;
    linux)  echo "$name" | grep -q linux  || continue ;;
  esac
  uploads+=("$name")
done
if [ ${#uploads[@]} -eq 0 ]; then
  echo "ERROR: no tarballs/ELFs in $BUILD_DIR for $TAG" >&2
  exit 1
fi

merged="$(mktemp)"
# Start from published sums so we do not clobber linux lines with a partial local file.
if curl -fsSL "$PUBLIC/releases/${PROJECT}/${TAG}/sha256sum.txt" > "$merged" 2>/dev/null; then
  echo "merged existing $PUBLIC/releases/${PROJECT}/${TAG}/sha256sum.txt"
else
  : > "$merged"
fi

for name in "${uploads[@]}"; do
  sum="$(sha256_file "$BUILD_DIR/$name")"
  tmp="$(mktemp)"
  awk -v n="$name" '$2 != n' "$merged" > "$tmp"
  echo "$sum  $name" >> "$tmp"
  mv "$tmp" "$merged"
  echo "  $sum  $name"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN: mc cp $BUILD_DIR/$name ${DEST}/$name"
  else
    mc cp "$BUILD_DIR/$name" "${DEST}/$name"
  fi
done

sort -k2 "$merged" -o "$merged"
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY_RUN sha256sum.txt:"
  cat "$merged"
else
  mc cp "$merged" "${DEST}/sha256sum.txt"
fi
rm -f "$merged"

echo "Public:"
for name in "${uploads[@]}"; do
  echo "  $PUBLIC/releases/${PROJECT}/${TAG}/$name"
done
echo "  $PUBLIC/releases/${PROJECT}/${TAG}/sha256sum.txt"
