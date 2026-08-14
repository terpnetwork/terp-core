#!/usr/bin/env bash
####################################################################
# TEST C: two local chains, each: OLD_BIND gov software-upgrade v6 → halt
# → NEW_BIND start → applied height + POST_BLOCKS → Hermes + polytone
# note↔voice (existing tsh/polytone + helpers/relayer, un-bitrotted).
####################################################################
set -euo pipefail

OLD_BIND="${OLD_BIND:-terp-mainnet}"
NEW_BIND="${NEW_BIND:-terpd}"
UPGRADE_VERSION_TITLE="${UPGRADE_VERSION_TITLE:-v6}"
NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-../../../}"
KEY="${KEY:-terp1}"
KEY2="${KEY2:-terp2}"
DENOM="${DENOM:-uterp}"
KEYRING="${KEYRING:-test}"
KEYALGO="${KEYALGO:-secp256k1}"
TIMEOUT_COMMIT="${TIMEOUT_COMMIT:-1s}"
HALT_DELTA="${HALT_DELTA:-15}"
POST_BLOCKS="${POST_BLOCKS:-5}"
CLEAN="${CLEAN:-true}"

HOME1="${HOME1:-$HOME/.terpd-c1}"
HOME2="${HOME2:-$HOME/.terpd-c2}"
ID1="${ID1:-local-1}"
ID2="${ID2:-local-2}"
RPC1="${RPC1:-26957}"
RPC2="${RPC2:-23957}"
P2P1="${P2P1:-26956}"
P2P2="${P2P2:-23956}"
GRPC1="${GRPC1:-19090}"
GRPC2="${GRPC2:-19091}"
RELAYER="${RELAYER:-relayer}"
WASM_DIR="${WASM_DIR:-../../../artifacts}"
HERMES_BIN="${HERMES_BIN:-$HOME/go/bin/hermes}"
HERMES_VER="${HERMES_VER:-v1.13.2}"
OLD_LOG1="${OLD_LOG1:-/tmp/tsh-c1-old.log}"
OLD_LOG2="${OLD_LOG2:-/tmp/tsh-c2-old.log}"
NEW_LOG1="${NEW_LOG1:-/tmp/tsh-c1-new.log}"
NEW_LOG2="${NEW_LOG2:-/tmp/tsh-c2-new.log}"

command -v "$OLD_BIND" >/dev/null || { echo "$OLD_BIND not found"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

rpc_h() { curl -sf "http://127.0.0.1:$1/status" | jq -r '.result.sync_info.latest_block_height'; }
wait_rpc() {
  local port=$1
  for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$port/status" >/dev/null && return 0; sleep 1; done
  echo "rpc :$port down"; return 1
}

applied_h() {
  local home=$1 port=$2
  "$NEW_BIND" q upgrade applied "$UPGRADE_VERSION_TITLE" \
    --home "$home" --node "tcp://127.0.0.1:${port}" -o json 2>/dev/null \
    | jq -r '.height // empty'
}

init_home() {
  local home=$1 id=$2 rpc=$3 p2p=$4 grpc=$5
  rm -rf "$home"
  echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry" | \
    "$OLD_BIND" keys add "$KEY" --home "$home" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover
  echo "wealth flavor believe regret funny network recall kiss grape useless pepper cram hint member few certain unveil rather brick bargain curious require crowd raise" | \
    "$OLD_BIND" keys add "$KEY2" --home "$home" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover
  if [ ! -s /tmp/c-relayer.mnemonic ]; then
    set +o pipefail
    yes | "$OLD_BIND" keys add "$RELAYER" --home "$home" --keyring-backend "$KEYRING" --algo "$KEYALGO" --output json > "$home/relayer.json" 2>&1
    set -o pipefail
    jq -r '.mnemonic' "$home/relayer.json" > /tmp/c-relayer.mnemonic
  else
    "$OLD_BIND" keys add "$RELAYER" --home "$home" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover < /tmp/c-relayer.mnemonic
  fi
  "$OLD_BIND" init localterp --home "$home" --chain-id "$id" --default-denom "$DENOM"
  jq '.app_state.gov.params.voting_period="15s" | .app_state.gov.params.expedited_voting_period="5s" | .app_state.gov.params.min_deposit=[{"denom":"uterp","amount":"1000000"}] | .app_state.staking.params.bond_denom="uterp" | .app_state.mint.params.mint_denom="uterp"' \
    "$home/config/genesis.json" > "$home/config/tmp.json"
  mv "$home/config/tmp.json" "$home/config/genesis.json"
  "$OLD_BIND" genesis add-genesis-account "$KEY" 1000000000000uterp --home "$home" --keyring-backend "$KEYRING"
  "$OLD_BIND" genesis add-genesis-account "$KEY2" 100000000000uterp --home "$home" --keyring-backend "$KEYRING"
  "$OLD_BIND" genesis add-genesis-account "$RELAYER" 1000000000000uterp --home "$home" --keyring-backend "$KEYRING"
  "$OLD_BIND" genesis gentx "$KEY" 10000000000uterp --home "$home" --keyring-backend "$KEYRING" --chain-id "$id"
  "$OLD_BIND" genesis collect-gentxs --home "$home"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${rpc}\"/" "$home/config/config.toml"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^pprof_laddr *=.*/pprof_laddr = \"localhost:16${rpc: -3}\"/" "$home/config/config.toml"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${p2p}\"/" "$home/config/config.toml"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^pex *=.*/pex = false/" "$home/config/config.toml"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^seeds *=.*/seeds = \"\"/" "$home/config/config.toml"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^persistent_peers *=.*/persistent_peers = \"\"/" "$home/config/config.toml"
  sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"${TIMEOUT_COMMIT}\"/" "$home/config/config.toml"
  sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"127.0.0.1:${grpc}\"/" "$home/config/app.toml" || true
}

propose_v6() {
  local home=$1 id=$2 halt=$3 rpc=$4
  cat > "$home/upgrade.json" <<EOF
{
  "messages": [{
    "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
    "authority": "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
    "plan": {"name": "$UPGRADE_VERSION_TITLE", "time": "0001-01-01T00:00:00Z", "height": "$halt", "info": "", "upgraded_client_state": null}
  }],
  "metadata": "",
  "deposit": "5000000000$DENOM",
  "title": "$UPGRADE_VERSION_TITLE",
  "summary": "v6 sdk 0.54 / ibc-go 11.1",
  "expedited": true
}
EOF
  "$OLD_BIND" tx gov submit-proposal "$home/upgrade.json" --from "$KEY" --home "$home" --chain-id "$id" \
    --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${rpc}" \
    --gas auto --gas-adjustment 1.5 --fees "2000$DENOM" -y
  sleep 2
  "$OLD_BIND" tx gov vote 1 yes --from "$KEY" --home "$home" --chain-id "$id" \
    --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${rpc}" \
    --gas auto --gas-adjustment 1.2 --fees "1000$DENOM" -y
  sleep 2
  "$OLD_BIND" tx gov vote 1 yes --from "$KEY2" --home "$home" --chain-id "$id" \
    --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${rpc}" \
    --gas auto --gas-adjustment 1.2 --fees "1000$DENOM" -y
  sleep 2
}

wait_halt() {
  local pid=$1 log=$2
  for _ in $(seq 1 180); do
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    if grep -q "UPGRADE \"${UPGRADE_VERSION_TITLE}\" NEEDED" "$log" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "C: make install NEW_BIND=$NEW_BIND"
( cd "$NEW_RELEASE_PATH" && make install )
command -v "$NEW_BIND" >/dev/null || { echo "$NEW_BIND not on PATH"; exit 1; }
echo "C: OLD=$OLD_BIND ($("$OLD_BIND" version | head -1)) NEW=$NEW_BIND ($("$NEW_BIND" version | head -1))"

if [ "$CLEAN" != "false" ]; then
  rm -f /tmp/c-relayer.mnemonic
  init_home "$HOME1" "$ID1" "$RPC1" "$P2P1" "$GRPC1"
  init_home "$HOME2" "$ID2" "$RPC2" "$P2P2" "$GRPC2"
fi

: > "$OLD_LOG1"; : > "$OLD_LOG2"
"$OLD_BIND" start --home "$HOME1" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC1" >>"$OLD_LOG1" 2>&1 &
PID1=$!
"$OLD_BIND" start --home "$HOME2" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC2" >>"$OLD_LOG2" 2>&1 &
PID2=$!
wait_rpc "$RPC1"
wait_rpc "$RPC2"
for _ in $(seq 1 60); do
  a=$(rpc_h "$RPC1" || echo 0)
  b=$(rpc_h "$RPC2" || echo 0)
  if [ "${a:-0}" -ge 1 ] && [ "${b:-0}" -ge 1 ]; then
    break
  fi
  sleep 1
done
H1=$(rpc_h "$RPC1")
if [ "${H1:-0}" -lt 1 ]; then
  echo "C: no first block yet"; exit 1
fi
HALT=$((H1 + HALT_DELTA))
echo "C: proposing $UPGRADE_VERSION_TITLE halt=$HALT"
propose_v6 "$HOME1" "$ID1" "$HALT" "$RPC1"
propose_v6 "$HOME2" "$ID2" "$HALT" "$RPC2"

echo "C: waiting for UPGRADE NEEDED on both"
wait_halt "$PID1" "$OLD_LOG1" || { echo "C: c1 did not halt"; tail -30 "$OLD_LOG1"; exit 1; }
wait_halt "$PID2" "$OLD_LOG2" || { echo "C: c2 did not halt"; tail -30 "$OLD_LOG2"; exit 1; }
sleep 2

for home in "$HOME1" "$HOME2"; do
  if [ ! -f "$home/data/upgrade-info.json" ]; then
    echo "C: missing $home/data/upgrade-info.json"; exit 1
  fi
  echo "C: $home info=$(cat "$home/data/upgrade-info.json")"
done

: > "$NEW_LOG1"; : > "$NEW_LOG2"
"$NEW_BIND" start --home "$HOME1" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC1" >>"$NEW_LOG1" 2>&1 &
NPID1=$!
"$NEW_BIND" start --home "$HOME2" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC2" >>"$NEW_LOG2" 2>&1 &
NPID2=$!
wait_rpc "$RPC1"
wait_rpc "$RPC2"

ok_applied() {
  local home=$1 port=$2
  local ah
  for _ in $(seq 1 120); do
    ah=$(applied_h "$home" "$port" || true)
    if [ -n "$ah" ] && [ "$ah" != "0" ]; then
      echo "$ah"
      return 0
    fi
    sleep 2
  done
  return 1
}

A1=$(ok_applied "$HOME1" "$RPC1") || { echo "C: c1 not applied"; tail -40 "$NEW_LOG1"; exit 1; }
A2=$(ok_applied "$HOME2" "$RPC2") || { echo "C: c2 not applied"; tail -40 "$NEW_LOG2"; exit 1; }
echo "C: applied c1=$A1 c2=$A2"

T1=$(( $(rpc_h "$RPC1") + POST_BLOCKS ))
T2=$(( $(rpc_h "$RPC2") + POST_BLOCKS ))
echo "C: waiting post-upgrade blocks t1=$T1 t2=$T2"
for _ in $(seq 1 120); do
  a=$(rpc_h "$RPC1" || echo 0)
  b=$(rpc_h "$RPC2" || echo 0)
  echo "  c1=$a/$T1 c2=$b/$T2"
  if [ "$a" -ge "$T1" ] && [ "$b" -ge "$T2" ]; then break; fi
  if ! kill -0 "$NPID1" 2>/dev/null || ! kill -0 "$NPID2" 2>/dev/null; then
    echo "C: new binary died"; exit 1
  fi
  sleep 2
done
a=$(rpc_h "$RPC1"); b=$(rpc_h "$RPC2")
if [ "$a" -lt "$T1" ] || [ "$b" -lt "$T2" ]; then
  echo "C: missing post-upgrade blocks"; exit 1
fi

"$NEW_BIND" q wasm params --home "$HOME1" --node "tcp://127.0.0.1:${RPC1}" -o json | jq '.circuit_upload_access.permission // .'
"$NEW_BIND" q tokenfactory params --home "$HOME1" --node "tcp://127.0.0.1:${RPC1}" -o json | jq .
"$NEW_BIND" q wasm params --home "$HOME2" --node "tcp://127.0.0.1:${RPC2}" -o json | jq '.circuit_upload_access.permission // .'
"$NEW_BIND" q tokenfactory params --home "$HOME2" --node "tcp://127.0.0.1:${RPC2}" -o json | jq .
echo "C: both nodes upgraded applied=$UPGRADE_VERSION_TITLE h1=$a h2=$b"

ensure_hermes() {
  if command -v "$HERMES_BIN" >/dev/null; then
    return 0
  fi
  echo "C: installing hermes $HERMES_VER to $HOME/go/bin"
  mkdir -p "$HOME/go/bin" /tmp/hermes-dl
  local url="https://github.com/informalsystems/hermes/releases/download/${HERMES_VER}/hermes-${HERMES_VER}-aarch64-apple-darwin.tar.gz"
  curl -fL --retry 3 -o /tmp/hermes-dl/hermes.tgz "$url"
  tar -xzf /tmp/hermes-dl/hermes.tgz -C /tmp/hermes-dl
  install -m 0755 /tmp/hermes-dl/hermes "$HOME/go/bin/hermes"
  HERMES_BIN="$HOME/go/bin/hermes"
}

write_hermes_cfg() {
  mkdir -p "$HOME/.hermes"
  cat > "$HOME/.hermes/config.toml" <<EOF
[global]
log_level = "info"

[mode.clients]
enabled = true
refresh = true
misbehaviour = true
[mode.connections]
enabled = true
[mode.channels]
enabled = true
[mode.packets]
enabled = true
clear_interval = 100
clear_on_start = true
tx_confirmation = true

[[chains]]
id = "$ID1"
type = "CosmosSdk"
rpc_addr = "http://127.0.0.1:$RPC1"
grpc_addr = "http://127.0.0.1:$GRPC1"
event_source = { mode = "push", url = "ws://127.0.0.1:$RPC1/websocket", batch_delay = "500ms" }
rpc_timeout = "10s"
account_prefix = "terp"
key_name = "$RELAYER"
store_prefix = "ibc"
compat_mode = "0.38"
default_gas = 200000
max_gas = 4000000
gas_multiplier = 1.3
gas_price = { price = 0.1, denom = "$DENOM" }
clock_drift = "5s"
max_block_time = "30s"
trust_threshold = { numerator = "1", denominator = "3" }
address_type = { derivation = "cosmos" }

[[chains]]
id = "$ID2"
type = "CosmosSdk"
rpc_addr = "http://127.0.0.1:$RPC2"
grpc_addr = "http://127.0.0.1:$GRPC2"
event_source = { mode = "push", url = "ws://127.0.0.1:$RPC2/websocket", batch_delay = "500ms" }
rpc_timeout = "10s"
account_prefix = "terp"
key_name = "$RELAYER"
store_prefix = "ibc"
compat_mode = "0.38"
default_gas = 200000
max_gas = 4000000
gas_multiplier = 1.3
gas_price = { price = 0.1, denom = "$DENOM" }
clock_drift = "5s"
max_block_time = "30s"
trust_threshold = { numerator = "1", denominator = "3" }
address_type = { derivation = "cosmos" }
EOF
}

store_one() {
  local home=$1 rpc=$2 id=$3 wasm=$4
  "$NEW_BIND" tx wasm store "$wasm" --from "$KEY" --home "$home" --chain-id "$id" \
    --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${rpc}" \
    --gas auto --gas-adjustment 1.5 --fees "400000$DENOM" -y
  sleep 3
}

lca() {
  local home=$1 rpc=$2 code=$3
  "$NEW_BIND" q wasm list-contract-by-code "$code" --home "$home" --node "tcp://127.0.0.1:${rpc}" -o json \
    | jq -r '.contracts[0] // empty'
}

echo "C: polytone + hermes (post-upgrade)"
ensure_hermes
command -v "$HERMES_BIN" >/dev/null || { echo "C: hermes missing"; exit 1; }

for f in polytone_listener.wasm polytone_note.wasm polytone_proxy.wasm polytone_voice.wasm polytone_tester.wasm; do
  [ -f "$WASM_DIR/$f" ] || { echo "C: missing $WASM_DIR/$f"; exit 1; }
done

for pair in "$HOME1 $RPC1 $ID1" "$HOME2 $RPC2 $ID2"; do
  set -- $pair
  echo "C: store polytone wasm on $3"
  store_one "$1" "$2" "$3" "$WASM_DIR/polytone_listener.wasm"
  store_one "$1" "$2" "$3" "$WASM_DIR/polytone_note.wasm"
  store_one "$1" "$2" "$3" "$WASM_DIR/polytone_proxy.wasm"
  store_one "$1" "$2" "$3" "$WASM_DIR/polytone_voice.wasm"
  store_one "$1" "$2" "$3" "$WASM_DIR/polytone_tester.wasm"
done

NOTE_ID=2
VOICE_ID=4
TESTER_ID=5
LISTENER_ID=1

inst() {
  local home=$1 rpc=$2 id=$3 code=$4 msg=$5 label=$6
  "$NEW_BIND" tx wasm instantiate "$code" "$msg" --from "$KEY" --home "$home" --chain-id "$id" \
    --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${rpc}" \
    --no-admin --label "$label" --gas auto --gas-adjustment 1.4 --fees "400000$DENOM" -y
  sleep 3
}

inst "$HOME1" "$RPC1" "$ID1" "$NOTE_ID" '{"block_max_gas":"100000000"}' "note-c1"
inst "$HOME2" "$RPC2" "$ID2" "$NOTE_ID" '{"block_max_gas":"100000000"}' "note-c2"
inst "$HOME1" "$RPC1" "$ID1" "$VOICE_ID" '{"proxy_code_id":"3","block_max_gas":"100000000"}' "voice-c1"
inst "$HOME2" "$RPC2" "$ID2" "$VOICE_ID" '{"proxy_code_id":"3","block_max_gas":"100000000"}' "voice-c2"
inst "$HOME1" "$RPC1" "$ID1" "$TESTER_ID" '{}' "tester-c1"
inst "$HOME2" "$RPC2" "$ID2" "$TESTER_ID" '{}' "tester-c2"

NOTE_A=$(lca "$HOME1" "$RPC1" "$NOTE_ID")
NOTE_B=$(lca "$HOME2" "$RPC2" "$NOTE_ID")
VOICE_A=$(lca "$HOME1" "$RPC1" "$VOICE_ID")
VOICE_B=$(lca "$HOME2" "$RPC2" "$VOICE_ID")
TESTER_A=$(lca "$HOME1" "$RPC1" "$TESTER_ID")
TESTER_B=$(lca "$HOME2" "$RPC2" "$TESTER_ID")
echo "C: note_a=$NOTE_A note_b=$NOTE_B voice_a=$VOICE_A voice_b=$VOICE_B tester_a=$TESTER_A tester_b=$TESTER_B"
[ -n "$NOTE_A" ] && [ -n "$NOTE_B" ] && [ -n "$VOICE_A" ] && [ -n "$VOICE_B" ] || { echo "C: missing contract addrs"; exit 1; }

inst "$HOME1" "$RPC1" "$ID1" "$LISTENER_ID" "{\"note\":\"$NOTE_A\"}" "listener-c1"
inst "$HOME2" "$RPC2" "$ID2" "$LISTENER_ID" "{\"note\":\"$NOTE_B\"}" "listener-c2"

write_hermes_cfg
"$HERMES_BIN" keys delete --chain "$ID1" --all || true
"$HERMES_BIN" keys delete --chain "$ID2" --all || true
"$HERMES_BIN" keys add --key-name "$RELAYER" --chain "$ID1" --hd-path "m/44'/118'/0'/0/0" --mnemonic-file /tmp/c-relayer.mnemonic
"$HERMES_BIN" keys add --key-name "$RELAYER" --chain "$ID2" --hd-path "m/44'/118'/0'/0/0" --mnemonic-file /tmp/c-relayer.mnemonic

echo "C: hermes create note_a ↔ voice_b"
"$HERMES_BIN" create channel --a-chain "$ID1" --b-chain "$ID2" \
  --a-port "wasm.$NOTE_A" --b-port "wasm.$VOICE_B" \
  --order unordered --chan-version polytone-1 --new-client-connection --yes
echo "C: hermes create note_b ↔ voice_a"
"$HERMES_BIN" create channel --a-chain "$ID2" --b-chain "$ID1" \
  --a-port "wasm.$NOTE_B" --b-port "wasm.$VOICE_A" \
  --order unordered --chan-version polytone-1 --new-client-connection --yes

"$HERMES_BIN" start > /tmp/tsh-c-hermes.log 2>&1 &
HERMES_PID=$!
sleep 5

echo "C: execute empty polytone notes + callback to testers"
"$NEW_BIND" tx wasm execute "$NOTE_A" \
  "{\"execute\":{\"msgs\":[],\"timeout_seconds\":\"300\",\"callback\":{\"receiver\":\"$TESTER_A\",\"msg\":\"aGVsbG8K\"}}}" \
  --from "$KEY" --home "$HOME1" --chain-id "$ID1" --keyring-backend "$KEYRING" \
  --node "tcp://127.0.0.1:${RPC1}" --gas auto --gas-adjustment 1.4 --fees "400000$DENOM" -y
sleep 3
"$NEW_BIND" tx wasm execute "$NOTE_B" \
  "{\"execute\":{\"msgs\":[],\"timeout_seconds\":\"300\",\"callback\":{\"receiver\":\"$TESTER_B\",\"msg\":\"aGVsbG8K\"}}}" \
  --from "$KEY" --home "$HOME2" --chain-id "$ID2" --keyring-backend "$KEYRING" \
  --node "tcp://127.0.0.1:${RPC2}" --gas auto --gas-adjustment 1.4 --fees "400000$DENOM" -y
sleep 2
"$HERMES_BIN" clear packets --chain "$ID1" --port "wasm.$NOTE_A" --channel channel-0 || true
"$HERMES_BIN" clear packets --chain "$ID2" --port "wasm.$NOTE_B" --channel channel-1 || true
"$HERMES_BIN" clear packets --chain "$ID2" --port "wasm.$NOTE_B" --channel channel-0 || true

echo "C: wait for hermes packets"
ok=0
for i in $(seq 1 40); do
  HA=$("$NEW_BIND" q wasm contract-state smart "$TESTER_A" '{"history":{}}' --home "$HOME1" --node "tcp://127.0.0.1:${RPC1}" -o json 2>/dev/null || echo '{}')
  HB=$("$NEW_BIND" q wasm contract-state smart "$TESTER_B" '{"history":{}}' --home "$HOME2" --node "tcp://127.0.0.1:${RPC2}" -o json 2>/dev/null || echo '{}')
  na=$(echo "$HA" | jq -r '(.data.history // .history // []) | length')
  nb=$(echo "$HB" | jq -r '(.data.history // .history // []) | length')
  echo "  polytone history a=$na b=$nb try=$i"
  if [ "${na:-0}" -ge 1 ] && [ "${nb:-0}" -ge 1 ]; then
    ok=1
    break
  fi
  sleep 3
done
if [ "$ok" != 1 ]; then
  echo "C: polytone callbacks never landed"
  tail -50 /tmp/tsh-c-hermes.log
  exit 1
fi
echo "C: polytone callbacks landed — upgrade + IBC path good"
kill "$HERMES_PID" 2>/dev/null || true

