#!/usr/bin/env bash
# Download the pinned ict-ci tarball from s3.terp.network (no GitHub Releases).
# Usage: scripts/ci/fetch-ict-rs-bins.sh [destdir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/scripts/ci/ict-rs-bins.env"
DEST="${1:-/tmp/ict-bins}"
URL="${ICT_RS_BINS_URL:?}"
mkdir -p "$DEST"
ARCHIVE="$DEST/${ICT_RS_TARBALL}"
echo "fetch $URL -> $ARCHIVE"
curl -fsSL -o "$ARCHIVE" "$URL"
tar -C "$DEST" -xzf "$ARCHIVE"
chmod +x "$DEST/ict-ci" "$DEST/examples/"*
test -x "$DEST/examples/ibc_transfer"
test -x "$DEST/examples/polytone"
echo "ok $DEST"
