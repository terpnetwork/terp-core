#!/usr/bin/env bash
####################################################################
# TSH: morocco-1 snapshot → in-place testnet → v6.1 IAVL dual-store
#
# OLD_BIND is terpd-v6 (post-v6 binary). The tar is data/ + wasm/ only;
# genesis is fetched separately (GENESIS_URL). Default SNAPSHOT_URL is
# snapshot.json latest. Do not use 5.2.0 (dies: expected 22911849 got 0).
# Do not use pruned 22807932 or archive 22749033 (pre-v6).
#
# After halt, NEW_BIND (this tree) applies plan v6.1, then query-all-params
# and iavl-v2 ingest.
#
#   make tsh-upgrade-v61
#   STATE_SYNC=0 sh tests/tsh/upgrade/v61.sh
#   STATE_SYNC=0 SNAPSHOT_URL='https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/morocco-1_22911849_2026-09-02T03-49-50Z.tar.lz4' \
#     sh tests/tsh/upgrade/v61.sh
####################################################################
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
export UPGRADE_VERSION="${UPGRADE_VERSION:-v6.1}"
export STATE_SYNC="${STATE_SYNC:-0}"
export OLD_BIND="${OLD_BIND:-terpd-v6}"
export NEW_BIND="${NEW_BIND:-terpd}"
export CHAINID="${CHAINID:-test-1}"
export NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-../../../}"
export GENESIS_URL="${GENESIS_URL:-https://raw.githubusercontent.com/terpnetwork/networks/main/mainnet/morocco-1/genesis.json}"
export SNAPSHOT_INDEX="${SNAPSHOT_INDEX:-https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/snapshot.json}"
export OLD_LOG="${OLD_LOG:-/tmp/tsh-v61-old.log}"
export NEW_LOG="${NEW_LOG:-/tmp/tsh-v61-new.log}"
export POST_BLOCKS="${POST_BLOCKS:-3}"

if ! command -v "$OLD_BIND" >/dev/null; then
  echo "OLD_BIND=$OLD_BIND not on PATH. Install the v6 terpd as terpd-v6 (post-v6 snapshot). Do not use 5.2.0."
  exit 1
fi
_oldver="$("$OLD_BIND" version 2>/dev/null | head -1 || true)"
if echo "$_oldver" | grep -qE '^5\.'; then
  echo "OLD_BIND=$OLD_BIND is $_oldver — v6.1 TSH must start from the v6 binary, not 5.x"
  exit 1
fi
echo "v61: OLD_BIND=$OLD_BIND (${_oldver:-v6 pack, version string empty})"

if [ -z "${SNAPSHOT_PATH:-}" ] && [ -z "${SNAPSHOT_URL:-}" ] && [ "$STATE_SYNC" = "0" ]; then
  echo "resolving pruned snapshot from $SNAPSHOT_INDEX"
  SNAPSHOT_URL="$(curl -sfL "$SNAPSHOT_INDEX" | jq -r '.latest // .url // .snapshots[0] // empty')"
  if [ -z "$SNAPSHOT_URL" ] || [ "$SNAPSHOT_URL" = "null" ]; then
    echo "could not resolve snapshot URL from $SNAPSHOT_INDEX — set SNAPSHOT_PATH or SNAPSHOT_URL"
    exit 1
  fi
  export SNAPSHOT_URL
  echo "SNAPSHOT_URL=$SNAPSHOT_URL"
  export SNAPSHOT_PATH="${SNAPSHOT_PATH:-/tmp/terp-morocco-1-pruned.tar.lz4}"
fi

# Reuse the in-place harness (OLD halt → NEW start → applied + post blocks).
# shellcheck disable=SC1091
source "$ROOT/a.sh"

echo "v6.1: checking handler curated dual stores"
if ! grep -q "v6.1: ibc/transfer/ica stores unchanged" "$NEW_LOG"; then
  echo "missing IBC-untouched log in $NEW_LOG"
  tail -80 "$NEW_LOG"
  exit 1
fi
if ! grep -q "v6.1: curated store" "$NEW_LOG"; then
  echo "WARNING: no 'curated store' lines — dest keys may have been missing (skip). Check keepers GenerateKeys + StoreUpgrades.Added."
fi
if grep -q "refusing to rehash IBC-facing store" "$NEW_LOG"; then
  echo "handler refused an IBC store copy — fail closed"
  exit 1
fi
echo "v6.1 TSH ok (applied=$UPGRADE_VERSION)"

echo "v6.1: querying every module params after migration"
# a.sh leaves NEW_BIND running and exports VAL1HOME / ports.
# shellcheck disable=SC1091
source "$ROOT/query-all-params.sh"

# IAVL v2 ingest (not CMS). Uses snapshot/statesync home when present.
export VAL1HOME="${VAL1HOME:-}"
# shellcheck disable=SC1091
source "$ROOT/iavl-v2.sh"
