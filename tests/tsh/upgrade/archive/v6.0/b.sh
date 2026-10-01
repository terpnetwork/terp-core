#!/usr/bin/env bash
####################################################################
# TEST B: local single-node gov software-upgrade named v6.
#
# Same workflow as A, from a fresh local genesis:
#   OLD_BIND (mainnet, no v6 handler) produces blocks + gov plan
#   halt → upgrade-info.json + UPGRADE NEEDED
#   NEW_BIND (this tree) starts, applied height must be set, then POST_BLOCKS
####################################################################
set -euo pipefail

OLD_BIND="${OLD_BIND:-terp-mainnet}"
NEW_BIND="${NEW_BIND:-terpd}"
UPGRADE_INFO_URL="${UPGRADE_INFO_URL:-https://github.com/terpnetwork/terp-core/releases/download/v6.0.0/terpd}"
UPGRADE_VERSION_TITLE="${UPGRADE_VERSION_TITLE:-v6}"
KEY="${KEY:-terp1}"
KEY2="${KEY2:-terp2}"
TFDENOM="${TFDENOM:-skeret}"
NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-../../../}"
CHAIN_ID="${CHAIN_ID:-local-1}"
MONIKER="${MONIKER:-localterp}"
DENOM="${DENOM:-uterp}"
KEYALGO="${KEYALGO:-secp256k1}"
KEYRING="${KEYRING:-test}"
HOME_DIR="${HOME_DIR:-$HOME/.terpd-b}"
CLEAN="${CLEAN:-true}"
RPC="${RPC:-26857}"
REST="${REST:-1319}"
P2P="${P2P:-26856}"
GRPC="${GRPC:-9092}"
TIMEOUT_COMMIT="${TIMEOUT_COMMIT:-1s}"
HALT_DELTA="${HALT_DELTA:-12}"
POST_BLOCKS="${POST_BLOCKS:-5}"
OLD_LOG="${OLD_LOG:-/tmp/tsh-b-old.log}"
NEW_LOG="${NEW_LOG:-/tmp/tsh-b-new.log}"

command -v "$OLD_BIND" >/dev/null || { echo "$OLD_BIND not found"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

rpc() { curl -sf "http://127.0.0.1:${RPC}/status"; }
rpc_height() { rpc | jq -r '.result.sync_info.latest_block_height'; }
wait_rpc() {
  for _ in $(seq 1 60); do rpc >/dev/null 2>&1 && return 0; sleep 1; done
  echo "RPC down"; return 1
}

applied_height() {
  "$NEW_BIND" q upgrade applied "$UPGRADE_VERSION_TITLE" \
    --home "$HOME_DIR" --node "tcp://127.0.0.1:${RPC}" -o json 2>/dev/null \
    | jq -r '.height // empty'
}

tune_config() {
  local cfg="$HOME_DIR/config/config.toml"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${RPC}\"/" "$cfg"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^pprof_laddr *=.*/pprof_laddr = \"localhost:16061\"/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${P2P}\"/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^pex *=.*/pex = false/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^seeds *=.*/seeds = \"\"/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^persistent_peers *=.*/persistent_peers = \"\"/" "$cfg"
  sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"${TIMEOUT_COMMIT}\"/" "$cfg"
  sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/127.0.0.1:${REST}\"/" "$HOME_DIR/config/app.toml" || true
  sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:${GRPC}\"/" "$HOME_DIR/config/app.toml" || true
}

from_scratch() {
  rm -rf "$HOME_DIR"
  echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry" | \
    "$OLD_BIND" keys add "$KEY" --home "$HOME_DIR" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover
  echo "wealth flavor believe regret funny network recall kiss grape useless pepper cram hint member few certain unveil rather brick bargain curious require crowd raise" | \
    "$OLD_BIND" keys add "$KEY2" --home "$HOME_DIR" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover
  "$OLD_BIND" init "$MONIKER" --home "$HOME_DIR" --chain-id "$CHAIN_ID" --default-denom "$DENOM"
  update_test_genesis() {
    jq "$1" "$HOME_DIR/config/genesis.json" > "$HOME_DIR/config/tmp_genesis.json"
    mv "$HOME_DIR/config/tmp_genesis.json" "$HOME_DIR/config/genesis.json"
  }
  update_test_genesis '.consensus.params.block.max_gas="100000000"'
  update_test_genesis '.app_state.gov.params.min_deposit=[{"denom":"uterp","amount":"1000000"}]'
  update_test_genesis '.app_state.gov.params.voting_period="15s"'
  update_test_genesis '.app_state.gov.params.expedited_voting_period="5s"'
  update_test_genesis '.app_state.staking.params.bond_denom="uterp"'
  update_test_genesis '.app_state.mint.params.mint_denom="uterp"'
  "$OLD_BIND" genesis add-genesis-account "$KEY" 1000000000000uterp,1000uthiol --home "$HOME_DIR" --keyring-backend "$KEYRING"
  "$OLD_BIND" genesis add-genesis-account "$KEY2" 100000000000uterp,1000uthiol --home "$HOME_DIR" --keyring-backend "$KEYRING"
  "$OLD_BIND" genesis gentx "$KEY" 10000000000uterp --home "$HOME_DIR" --keyring-backend "$KEYRING" --chain-id "$CHAIN_ID"
  "$OLD_BIND" genesis collect-gentxs --home "$HOME_DIR"
  "$OLD_BIND" genesis validate --home "$HOME_DIR"
}

echo "B: make install NEW_BIND=$NEW_BIND"
( cd "$NEW_RELEASE_PATH" && make install )
command -v "$NEW_BIND" >/dev/null || { echo "$NEW_BIND not on PATH"; exit 1; }
echo "B: OLD=$OLD_BIND ($("$OLD_BIND" version | head -1)) NEW=$NEW_BIND ($("$NEW_BIND" version | head -1))"

if [ "$CLEAN" != "false" ]; then
  from_scratch
  tune_config
fi

: > "$OLD_LOG"
"$OLD_BIND" start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC" >>"$OLD_LOG" 2>&1 &
OLD_PID=$!
wait_rpc
sleep 2
H0=$(rpc_height)
HALT=$((H0 + HALT_DELTA))
echo "B: proposing $UPGRADE_VERSION_TITLE at height $HALT (now $H0) pid=$OLD_PID"

cat > "$HOME_DIR/upgrade.json" <<EOF
{
  "messages": [
    {
      "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
      "authority": "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
      "plan": {
        "name": "$UPGRADE_VERSION_TITLE",
        "time": "0001-01-01T00:00:00Z",
        "height": "$HALT",
        "info": "$UPGRADE_INFO_URL",
        "upgraded_client_state": null
      }
    }
  ],
  "metadata": "",
  "deposit": "5000000000$DENOM",
  "title": "$UPGRADE_VERSION_TITLE",
  "summary": "sdk 0.54 + ibc-go v11.1 + 08-wasm v11.1.0",
  "expedited": true
}
EOF

"$OLD_BIND" tx gov submit-proposal "$HOME_DIR/upgrade.json" --from "$KEY" --home "$HOME_DIR" \
  --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC}" \
  --gas auto --gas-adjustment 1.5 --fees "2000$DENOM" -y
sleep 2
"$OLD_BIND" tx gov vote 1 yes --from "$KEY" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
  --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC}" \
  --gas auto --gas-adjustment 1.2 --fees "1000$DENOM" -y
"$OLD_BIND" tx gov vote 1 yes --from "$KEY2" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
  --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC}" \
  --gas auto --gas-adjustment 1.2 --fees "1000$DENOM" -y

echo "B: waiting for UPGRADE NEEDED at $HALT"
for i in $(seq 1 180); do
  if ! kill -0 "$OLD_PID" 2>/dev/null; then
    echo "B: OLD_BIND exited"
    break
  fi
  if grep -q "UPGRADE \"${UPGRADE_VERSION_TITLE}\" NEEDED" "$OLD_LOG" 2>/dev/null; then
    echo "B: halt signal"
    kill "$OLD_PID" 2>/dev/null || true
    wait "$OLD_PID" 2>/dev/null || true
    break
  fi
  echo "  pre-upgrade h=$(rpc_height || echo ?) halt=$HALT try=$i"
  sleep 1
done
wait "$OLD_PID" 2>/dev/null || true
sleep 2

if [ ! -f "$HOME_DIR/data/upgrade-info.json" ]; then
  echo "B: missing upgrade-info.json"
  tail -40 "$OLD_LOG"
  exit 1
fi
if ! grep -q "UPGRADE \"${UPGRADE_VERSION_TITLE}\" NEEDED" "$OLD_LOG"; then
  echo "B: no UPGRADE NEEDED in old log"
  tail -40 "$OLD_LOG"
  exit 1
fi
echo "B: upgrade-info.json=$(cat "$HOME_DIR/data/upgrade-info.json")"

: > "$NEW_LOG"
"$NEW_BIND" start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC" >>"$NEW_LOG" 2>&1 &
NEW_PID=$!
wait_rpc

APPLIED_H=""
for i in $(seq 1 120); do
  APPLIED_H=$(applied_height || true)
  h=$(rpc_height || echo 0)
  echo "  post-upgrade h=$h applied_height=${APPLIED_H:-none} try=$i"
  if [ -n "$APPLIED_H" ] && [ "$APPLIED_H" != "0" ]; then
    break
  fi
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "B: NEW_BIND died"; tail -50 "$NEW_LOG"; exit 1
  fi
  sleep 2
done
if [ -z "$APPLIED_H" ] || [ "$APPLIED_H" = "0" ]; then
  echo "B: $UPGRADE_VERSION_TITLE not applied"; tail -50 "$NEW_LOG"; exit 1
fi

AFTER=$(rpc_height)
TARGET=$((AFTER + POST_BLOCKS))
echo "B: waiting for $POST_BLOCKS good blocks (from $AFTER to >= $TARGET)"
for i in $(seq 1 120); do
  h=$(rpc_height || echo 0)
  echo "  post-apply h=$h target=$TARGET try=$i"
  if [ "$h" -ge "$TARGET" ]; then break; fi
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "B: NEW_BIND died producing blocks"; tail -50 "$NEW_LOG"; exit 1
  fi
  sleep 2
done
h=$(rpc_height)
if [ "$h" -lt "$TARGET" ]; then
  echo "B: did not produce post-upgrade blocks"; exit 1
fi

"$NEW_BIND" q tokenfactory params --home "$HOME_DIR" --node "tcp://127.0.0.1:${RPC}" -o json | jq .
"$NEW_BIND" q wasm params --home "$HOME_DIR" --node "tcp://127.0.0.1:${RPC}" -o json \
  | jq '.circuit_upload_access.permission // .params.circuit_upload_access.permission // .'
"$NEW_BIND" tx tokenfactory create-denom "$TFDENOM" --from "$KEY" --home "$HOME_DIR" \
  --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC}" \
  --gas auto --gas-adjustment 1.2 --fees "1000$DENOM" -y
sleep 2
"$NEW_BIND" q tokenfactory denoms-from-creator \
  "$("$NEW_BIND" keys show "$KEY" -a --home "$HOME_DIR" --keyring-backend "$KEYRING")" \
  --home "$HOME_DIR" --node "tcp://127.0.0.1:${RPC}" -o json | jq .

echo "B: gov upgrade finished applied=$UPGRADE_VERSION_TITLE at $APPLIED_H height=$h"
