#!/usr/bin/env bash
####################################################################
# TEST D: existing CosmWasm guests survive the v6 (bulk_memory VM) upgrade.
#
# Mirrors tests/tsh/upgrade/b.sh (local genesis + gov software-upgrade),
# and adds a pre-upgrade contract lifecycle:
#
#   OLD_BIND (current mainnet, no bulk_memory cap)
#     store + instantiate a rustc≤1.86 guest (cw_template)
#     execute increment, query count
#   halt at plan height (UPGRADE NEEDED)
#   NEW_BIND (this tree, metered bulk_memory VM)
#     same code_id checksum, same contract address
#     query returns the pre-upgrade count
#     execute increment still works (count + 1)
#
# That is the concrete claim:
#   updating the VM to support bulk memory does not brick existing
#   smart contracts after the network upgrade.
#
#   OLD_BIND        default terp-mainnet
#   NEW_BIND        default terpd (make install of this tree)
#   WASM            default ../../../artifacts/cw_template.wasm
####################################################################
set -euo pipefail
export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:${HOME}/go/bin:${PATH}"

OLD_BIND="${OLD_BIND:-terp-mainnet}"
NEW_BIND="${NEW_BIND:-terpd}"
UPGRADE_INFO_URL="${UPGRADE_INFO_URL:-https://github.com/terpnetwork/terp-core/releases/download/v6.0.0/terpd}"
UPGRADE_VERSION_TITLE="${UPGRADE_VERSION_TITLE:-v6}"
KEY="${KEY:-terp1}"
KEY2="${KEY2:-terp2}"
NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-../../../}"
CHAIN_ID="${CHAIN_ID:-local-wasm-upgrade}"
MONIKER="${MONIKER:-localterp-d}"
DENOM="${DENOM:-uterp}"
KEYALGO="${KEYALGO:-secp256k1}"
KEYRING="${KEYRING:-test}"
HOME_DIR="${HOME_DIR:-$HOME/.terpd-d}"
CLEAN="${CLEAN:-true}"
RPC="${RPC:-27657}"
REST="${REST:-1327}"
P2P="${P2P:-27656}"
GRPC="${GRPC:-9097}"
TIMEOUT_COMMIT="${TIMEOUT_COMMIT:-1s}"
HALT_DELTA="${HALT_DELTA:-16}"
POST_BLOCKS="${POST_BLOCKS:-5}"
OLD_LOG="${OLD_LOG:-/tmp/tsh-d-old.log}"
NEW_LOG="${NEW_LOG:-/tmp/tsh-d-new.log}"
OLD_PID=""
NEW_PID=""
NODE="tcp://127.0.0.1:${RPC}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WASM="${WASM:-$HERE/../../../artifacts/cw_template.wasm}"

command -v "$OLD_BIND" >/dev/null || { echo "$OLD_BIND not found"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
[ -f "$WASM" ] || { echo "missing legacy wasm at $WASM"; exit 1; }

rpc() { curl -sf "http://127.0.0.1:${RPC}/status"; }
rpc_height() { rpc | jq -r '.result.sync_info.latest_block_height'; }
wait_rpc() {
  for _ in $(seq 1 60); do
    local cid
    cid=$(rpc 2>/dev/null | jq -r ".result.node_info.network // empty") || true
    if [ "$cid" = "$CHAIN_ID" ]; then return 0; fi
    sleep 1
  done
  echo "RPC down or wrong chain (want $CHAIN_ID). old log:"; tail -40 "$OLD_LOG" 2>/dev/null || true
  return 1
}
wait_blocks() {
  local n="${1:-2}"
  local h0 h
  h0=$(rpc_height)
  for _ in $(seq 1 40); do
    h=$(rpc_height || echo "$h0")
    if [ "$h" -ge $((h0 + n)) ]; then return 0; fi
    sleep 1
  done
  echo "did not advance $n blocks from $h0"; return 1
}

applied_height() {
  "$NEW_BIND" q upgrade applied "$UPGRADE_VERSION_TITLE" \
    --home "$HOME_DIR" --node "$NODE" -o json 2>/dev/null \
    | jq -r '.height // empty'
}

tx() {
  local bind="$1"; shift
  local json
  json=$("$bind" tx "$@" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
    --keyring-backend "$KEYRING" --node "$NODE" \
    --output json -y)
  echo "$json" >&2
  local code
  code=$(echo "$json" | jq -r '.code // 0')
  if [ "$code" != "0" ]; then
    echo "tx failed code=$code log=$(echo "$json" | jq -r '.raw_log // empty')"
    return 1
  fi
  wait_blocks 2
}

q() {
  local bind="$1"; shift
  "$bind" q "$@" --home "$HOME_DIR" --node "$NODE" -o json
}

code_checksum() {
  local bind="$1" id="$2"
  q "$bind" wasm code-info "$id" | jq -r '.data_hash // .checksum // empty'
}

query_count() {
  local bind="$1" addr="$2"
  q "$bind" wasm contract-state smart "$addr" '{"get_count":{}}' | jq -r '.data.count // .count // empty'
}

tune_config() {
  local cfg="$HOME_DIR/config/config.toml"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${RPC}\"/" "$cfg"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^pprof_laddr *=.*/pprof_laddr = \"localhost:16062\"/" "$cfg"
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

cleanup() {
  kill "${OLD_PID:-}" 2>/dev/null || true
  kill "${NEW_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

if [ "${SKIP_INSTALL:-0}" = "1" ]; then
  echo "D: SKIP_INSTALL=1 — using existing $NEW_BIND"
else
  echo "D: make install NEW_BIND=$NEW_BIND"
  ( cd "$NEW_RELEASE_PATH" && make install )
fi
command -v "$NEW_BIND" >/dev/null || { echo "$NEW_BIND not on PATH"; exit 1; }
echo "D: OLD=$OLD_BIND ($("$OLD_BIND" version | head -1)) NEW=$NEW_BIND ($("$NEW_BIND" version | head -1))"
echo "D: legacy wasm $WASM ($(wc -c < "$WASM") bytes)"

if [ "$CLEAN" != "false" ]; then
  from_scratch
  tune_config
fi

: > "$OLD_LOG"
"$OLD_BIND" start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC" ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$OLD_LOG" 2>&1 &
OLD_PID=$!
wait_rpc
wait_blocks 1

echo "D: store+instantiate+execute on OLD_BIND (pre-bulk_memory VM)"
tx "$OLD_BIND" wasm store "$WASM" --from "$KEY" --gas auto --gas-adjustment 1.5 --fees "400000$DENOM"
CODE_ID=$(q "$OLD_BIND" wasm list-code | jq -r '.code_infos[0].code_id // .code_infos[0].id')
[ -n "$CODE_ID" ] && [ "$CODE_ID" != "null" ] || { echo "D: no code_id after store"; exit 1; }
PRE_SUM=$(code_checksum "$OLD_BIND" "$CODE_ID")
[ -n "$PRE_SUM" ] || { echo "D: empty checksum"; exit 1; }
echo "D: code_id=$CODE_ID checksum=$PRE_SUM"

tx "$OLD_BIND" wasm instantiate "$CODE_ID" '{"count":0}' --label "pre-v6-guest" --no-admin \
  --from "$KEY" --gas auto --gas-adjustment 1.4 --fees "400000$DENOM"
ADDR=$(q "$OLD_BIND" wasm list-contract-by-code "$CODE_ID" | jq -r '.contracts[0]')
[ -n "$ADDR" ] && [ "$ADDR" != "null" ] || { echo "D: no contract address"; exit 1; }
echo "D: instantiated $ADDR"

COUNT0=$(query_count "$OLD_BIND" "$ADDR")
[ "$COUNT0" = "0" ] || { echo "D: expected count 0 got $COUNT0"; exit 1; }
tx "$OLD_BIND" wasm execute "$ADDR" '{"increment":{}}' --from "$KEY" \
  --gas auto --gas-adjustment 1.4 --fees "400000$DENOM"
COUNT1=$(query_count "$OLD_BIND" "$ADDR")
[ "$COUNT1" = "1" ] || { echo "D: expected count 1 after increment got $COUNT1"; exit 1; }
echo "D: pre-upgrade execute ok count=$COUNT1"

H0=$(rpc_height)
HALT=$((H0 + HALT_DELTA))
echo "D: proposing $UPGRADE_VERSION_TITLE at height $HALT (now $H0) pid=$OLD_PID"

cat > "$HOME_DIR/upgrade.json" <<JSON
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
  "summary": "v6 CosmWasm VM meters bulk_memory; existing guests must keep working",
  "expedited": true
}
JSON

tx "$OLD_BIND" gov submit-proposal "$HOME_DIR/upgrade.json" --from "$KEY" \
  --gas auto --gas-adjustment 1.5 --fees "2000$DENOM"
tx "$OLD_BIND" gov vote 1 yes --from "$KEY" --gas auto --gas-adjustment 1.2 --fees "1000$DENOM"
tx "$OLD_BIND" gov vote 1 yes --from "$KEY2" --gas auto --gas-adjustment 1.2 --fees "1000$DENOM"

echo "D: waiting for UPGRADE NEEDED at $HALT"
for i in $(seq 1 180); do
  if ! kill -0 "$OLD_PID" 2>/dev/null; then
    echo "D: OLD_BIND exited"
    break
  fi
  if grep -q "UPGRADE \"${UPGRADE_VERSION_TITLE}\" NEEDED" "$OLD_LOG" 2>/dev/null; then
    echo "D: halt signal"
    kill "$OLD_PID" 2>/dev/null || true
    wait "$OLD_PID" 2>/dev/null || true
    break
  fi
  echo "  pre-upgrade h=$(rpc_height || echo ?) halt=$HALT try=$i"
  sleep 1
done
wait "$OLD_PID" 2>/dev/null || true
OLD_PID=""
sleep 2

if [ ! -f "$HOME_DIR/data/upgrade-info.json" ]; then
  echo "D: missing upgrade-info.json"
  tail -40 "$OLD_LOG"
  exit 1
fi
if ! grep -q "UPGRADE \"${UPGRADE_VERSION_TITLE}\" NEEDED" "$OLD_LOG"; then
  echo "D: no UPGRADE NEEDED in old log"
  tail -40 "$OLD_LOG"
  exit 1
fi
echo "D: upgrade-info.json=$(cat "$HOME_DIR/data/upgrade-info.json")"

: > "$NEW_LOG"
"$NEW_BIND" start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC" ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$NEW_LOG" 2>&1 &
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
    echo "D: NEW_BIND died"; tail -50 "$NEW_LOG"; exit 1
  fi
  sleep 2
done
if [ -z "$APPLIED_H" ] || [ "$APPLIED_H" = "0" ]; then
  echo "D: $UPGRADE_VERSION_TITLE not applied"; tail -50 "$NEW_LOG"; exit 1
fi

AFTER=$(rpc_height)
TARGET=$((AFTER + POST_BLOCKS))
echo "D: waiting for $POST_BLOCKS good blocks (from $AFTER to >= $TARGET)"
for i in $(seq 1 120); do
  h=$(rpc_height || echo 0)
  echo "  post-apply h=$h target=$TARGET try=$i"
  if [ "$h" -ge "$TARGET" ]; then break; fi
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "D: NEW_BIND died producing blocks"; tail -50 "$NEW_LOG"; exit 1
  fi
  sleep 2
done
h=$(rpc_height)
if [ "$h" -lt "$TARGET" ]; then
  echo "D: did not produce post-upgrade blocks"; exit 1
fi

echo "D: asserting pre-upgrade contract still works on bulk_memory VM"
POST_SUM=$(code_checksum "$NEW_BIND" "$CODE_ID")
[ "$POST_SUM" = "$PRE_SUM" ] || {
  echo "D: checksum changed across upgrade pre=$PRE_SUM post=$POST_SUM"
  exit 1
}
POST_ADDR=$(q "$NEW_BIND" wasm list-contract-by-code "$CODE_ID" | jq -r '.contracts[0]')
[ "$POST_ADDR" = "$ADDR" ] || {
  echo "D: contract address changed pre=$ADDR post=$POST_ADDR"
  exit 1
}
COUNT_KEEP=$(query_count "$NEW_BIND" "$ADDR")
[ "$COUNT_KEEP" = "$COUNT1" ] || {
  echo "D: state lost across upgrade expected $COUNT1 got $COUNT_KEEP"
  exit 1
}
tx "$NEW_BIND" wasm execute "$ADDR" '{"increment":{}}' --from "$KEY" \
  --gas auto --gas-adjustment 1.4 --fees "400000$DENOM"
COUNT2=$(query_count "$NEW_BIND" "$ADDR")
[ "$COUNT2" = "2" ] || {
  echo "D: post-upgrade execute bricked expected 2 got $COUNT2"
  exit 1
}

echo "D: PASS existing guest survived v6 bulk_memory VM upgrade"
echo "D:   code_id=$CODE_ID checksum=$POST_SUM addr=$ADDR"
echo "D:   count pre-upgrade=$COUNT1 post-query=$COUNT_KEEP post-execute=$COUNT2"
echo "D:   applied=$UPGRADE_VERSION_TITLE at $APPLIED_H height=$h"
