#!/usr/bin/env bash
# Publish a governance upgrade pack to the `upgrades` bucket (ADR-11).
#
#   upgrades/<PLAN>/
#     cosmovisor.json
#     (optional extra files from networks/upgrades/<PLAN>/)
#
# Public: https://s3.terp.network/upgrades/<PLAN>/cosmovisor.json
#
# Usage:
#   PLAN=v6 ./scripts/release/publish_s3_upgrade.sh
#   DRY_RUN=1 PLAN=v520 ./scripts/release/publish_s3_upgrade.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PLAN="${PLAN:-}"
if [ -z "$PLAN" ]; then
  echo "ERROR: set PLAN (e.g. v6, v520)" >&2
  exit 1
fi
MINIO_ALIAS="${MINIO_ALIAS:-usb2}"
S3_BUCKET="${S3_BUCKET:-upgrades}"
SRC="${SRC:-$ROOT/networks/upgrades/${PLAN}}"
DRY_RUN="${DRY_RUN:-0}"
DEST="${MINIO_ALIAS}/${S3_BUCKET}/${PLAN}"

if [ ! -d "$SRC" ]; then
  echo "ERROR: missing $SRC" >&2
  exit 1
fi
if [ ! -f "$SRC/cosmovisor.json" ]; then
  echo "ERROR: missing $SRC/cosmovisor.json" >&2
  exit 1
fi

run_mc() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN: mc $*"
  else
    mc "$@"
  fi
}

echo "=== publish_s3_upgrade ==="
echo "  PLAN   = $PLAN"
echo "  SRC    = $SRC"
echo "  DEST   = $DEST"
echo "  DRY_RUN= $DRY_RUN"

if [ "$DRY_RUN" != "1" ]; then
  if ! mc ls "${MINIO_ALIAS}" >/dev/null 2>&1; then
    echo "ERROR: cannot list mc alias '${MINIO_ALIAS}'" >&2
    exit 1
  fi
  run_mc mb --ignore-existing "${MINIO_ALIAS}/${S3_BUCKET}" || true
fi

run_mc cp "$SRC/cosmovisor.json" "${DEST}/cosmovisor.json"
for f in binaries.json draft_proposal.json ARTIFACT_LOCK guide.md sha256sum.txt; do
  if [ -f "$SRC/$f" ]; then
    run_mc cp "$SRC/$f" "${DEST}/$f"
  fi
done

echo "  public: https://s3.terp.network/upgrades/${PLAN}/cosmovisor.json"
