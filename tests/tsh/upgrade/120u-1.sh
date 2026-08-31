#!/usr/bin/env bash
####################################################################
# 120u-1 soak helper for plan v6.1
#
# Default: measure height, write proposal JSON, stage NEW binary,
# print the tx commands. Does NOT broadcast or swap the running process.
#
#   SKIP_INSTALL=1 sh tests/tsh/upgrade/120u-1.sh
#   SUBMIT=1 KEY=<key> sh tests/tsh/upgrade/120u-1.sh   # only when asked
####################################################################
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PACK="$ROOT/networks/upgrades/v6.1"
HOME_DIR="${HOME_DIR:-$HOME/.terpd-testnet}"
CHAIN_ID="${CHAIN_ID:-120u-1}"
RPC="${RPC:-26657}"
NODE="tcp://127.0.0.1:${RPC}"
OLD_BIND="${OLD_BIND:-terpd-testnet-v6}"
NEW_BIND="${NEW_BIND:-terpd-testnet-v61}"
KEY="${KEY:-}"
KEYRING="${KEYRING:-test}"
DENOM="${DENOM:-uterp}"
HALT_DELTA="${HALT_DELTA:-50}"
UPGRADE_VERSION="${UPGRADE_VERSION:-v6.1}"
SUBMIT="${SUBMIT:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-$ROOT}"

# Never point at mainnet home/RPC.
if [ "$HOME_DIR" = "$HOME/.terpd-mainnet" ] || [ "$CHAIN_ID" = "morocco-1" ]; then
  echo "refusing mainnet home/chain"
  exit 1
fi

command -v "$OLD_BIND" >/dev/null || { echo "$OLD_BIND not on PATH"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

if [ "$SKIP_INSTALL" != "1" ]; then
  echo "120u-1: GOWORK=off go install → $HOME/go/bin/$NEW_BIND"
  ( cd "$NEW_RELEASE_PATH" && GOWORK=off go install -mod=mod -tags "netgo ledger" -o "$HOME/go/bin/$NEW_BIND" ./cmd/terpd )
fi
command -v "$NEW_BIND" >/dev/null || [ -x "$HOME/go/bin/$NEW_BIND" ] || {
  echo "$NEW_BIND not built"; exit 1
}
NEW_BIN="$(command -v "$NEW_BIND" 2>/dev/null || echo "$HOME/go/bin/$NEW_BIND")"

H="$(curl -sf "http://127.0.0.1:${RPC}/status" | jq -r '.result.sync_info.latest_block_height')"
NET="$(curl -sf "http://127.0.0.1:${RPC}/status" | jq -r '.result.node_info.network')"
if [ "$NET" != "$CHAIN_ID" ]; then
  echo "RPC :$RPC is $NET, expected $CHAIN_ID"
  exit 1
fi
HALT=$((H + HALT_DELTA))
echo "120u-1: height=$H halt=$HALT plan=$UPGRADE_VERSION"
echo "120u-1: OLD=$OLD_BIND NEW=$NEW_BIN"

mkdir -p "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION}/bin"
cp "$NEW_BIN" "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd"
chmod +x "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd"

PROP="$HOME_DIR/upgrade-v61.json"
jq --arg h "$HALT" --arg name "$UPGRADE_VERSION" \
  '.messages[0].plan.height=$h | .messages[0].plan.name=$name' \
  "$PACK/draft_proposal.json" > "$PROP"
echo "120u-1: wrote $PROP"
cat "$PROP"

if [ "$SUBMIT" != "1" ]; then
  echo
  echo "120u-1: not submitting (SUBMIT=0). When asked:"
  echo "  $OLD_BIND tx gov submit-proposal $PROP --from \$KEY --home $HOME_DIR --chain-id $CHAIN_ID \\"
  echo "    --keyring-backend $KEYRING --node $NODE --gas auto --gas-adjustment 1.5 --fees 2000$DENOM -y"
  echo "  $OLD_BIND tx gov vote 1 yes --from \$KEY --home $HOME_DIR --chain-id $CHAIN_ID \\"
  echo "    --keyring-backend $KEYRING --node $NODE --gas auto --gas-adjustment 1.2 --fees 1000$DENOM -y"
  echo "After UPGRADE NEEDED: stop $OLD_BIND, start $NEW_BIN --home $HOME_DIR"
  exit 0
fi

if [ -z "$KEY" ]; then
  echo "SUBMIT=1 requires KEY=<keyring name>"
  exit 1
fi

"$OLD_BIND" tx gov submit-proposal "$PROP" --from "$KEY" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
  --keyring-backend "$KEYRING" --node "$NODE" \
  --gas auto --gas-adjustment 1.5 --fees "2000$DENOM" -y
echo "120u-1: proposal submitted. Vote, then wait for halt."
