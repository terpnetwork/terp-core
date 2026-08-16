#!/usr/bin/env bash
# Upload a packed ict-ci tarball to host MinIO:
#   usb2/releases/ict-rs/<tag>/ict-ci-linux-x86_64.tar.gz
# Public: https://s3.terp.network/releases/ict-rs/<tag>/...
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/scripts/ci/ict-rs-bins.env"
SRC="${1:-}"
if [ -z "$SRC" ]; then
  echo "usage: $0 <ict-ci-linux-x86_64.tar.gz>" >&2
  exit 2
fi
test -f "$SRC"
MINIO_ALIAS="${MINIO_ALIAS:-usb2}"
DEST="${MINIO_ALIAS}/releases/${ICT_RS_PROJECT}/${ICT_RS_RELEASE}"
echo "publish $SRC -> $DEST/${ICT_RS_TARBALL}"
mc cp "$SRC" "${DEST}/${ICT_RS_TARBALL}"
if [ -f "${SRC}.sha256" ]; then
  mc cp "${SRC}.sha256" "${DEST}/${ICT_RS_TARBALL}.sha256"
fi
mc ls "$DEST"
echo "public: https://s3.terp.network/releases/${ICT_RS_PROJECT}/${ICT_RS_RELEASE}/${ICT_RS_TARBALL}"
