#!/usr/bin/env bash
# Fetch ict-rs prebuilt for ICT_RS_COMMIT. Works without crates/ict-rs.
# Layout: $PREBUILT_HOST/releases/ict-rs/commits/<sha>/ict-ci-linux-x86_64.tar.gz
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/ci/ict-rs-bins.env"
HOST="${PREBUILT_HOST:-https://minio.terp.network}"
COMMIT="${ICT_RS_COMMIT:?set ICT_RS_COMMIT in ict-rs-bins.env}"
TARBALL="${ICT_RS_TARBALL:-ict-ci-linux-x86_64.tar.gz}"
DEST="${1:-/tmp/ict-bins}"
BASE="${HOST}/releases/ict-rs/commits/${COMMIT}"
mkdir -p "$DEST"
echo "==> fetch $BASE/$TARBALL"
curl -fsSL -o "$DEST/${TARBALL}.sha256" "${BASE}/${TARBALL}.sha256"
curl -fsSL -o "$DEST/${TARBALL}" "${BASE}/${TARBALL}"
got="$(sha256sum "$DEST/${TARBALL}" | awk '{print $1}')"
want="$(awk '{print $1}' "$DEST/${TARBALL}.sha256")"
if [ "$got" != "$want" ]; then
  echo "ERROR: ict-ci tarball sha256 $got != $want" >&2
  exit 1
fi
tar -C "$DEST" -xzf "$DEST/${TARBALL}"
chmod +x "$DEST/ict-ci"
if [ -d "$DEST/examples" ]; then
  find "$DEST/examples" -type f -exec chmod +x {} +
fi
export ICT_CI_BIN_DIR="${ICT_CI_BIN_DIR:-$DEST/examples}"
if [ ! -x "$DEST/ict-ci" ]; then
  echo "ERROR: missing $DEST/ict-ci after unpack" >&2
  exit 1
fi
echo "==> ict-ci pin $COMMIT"
if "$DEST/ict-ci" list >/tmp/ict-ci-list.txt 2>/tmp/ict-ci-list.err; then
  cat /tmp/ict-ci-list.txt
elif grep -q "Exec format error\|cannot execute" /tmp/ict-ci-list.err; then
  echo "note: ict-ci is linux; unpacked for docker/act ($(uname -sm))"
else
  cat /tmp/ict-ci-list.err >&2
  echo "ERROR: ict-ci list failed" >&2
  exit 1
fi
echo "ok $DEST commit=$COMMIT tarball=$got"
