#!/usr/bin/env bash
# Publish a release bundle to MinIO/S3 via `mc` for durable, verifiable availability.
#
# Canonical layout (project-scoped — same pattern for every repo):
#
#   Bucket: releases   (MINIO_ALIAS/releases)
#     <PROJECT>/<RELEASE_TAG>/
#       manifest.json
#       SOURCE_COMMIT
#       source.tar.gz
#       source.tar.gz.sha256
#       docker-images.txt
#       sha256sum.txt                 (if present)
#       docker-build.env              (if present)
#     <PROJECT>/latest/               (optional: pointer files when PUBLISH_LATEST=1)
#
# Network ops assets stay separate (do not bury source releases here):
#   Bucket: snapshots
#     <NETWORK>/<CHAIN_ID>/releases/<PROJECT>/<RELEASE_TAG>/   # lightweight pointer
#     <NETWORK>/<CHAIN_ID>/scripts/...                         # entrypoints if SYNC_ENTRYPOINT=1
#
# Public (s3.terp.network proxies MinIO path-style):
#   https://s3.terp.network/releases/<PROJECT>/<RELEASE_TAG>/manifest.json
#
# Usage:
#   make release-s3 RELEASE_TAG=v5.3.0-dev PROJECT=terp-core NETWORK=testnet CHAIN_ID=120u-1
#   DRY_RUN=1 ./scripts/release/publish_s3_release.sh
#
# Env defaults match scripts/release/README.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

RELEASE_TAG="${RELEASE_TAG:-v5.3.0-dev}"
# Project folder = repo name (stable across tags). Override for binary-only trees (e.g. terpd).
PROJECT="${PROJECT:-${RELEASE_PROJECT:-terp-core}}"
MINIO_ALIAS="${MINIO_ALIAS:-usb2}"
# Default into the dedicated releases bucket (not alias root / not snapshots).
S3_BUCKET="${S3_BUCKET:-releases}"
NETWORK="${NETWORK:-testnet}"
CHAIN_ID="${CHAIN_ID:-120u-1}"
DRY_RUN="${DRY_RUN:-0}"
SYNC_ENTRYPOINT="${SYNC_ENTRYPOINT:-0}"
ENTRYPOINT_SRC="${ENTRYPOINT_SRC:-}"
CONFIG_ENDPOINTS_SRC="${CONFIG_ENDPOINTS_SRC:-}"
BUNDLE_DIR="${BUNDLE_DIR:-build/release/${RELEASE_TAG}}"
MIRROR_SNAPSHOT_POINTER="${MIRROR_SNAPSHOT_POINTER:-1}"
PUBLISH_LATEST="${PUBLISH_LATEST:-0}"
# Remove legacy flat key releases/<tag>/ after successful project-scoped publish
MIGRATE_LEGACY_FLAT="${MIGRATE_LEGACY_FLAT:-1}"

mc_base() {
  if [ -n "$S3_BUCKET" ]; then
    echo "${MINIO_ALIAS}/${S3_BUCKET}"
  else
    echo "${MINIO_ALIAS}"
  fi
}

BASE="$(mc_base)"
DEST_RELEASE="${BASE}/${PROJECT}/${RELEASE_TAG}"
DEST_LATEST="${BASE}/${PROJECT}/latest"
# Snapshot pointer: network tree → which project release powers this chain
DEST_SNAP_PTR="${MINIO_ALIAS}/snapshots/${NETWORK}/${CHAIN_ID}/releases/${PROJECT}/${RELEASE_TAG}"
DEST_SCRIPTS="${MINIO_ALIAS}/snapshots/${NETWORK}/${CHAIN_ID}/scripts"
LEGACY_FLAT="${MINIO_ALIAS}/releases/${RELEASE_TAG}"

echo "=== publish_s3_release ==="
echo "  PROJECT       = $PROJECT"
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
  # Ensure releases bucket exists (idempotent)
  if ! mc ls "${MINIO_ALIAS}/releases" >/dev/null 2>&1; then
    echo "==> Creating bucket ${MINIO_ALIAS}/releases"
    run_mc mb --ignore-existing "${MINIO_ALIAS}/releases" || true
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

if [ "$PUBLISH_LATEST" = "1" ]; then
  echo "==> Pointer → ${DEST_LATEST}/ (manifest + digests only)"
  for f in manifest.json SOURCE_COMMIT source.tar.gz.sha256 docker-images.txt; do
    if [ -f "$BUNDLE_DIR/$f" ]; then
      run_mc cp "$BUNDLE_DIR/$f" "${DEST_LATEST}/$f"
    fi
  done
fi

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

# Migrate legacy flat releases/<tag>/ → project-scoped path (one-time cleanup)
if [ "$MIGRATE_LEGACY_FLAT" = "1" ] && [ "$DRY_RUN" != "1" ]; then
  if mc ls "${LEGACY_FLAT}/" >/dev/null 2>&1; then
    # Only migrate if it looks like our flat mistake (has source.tar.gz at tag root)
    if mc stat "${LEGACY_FLAT}/source.tar.gz" >/dev/null 2>&1; then
      echo "==> Legacy flat path detected: ${LEGACY_FLAT}/"
      echo "    Already published to ${DEST_RELEASE}/ — removing flat key to avoid dual homes"
      run_mc rm --recursive --force "${LEGACY_FLAT}/" || true
    fi
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
  echo "Public:"
  echo "  https://s3.terp.network/releases/${PROJECT}/${RELEASE_TAG}/manifest.json"
  echo "  https://s3.terp.network/releases/${PROJECT}/${RELEASE_TAG}/source.tar.gz"
fi
