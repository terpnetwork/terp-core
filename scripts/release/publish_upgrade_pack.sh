#!/usr/bin/env bash
# Upload Cosmovisor pack JSON to upgrades/<plan>/ and linux tarballs to
# releases/terp-core/<tag>/. Write alias is usb2 (LAN). s3terp is public read.
#
#   PLAN=v6.4 ./scripts/release/publish_upgrade_pack.sh
#   PLAN=v6.4 DRY_RUN=1 ./scripts/release/publish_upgrade_pack.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
PLAN="${PLAN:-}"
[ "$PLAN" = "v6.3" ] || [ "$PLAN" = "v6.4" ] || { echo "ERROR: PLAN=v6.3 or v6.4" >&2; exit 1; }
PACK="$ROOT/networks/upgrades/${PLAN}"
LOCK="$PACK/ARTIFACT_LOCK"
[ -f "$PACK/cosmovisor.json" ] || { echo "ERROR: missing $PACK/cosmovisor.json" >&2; exit 1; }
tag="$(awk -F': ' '$1=="binary_tag"{print $2; exit}' "$LOCK")"
DRY_RUN="${DRY_RUN:-0}"
ALIAS="${MINIO_ALIAS:-usb2}"

PLAN="$PLAN" CHECK_S3=0 bash "$ROOT/scripts/release/verify_upgrade_pack.sh"

echo "==> $ALIAS/upgrades/${PLAN}/"
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY_RUN pack files:"
  ls -l "$PACK"/cosmovisor.json "$PACK"/binaries.json "$PACK"/ARTIFACT_LOCK "$PACK"/draft_proposal.json
else
  mc cp "$PACK/cosmovisor.json" "$PACK/binaries.json" "$PACK/ARTIFACT_LOCK" \
    "$PACK/draft_proposal.json" "$ALIAS/upgrades/${PLAN}/"
  if [ -f "$PACK/guide.md" ]; then
    mc cp "$PACK/guide.md" "$ALIAS/upgrades/${PLAN}/"
  fi
fi

export MINIO_ALIAS="$ALIAS"
export RELEASE_TAG="$tag"
export ONLY=linux
if [ "$DRY_RUN" = "1" ]; then
  DRY_RUN=1 bash "$ROOT/scripts/release/publish_s3_binaries.sh"
else
  bash "$ROOT/scripts/release/publish_s3_binaries.sh"
fi
echo "OK published PLAN=$PLAN TAG=$tag"
echo "  https://s3.terp.network/upgrades/${PLAN}/cosmovisor.json"
echo "  https://s3.terp.network/releases/terp-core/${tag}/"
