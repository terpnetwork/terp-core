#!/usr/bin/env bash
# CosmWasm guest survival across the hasher two-step.
# PHASE=pre  — store + instantiate + increment on v63pre (before v6.3).
# PHASE=post — same code_id/address still queries; increment still works on v6.4.
set -euo pipefail

PHASE="${PHASE:?}"
BIND="${BIND:?}"
HOME_DIR="${HOME_DIR:?}"
NODE="${NODE:?}"
CHAIN_ID="${CHAIN_ID:-local-1}"
KEY="${KEY:-terp1}"
KEYRING="${KEYRING:-test}"
DENOM="${DENOM:-uterp}"
WASM="${WASM:-}"
STATE="${STATE:-$HOME_DIR/hasher_wasm.state}"

q() { "$BIND" q "$@" --home "$HOME_DIR" --node "$NODE" -o json; }

wait_blocks() {
  local n="${1:-2}"
  local h0 h
  h0="$("$BIND" status --node "$NODE" -o json 2>/dev/null | jq -r '.sync_info.latest_block_height // .SyncInfo.latest_block_height // empty')"
  if [ -z "$h0" ]; then
    h0="$(curl -sf "${NODE#tcp://}/status" | jq -r '.result.sync_info.latest_block_height')"
  fi
  for _ in $(seq 1 40); do
    h="$(curl -sf "http://${NODE#tcp://}/status" | jq -r '.result.sync_info.latest_block_height')"
    if [ "${h:-0}" -ge $((h0 + n)) ] 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "hasher_wasm: did not advance $n blocks from $h0"
  return 1
}

tx() {
  local out code
  out="$("$BIND" tx "$@" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
    --keyring-backend "$KEYRING" --node "$NODE" --output json -y 2>/dev/null)" || true
  code="$(printf '%s' "$out" | jq -Rs 'try (split("\n") | map(select(startswith("{") and endswith("}"))) | last | fromjson | .code) catch 1')"
  if [ "$code" != "0" ]; then
    echo "hasher_wasm: tx failed code=$code"
    printf '%s\n' "$out"
    return 1
  fi
  wait_blocks 2
}

query_count() {
  local addr=$1
  q wasm contract-state smart "$addr" '{"get_count":{}}' | jq -r '.data.count // .count // empty'
}

code_checksum() {
  q wasm code-info "$1" | jq -r '.data_hash // .checksum // empty'
}

rpc_port() {
  local n="${NODE#tcp://}"
  echo "${n##*:}"
}

wait_height() {
  local port
  port="$(rpc_port)"
  for _ in $(seq 1 30); do
    local h
    h="$(curl -sf "http://127.0.0.1:${port}/status" | jq -r '.result.sync_info.latest_block_height // "0"')"
    if [ "${h:-0}" -ge 2 ] 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if [ "$PHASE" = "pre" ]; then
  [ -s "$WASM" ] || { echo "hasher_wasm: missing guest $WASM"; exit 1; }
  wait_height || { echo "hasher_wasm: chain produced no block"; exit 1; }
  echo "hasher_wasm: store+instantiate+execute on $BIND ($WASM)"
  tx wasm store "$WASM" --from "$KEY" --gas auto --gas-adjustment 1.5 --fees "400000$DENOM"
  CODE_ID="$(q wasm list-code | jq -r '.code_infos[0].code_id // .code_infos[0].id // empty')"
  [ -n "$CODE_ID" ] && [ "$CODE_ID" != "null" ] || { echo "hasher_wasm: no code_id"; exit 1; }
  PRE_SUM="$(code_checksum "$CODE_ID")"
  [ -n "$PRE_SUM" ] || { echo "hasher_wasm: empty checksum"; exit 1; }
  tx wasm instantiate "$CODE_ID" '{"count":0}' --label "pre-v63-guest" --no-admin \
    --from "$KEY" --gas auto --gas-adjustment 1.4 --fees "400000$DENOM"
  ADDR="$(q wasm list-contract-by-code "$CODE_ID" | jq -r '.contracts[0] // empty')"
  [ -n "$ADDR" ] && [ "$ADDR" != "null" ] || { echo "hasher_wasm: no contract address"; exit 1; }
  COUNT0="$(query_count "$ADDR")"
  [ "$COUNT0" = "0" ] || { echo "hasher_wasm: expected count 0 got $COUNT0"; exit 1; }
  tx wasm execute "$ADDR" '{"increment":{}}' --from "$KEY" \
    --gas auto --gas-adjustment 1.4 --fees "400000$DENOM"
  COUNT1="$(query_count "$ADDR")"
  [ "$COUNT1" = "1" ] || { echo "hasher_wasm: expected count 1 got $COUNT1"; exit 1; }
  cat > "$STATE" <<EOF
CODE_ID=$CODE_ID
ADDR=$ADDR
PRE_SUM=$PRE_SUM
COUNT=$COUNT1
EOF
  echo "hasher_wasm: pre-upgrade ok code_id=$CODE_ID addr=$ADDR count=$COUNT1 checksum=$PRE_SUM"
  exit 0
fi

if [ "$PHASE" = "post" ]; then
  [ -s "$STATE" ] || { echo "hasher_wasm: missing $STATE"; exit 1; }
  # shellcheck disable=SC1090
  . "$STATE"
  POST_SUM="$(code_checksum "$CODE_ID")"
  [ "$POST_SUM" = "$PRE_SUM" ] || {
    echo "hasher_wasm: checksum changed $PRE_SUM -> $POST_SUM"
    exit 1
  }
  COUNT="$(query_count "$ADDR")"
  [ "$COUNT" = "1" ] || { echo "hasher_wasm: expected count 1 after upgrade got $COUNT"; exit 1; }
  tx wasm execute "$ADDR" '{"increment":{}}' --from "$KEY" \
    --gas auto --gas-adjustment 1.4 --fees "400000$DENOM"
  COUNT2="$(query_count "$ADDR")"
  [ "$COUNT2" = "2" ] || { echo "hasher_wasm: expected count 2 after post increment got $COUNT2"; exit 1; }
  echo "hasher_wasm: post-upgrade ok same checksum=$POST_SUM count=$COUNT2"
  exit 0
fi

echo "hasher_wasm: PHASE must be pre or post"
exit 1
