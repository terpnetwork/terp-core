#!/usr/bin/env bash
# Publish a release bundle to MinIO/S3 via `mc` for durable, verifiable availability.
#
# Layout (under MINIO_ALIAS / S3_BUCKET):
#   releases/<RELEASE_TAG>/
#     manifest.json
#     SOURCE_COMMIT
#     source.tar.gz
#     source.tar.gz.sha256
#     docker-images.txt
#     sha256sum.txt                 (if present)
#     docker-build.env              (if present)
#
# Optional pointer under network snapshots tree:
#   snapshots/<NETWORK>/<CHAIN_ID>/releases/<RELEASE_TAG>/
#     (same files, or lightweight pointer — we mirror manifest + SOURCE_COMMIT)
#
# Optional entrypoint sync (SYNC_ENTRYPOINT=1):
#   snapshots/<NETWORK>/<CHAIN_ID>/scripts/oline-entrypoint.sh
#   snapshots/<NETWORK>/<CHAIN_ID>/scripts/config-node-endpoints.sh
#
# Usage:
#   make release-s3 RELEASE_TAG=v5.3.0-dev NETWORK=testnet CHAIN_ID=120u-1
#   DRY_RUN=1 ./scripts/release/publish_s3_release.sh
#
# Env defaults match scripts/release/README.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

RELEASE_TAG="${RELEASE_TAG:-v5.3.0-dev}"
MINIO_ALIAS="${MINIO_ALIAS:-usb2}"
S3_BUCKET="${S3_BUCKET:-}"
NETWORK="${NETWORK:-testnet}"
CHAIN_ID="${CHAIN_ID:-120u-1}"
DRY_RUN="${DRY_RUN:-0}"
SYNC_ENTRYPOINT="${SYNC_ENTRYPOINT:-0}"
ENTRYPOINT_SRC="${ENTRYPOINT_SRC:-}"
CONFIG_ENDPOINTS_SRC="${CONFIG_ENDPOINTS_SRC:-}"
BUNDLE_DIR="${BUNDLE_DIR:-build/release/${RELEASE_TAG}}"
MIRROR_SNAPSHOT_POINTER="${MIRROR_SNAPSHOT_POINTER:-1}"

# Resolve mc base path. Prefer explicit S3_BUCKET; else try bare alias root
# (host MinIO often exposes a single "data" root with releases/ snapshots/).
mc_base() {
  if [ -n "$S3_BUCKET" ]; then
    echo "${MINIO_ALIAS}/${S3_BUCKET}"
  else
    echo "${MINIO_ALIAS}"
  fi
}

BASE="$(mc_base)"
DEST_RELEASE="${BASE}/releases/${RELEASE_TAG}"
DEST_SNAP_PTR="${BASE}/snapshots/${NETWORK}/${CHAIN_ID}/releases/${RELEASE_TAG}"
DEST_SCRIPTS="${BASE}/snapshots/${NETWORK}/${CHAIN_ID}/scripts"

echo "=== publish_s3_release ==="
echo "  RELEASE_TAG   = $RELEASE_TAG"
echo "  MINIO_ALIAS   = $MINIO_ALIAS"
echo "  S3_BUCKET     = ${S3_BUCKET:-(alias root)}"
echo "  BASE          = $BASE"
echo "  BUNDLE_DIR    = $BUNDLE_DIR"
echo "  DEST_RELEASE  = $DEST_RELEASE"
echo "  NETWORK/CHAIN = $NETWORK / $CHAIN_ID"
echo "  DRY_RUN       = $DRY_RUN"
echo ""

if ! command -v mc >/dev/null 2>&1; then
  echo "ERROR: mc (MinIO client) not found on PATH" >&2
  exit 1
fi

if [ ! -d "$BUNDLE_DIR" ]; then
  echo "ERROR: bundle dir missing: $BUNDLE_DIR" >&2
  echo "Run: make release-bundle RELEASE_TAG=${RELEASE_TAG}" >&2
  exit 1
fi

REQUIRED=(manifest.json SOURCE_COMMIT source.tar.gz source.tar.gz.sha256)
for f in "${REQUIRED[@]}"; do
  if [ ! -f "$BUNDLE_DIR/$f" ]; then
    echo "ERROR: missing required bundle file: $BUNDLE_DIR/$f" >&2
    exit 1
  fi
done

# Verify local source checksum before upload
echo "==> Verifying source.tar.gz checksum"
(
  cd "$BUNDLE_DIR"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c source.tar.gz.sha256
  else
    sha256sum -c source.tar.gz.sha256
  fi
)

run_mc() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN: mc $*"
  else
    mc "$@"
  fi
}

# Probe alias / bucket
if [ "$DRY_RUN" != "1" ]; then
  if ! mc ls "${MINIO_ALIAS}" >/dev/null 2>&1; then
    echo "ERROR: cannot list mc alias '${MINIO_ALIAS}'. Check: mc alias list" >&2
    exit 1
  fi
fi

echo "==> Uploading release bundle → ${DEST_RELEASE}/"
for f in \
  manifest.json \
  SOURCE_COMMIT \
  source.tar.gz \
  source.tar.gz.sha256 \
  docker-images.txt \
  sha256sum.txt \
  docker-build.env; do
  if [ -f "$BUNDLE_DIR/$f" ]; then
    run_mc cp "$BUNDLE_DIR/$f" "${DEST_RELEASE}/$f"
  fi
done

if [ "$MIRROR_SNAPSHOT_POINTER" = "1" ]; then
  echo "==> Snapshot pointer → ${DEST_SNAP_PTR}/"
  for f in manifest.json SOURCE_COMMIT source.tar.gz.sha256 docker-images.txt; do
    if [ -f "$BUNDLE_DIR/$f" ]; then
      run_mc cp "$BUNDLE_DIR/$f" "${DEST_SNAP_PTR}/$f"
    fi
  done
fi

if [ "$SYNC_ENTRYPOINT" = "1" ]; then
  echo "==> Syncing entrypoint scripts → ${DEST_SCRIPTS}/"
  if [ -n "$ENTRYPOINT_SRC" ] && [ -f "$ENTRYPOINT_SRC" ]; then
    run_mc cp "$ENTRYPOINT_SRC" "${DEST_SCRIPTS}/oline-entrypoint.sh"
  else
    echo "WARN: SYNC_ENTRYPOINT=1 but ENTRYPOINT_SRC missing/unset ($ENTRYPOINT_SRC)"
  fi
  if [ -n "$CONFIG_ENDPOINTS_SRC" ] && [ -f "$CONFIG_ENDPOINTS_SRC" ]; then
    run_mc cp "$CONFIG_ENDPOINTS_SRC" "${DEST_SCRIPTS}/config-node-endpoints.sh"
  fi
fi

echo ""
if [ "$DRY_RUN" = "1" ]; then
  echo "Dry-run complete (no objects written)."
else
  echo "Published. List with:"
  echo "  mc ls ${DEST_RELEASE}/"
  echo "  mc cat ${DEST_RELEASE}/manifest.json"
  echo ""
  echo "Public (if Cloudflare/MinIO gateway maps this bucket):"
  echo "  https://s3.terp.network/releases/${RELEASE_TAG}/manifest.json"
fi
