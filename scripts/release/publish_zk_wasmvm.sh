#!/usr/bin/env bash
# Upload one-generation libwasmvm 4.0.0-zk artifacts to s3.terp.network.
# Does not invent checksums: hashes files on disk after verify-libwasmvm.
#
#   ./scripts/release/publish_zk_wasmvm.sh
#   DRY_RUN=1 ./scripts/release/publish_zk_wasmvm.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ZK="${ZK_WASMVM_DIR:-$ROOT/crates/zk-wasmvm}"
# usb2 is the LAN write alias (Makefile default). s3terp is public read.
ALIAS="${MINIO_ALIAS:-usb2}"
BUCKET="${S3_BUCKET:-releases}"
TAG="${WASMVM_S3_TAG:-v4.0.0-zk}"
DEST="${ALIAS}/${BUCKET}/zk-wasmvm/${TAG}"
DRY_RUN="${DRY_RUN:-0}"

bash "$ZK/builders/host/verify_libwasmvm.sh"

API="$ZK/internal/api"
COMMIT="$(git -C "$ZK" rev-parse HEAD)"
VERSION="$(awk -F'"' '/^version = /{print $2; exit}' "$ZK/libwasmvm/Cargo.toml")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

copy_one() {
  local src="$1"
  [ -f "$src" ] || { echo "ERROR: missing $src" >&2; exit 1; }
  cp -f "$src" "$STAGE/$(basename "$src")"
}

copy_one "$API/libwasmvm_muslc.x86_64.a"
copy_one "$API/libwasmvm_muslc.aarch64.a"
copy_one "$API/libwasmvm.x86_64.so"
copy_one "$API/libwasmvm.aarch64.so"
# dylib is Darwin-host; Cosmovisor is linux muslc. Still ship for go-test identity.
if [ -f "$API/libwasmvm.dylib" ]; then
  copy_one "$API/libwasmvm.dylib"
fi

(
  cd "$STAGE"
  if command -v sha256sum >/dev/null; then
    sha256sum libwasmvm* | sort > SHA256SUMS
  else
    shasum -a 256 libwasmvm* | sort > SHA256SUMS
  fi
  printf '%s\n' "$COMMIT" > SOURCE_COMMIT
  printf '%s\n' "$VERSION" > VERSION
)

echo "==> staged $STAGE"
cat "$STAGE/SHA256SUMS"
echo "SOURCE_COMMIT=$COMMIT"
echo "VERSION=$VERSION"
echo "DEST=$DEST"

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY_RUN=1: not uploading"
  exit 0
fi

command -v mc >/dev/null || { echo "ERROR: mc (minio client) not on PATH" >&2; exit 1; }
mc cp "$STAGE"/libwasmvm_muslc.x86_64.a "$STAGE"/libwasmvm_muslc.aarch64.a \
  "$STAGE"/libwasmvm.x86_64.so "$STAGE"/libwasmvm.aarch64.so \
  "$STAGE"/SHA256SUMS "$STAGE"/SOURCE_COMMIT "$STAGE"/VERSION \
  "$DEST/"
if [ -f "$STAGE/libwasmvm.dylib" ]; then
  mc cp "$STAGE/libwasmvm.dylib" "$DEST/"
fi
echo "OK uploaded $DEST"
mc ls "$DEST/"
