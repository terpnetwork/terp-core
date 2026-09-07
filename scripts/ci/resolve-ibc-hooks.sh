#!/usr/bin/env bash
# Print a directory that contains the store/v2-patched ibc-hooks-v11 (go.mod).
# Order: HOOKS_SRC tree → in-repo tarball (git-locked) → MinIO only if IBC_HOOKS_ALLOW_FETCH=1.
# Always sha256-verify tarball bytes against scripts/ci/ibc-hooks-v11.sha256.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_SRC="${HOOKS_SRC:-$ROOT/crates/ibc-hooks-v11}"
HOOKS_TAR="${IBC_HOOKS_TAR:-$ROOT/scripts/ci/ibc-hooks-v11.tar.gz}"
PIN_FILE="$ROOT/scripts/ci/ibc-hooks-v11.sha256"
HOOKS_SHA256="${IBC_HOOKS_SHA256:-}"
if [ -z "$HOOKS_SHA256" ] && [ -f "$PIN_FILE" ]; then
  HOOKS_SHA256="$(awk '/^[0-9a-f]{64}/{print $1; exit}' "$PIN_FILE")"
fi
HOOKS_SHA256="${HOOKS_SHA256:-1b31faa98bedb7e388eef97ed031143a851b0d8a799b52d7b1b3ab78c898a312}"
HOOKS_URL="${IBC_HOOKS_URL:-https://minio.terp.network/releases/terp-core/v6.0.0-dev/ibc-hooks-v11.tar.gz}"

extract_tar() {
  local tarpath="$1" dest="$2"
  got="$(shasum -a 256 "$tarpath" | awk '{print $1}')"
  if [ "$got" != "$HOOKS_SHA256" ]; then
    echo "ERROR: ibc-hooks-v11 tarball $got != pin $HOOKS_SHA256" >&2
    exit 1
  fi
  mkdir -p "$dest"
  tar -C "$dest" -xzf "$tarpath"
  if [ -f "$dest/ibc-hooks-v11/go.mod" ]; then
    echo "$dest/ibc-hooks-v11"
  elif [ -f "$dest/go.mod" ]; then
    echo "$dest"
  else
    echo "ERROR: tarball has no go.mod" >&2
    exit 1
  fi
}

if [ -f "$HOOKS_SRC/go.mod" ]; then
  echo "$HOOKS_SRC"
  exit 0
fi
if [ -f "$HOOKS_TAR" ]; then
  extract_tar "$HOOKS_TAR" "${IBC_HOOKS_EXTRACT:-$ROOT/build/zk-deps}"
  exit 0
fi
if [ "${IBC_HOOKS_ALLOW_FETCH:-0}" = "1" ]; then
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$HOOKS_URL"
  extract_tar "$tmp" "${IBC_HOOKS_EXTRACT:-$ROOT/build/zk-deps}"
  rm -f "$tmp"
  exit 0
fi
echo "ERROR: ibc-hooks-v11 is not in git at $HOOKS_SRC and $HOOKS_TAR is missing." >&2
echo "This tree must track crates/ibc-hooks-v11 or scripts/ci/ibc-hooks-v11.tar.gz." >&2
echo "MinIO fetch is off by default (object can change). Set IBC_HOOKS_ALLOW_FETCH=1 to use the pinned URL." >&2
exit 1
