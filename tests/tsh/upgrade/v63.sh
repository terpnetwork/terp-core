#!/usr/bin/env bash
####################################################################
# TSH: Cosmovisor dual-halt v6.3 then v6.4 (hasher dest copy → keepers
# on dest). Default: morocco-1 pruned pack + in-place-testnet.
# ALLOW_LOCAL_GENESIS=1 falls back to three-ELF local genesis.
####################################################################
set -euo pipefail
export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:${HOME}/go/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
SCRATCH="${SCRATCH:-${TMPDIR:-/tmp}/tsh-v63}"
mkdir -p "$SCRATCH"

PLAN_A="${PLAN_A:-v6.3}"
PLAN_B="${PLAN_B:-v6.4}"
HALT_GAP="${HALT_GAP:-2}"
POST_BLOCKS="${POST_BLOCKS:-3}"
CHAIN_ID="${CHAIN_ID:-local-1}"
KEY="${KEY:-terp1}"
KEY2="${KEY2:-terp2}"
KEYRING="${KEYRING:-test}"
KEYALGO="${KEYALGO:-secp256k1}"
DENOM="${DENOM:-uterp}"
RPC="${RPC:-26657}"
P2P="${P2P:-26656}"
GRPC="${GRPC:-9090}"
REST="${REST:-1317}"
TIMEOUT_COMMIT="${TIMEOUT_COMMIT:-1s}"
HALT_DELTA="${HALT_DELTA:-12}"
CV_BIND="${CV_BIND:-cosmovisor}"
SKIP_BUILD="${SKIP_BUILD:-0}"
HOME_DIR="${HOME_DIR:-$SCRATCH/home1}"
NEW_LOG="${NEW_LOG:-$SCRATCH/cv.log}"
OLD_LOG="${OLD_LOG:-$SCRATCH/old.log}"
SNAPSHOT_LOG="${SNAPSHOT_LOG:-$SCRATCH/snapshot.log}"
LC_LOG="${LC_LOG:-$SCRATCH/tsh-lc.log}"
HASH_WASM="${HASH_WASM:-1}"
WASM_GUEST="${WASM_GUEST:-$REPO/artifacts/cw_template.wasm}"
USE_SNAPSHOT="${USE_SNAPSHOT:-1}"
ALLOW_LOCAL_GENESIS="${ALLOW_LOCAL_GENESIS:-0}"
SNAPSHOT_INDEX="${SNAPSHOT_INDEX:-https://minio.terp.network/snapshots/mainnet/morocco-1/pruned/snapshot.json}"
SNAPSHOT_URL="${SNAPSHOT_URL:-}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-}"
SNAPSHOT_CACHE="${SNAPSHOT_CACHE:-/tmp/terp-morocco-1-pruned.tar.lz4}"
GENESIS_URL="${GENESIS_URL:-https://raw.githubusercontent.com/terpnetwork/networks/main/mainnet/morocco-1/genesis.json}"
GENESIS_FILE="${GENESIS_FILE:-}"

V63PRE_BIN="${V63PRE_BIN:-$REPO/build/terpd-v63pre}"
V63_BIN="${V63_BIN:-$REPO/build/terpd-v63}"
V64_BIN="${V64_BIN:-$REPO/build/terpd-v64}"

rpc() { curl -sf "http://127.0.0.1:${RPC}/status"; }
rpc_height() { rpc | jq -r '.result.sync_info.latest_block_height'; }
wait_rpc() {
  for _ in $(seq 1 180); do rpc >/dev/null 2>&1 && return 0; sleep 1; done
  echo "RPC down"; return 1
}

build_bins() {
  if [ "$SKIP_BUILD" = "1" ] && [ -x "$V63PRE_BIN" ] && [ -x "$V63_BIN" ] && [ -x "$V64_BIN" ]; then
    echo "v63: SKIP_BUILD using $V63PRE_BIN $V63_BIN $V64_BIN"
    return 0
  fi
  echo "v63: building v63pre / v6.3 / v6.4 ELFs"
  mkdir -p "$REPO/build"
  ( cd "$REPO" && BUILD_TAGS=v63pre make build )
  cp "$REPO/build/terpd" "$V63PRE_BIN"
  ( cd "$REPO" && make build )
  cp "$REPO/build/terpd" "$V63_BIN"
  ( cd "$REPO" && BUILD_TAGS=v64 make build )
  cp "$REPO/build/terpd" "$V64_BIN"
  chmod +x "$V63PRE_BIN" "$V63_BIN" "$V64_BIN"
}

MODE=genesis

from_scratch() {
  rm -rf "$HOME_DIR"
  echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry" | \
    "$V63PRE_BIN" keys add "$KEY" --home "$HOME_DIR" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover
  echo "wealth flavor believe regret funny network recall kiss grape useless pepper cram hint member few certain unveil rather brick bargain curious require crowd raise" | \
    "$V63PRE_BIN" keys add "$KEY2" --home "$HOME_DIR" --keyring-backend "$KEYRING" --algo "$KEYALGO" --recover
  "$V63PRE_BIN" init localterp --home "$HOME_DIR" --chain-id "$CHAIN_ID" --default-denom "$DENOM"
  jq '.consensus.params.block.max_gas="100000000" | .app_state.gov.params.min_deposit=[{"denom":"uterp","amount":"1000000"}] | .app_state.gov.params.voting_period="8s" | .app_state.gov.params.expedited_voting_period="4s" | .app_state.staking.params.bond_denom="uterp" | .app_state.mint.params.mint_denom="uterp" | .app_state.wasm.params.code_upload_access.permission="Everybody" | .app_state.wasm.params.instantiate_default_permission="Everybody"' \
    "$HOME_DIR/config/genesis.json" > "$HOME_DIR/config/tmp.json"
  mv "$HOME_DIR/config/tmp.json" "$HOME_DIR/config/genesis.json"
  "$V63PRE_BIN" genesis add-genesis-account "$KEY" 1000000000000uterp --home "$HOME_DIR" --keyring-backend "$KEYRING"
  "$V63PRE_BIN" genesis add-genesis-account "$KEY2" 100000000000uterp --home "$HOME_DIR" --keyring-backend "$KEYRING"
  "$V63PRE_BIN" genesis gentx "$KEY" 10000000000uterp --home "$HOME_DIR" --keyring-backend "$KEYRING" --chain-id "$CHAIN_ID"
  "$V63PRE_BIN" genesis collect-gentxs --home "$HOME_DIR"
  local cfg="$HOME_DIR/config/config.toml"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${RPC}\"/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${P2P}\"/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^pex *=.*/pex = false/" "$cfg"
  sed -i.bak "/^\[p2p\]/,/^\[/ s/^seeds *=.*/seeds = \"\"/" "$cfg"
  sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"${TIMEOUT_COMMIT}\"/" "$cfg"
  sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:${GRPC}\"/" "$HOME_DIR/config/app.toml" || true
  sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/127.0.0.1:${REST}\"/" "$HOME_DIR/config/app.toml" || true
}

place_cv() {
  mkdir -p "$HOME_DIR/cosmovisor/genesis/bin" \
    "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}/bin" \
    "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}/bin"
  cp "$V63PRE_BIN" "$HOME_DIR/cosmovisor/genesis/bin/terpd"
  cp "$V63_BIN" "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}/bin/terpd"
  cp "$V64_BIN" "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}/bin/terpd"
  chmod +x "$HOME_DIR/cosmovisor/genesis/bin/terpd" \
    "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}/bin/terpd" \
    "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}/bin/terpd"
}

applied() {
  local plan=$1 bind=$2
  "$bind" q upgrade applied "$plan" --home "$HOME_DIR" --node "tcp://127.0.0.1:${RPC}" -o json 2>/dev/null \
    | jq -r '.height // empty' || true
}

stop_cv() {
  local pid
  pid="${CV_PID:-}"
  if [ -z "${pid:-}" ] && [ -f "$HOME_DIR/cosmovisor.pid" ]; then
    pid="$(cat "$HOME_DIR/cosmovisor.pid" 2>/dev/null || true)"
  fi
  if [ -n "${pid:-}" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  if [ -n "${OLD_PID:-}" ]; then
    kill "$OLD_PID" 2>/dev/null || true
    kill -9 "$OLD_PID" 2>/dev/null || true
  fi
  rm -f "$HOME_DIR/cosmovisor.pid"
}

build_bins

if ! command -v "$CV_BIND" >/dev/null; then
  GOTOOLCHAIN=auto go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1
fi
command -v jq >/dev/null || { echo "jq required"; exit 1; }

if [ "$USE_SNAPSHOT" = "1" ]; then
  if [ -z "${SNAPSHOT_PATH:-}" ] && [ -f "$SNAPSHOT_CACHE" ]; then
    SNAPSHOT_PATH="$SNAPSHOT_CACHE"
  fi
  if [ -z "${GENESIS_FILE:-}" ] && [ -f /tmp/tsh-v63-snap/genesis.json ]; then
    GENESIS_FILE=/tmp/tsh-v63-snap/genesis.json
  fi
  if BIND="$V63PRE_BIN" HOME_DIR="$HOME_DIR" \
    SNAPSHOT_PATH="${SNAPSHOT_PATH:-}" SNAPSHOT_URL="${SNAPSHOT_URL:-}" \
    SNAPSHOT_INDEX="$SNAPSHOT_INDEX" SNAPSHOT_CACHE="$SNAPSHOT_CACHE" \
    GENESIS_URL="$GENESIS_URL" GENESIS_FILE="${GENESIS_FILE:-}" \
    RPC="$RPC" P2P="$P2P" GRPC="$GRPC" REST="$REST" \
    TIMEOUT_COMMIT="$TIMEOUT_COMMIT" \
    bash "$ROOT/hasher_snapshot.sh"; then
    MODE=snapshot
    HASH_WASM=0
    KEY=validator1
    CHAIN_ID=test-1
    echo "v63: MODE=snapshot (in-place-testnet $PLAN_A)"
  elif [ "$ALLOW_LOCAL_GENESIS" = "1" ]; then
    echo "v63: snapshot load failed; ALLOW_LOCAL_GENESIS=1"
    MODE=genesis
  else
    echo "v63: snapshot required (set ALLOW_LOCAL_GENESIS=1 for local genesis)"
    exit 1
  fi
fi

place_cv_and_trap() {
  place_cv
  trap stop_cv EXIT
}

if [ "$MODE" = "snapshot" ]; then
  place_cv_and_trap
  VAL1ADDR="$(cat "$HOME_DIR/test-keys/val.addr")"
  : > "$OLD_LOG"
  echo "v63: in-place-testnet --trigger-testnet-upgrade $PLAN_A val=$VAL1ADDR"
  "$V63PRE_BIN" in-place-testnet "$CHAIN_ID" "$VAL1ADDR" \
    --trigger-testnet-upgrade "$PLAN_A" \
    --home "$HOME_DIR" --skip-confirmation \
    --rpc.laddr "tcp://127.0.0.1:${RPC}" \
    --minimum-gas-prices=0uterp \
    ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$OLD_LOG" 2>&1 &
  OLD_PID=$!
  wait_rpc || true
  echo "v63: waiting for UPGRADE NEEDED ($PLAN_A, first testnet block)"
else
  from_scratch
  place_cv_and_trap
  : > "$OLD_LOG"
  "$V63PRE_BIN" start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
    --rpc.laddr="tcp://127.0.0.1:${RPC}" ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$OLD_LOG" 2>&1 &
  OLD_PID=$!
  wait_rpc
  sleep 2
  if [ "$HASH_WASM" = "1" ]; then
    PHASE=pre BIND="$V63PRE_BIN" HOME_DIR="$HOME_DIR" NODE="tcp://127.0.0.1:${RPC}" \
      CHAIN_ID="$CHAIN_ID" KEY="$KEY" KEYRING="$KEYRING" DENOM="$DENOM" \
      WASM="$WASM_GUEST" STATE="$HOME_DIR/hasher_wasm.state" \
      bash "$ROOT/hasher_wasm.sh"
  fi
  PHASE=pre BIND="$V63PRE_BIN" HOME_DIR="$HOME_DIR" NODE="tcp://127.0.0.1:${RPC}" \
    CHAIN_ID="$CHAIN_ID" KEY="$KEY" KEY2="$KEY2" KEYRING="$KEYRING" DENOM="$DENOM" \
    STATE="$HOME_DIR/hasher_state.json" RPC="$RPC" \
    bash "$ROOT/hasher_state.sh"
  H0=$(rpc_height)
  HALT=$((H0 + HALT_DELTA))
  echo "v63: proposing $PLAN_A at $HALT (now $H0)"
  jq -n --arg h "$HALT" --arg a "$PLAN_A" --arg info "https://s3.terp.network/upgrades/v6.3/cosmovisor.json" \
    '{
      messages: [{
        "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
        authority: "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
        plan: { name: $a, time: "0001-01-01T00:00:00Z", height: $h, info: $info, upgraded_client_state: null }
      }],
      metadata: "",
      deposit: "5000000000uterp",
      title: $a,
      summary: "v6.3 dest copy; handler arms v6.4 at +2",
      expedited: true
    }' > "$HOME_DIR/upgrade.json"
  mkdir -p "$REPO/networks/upgrades/v6.3"
  cp "$HOME_DIR/upgrade.json" "$REPO/networks/upgrades/v6.3/draft_proposal.json"
  "$V63PRE_BIN" tx gov submit-proposal "$HOME_DIR/upgrade.json" --from "$KEY" --home "$HOME_DIR" \
    --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC}" \
    --gas auto --gas-adjustment 1.5 --fees "2000uterp" -y
  sleep 2
  "$V63PRE_BIN" tx gov vote 1 yes --from "$KEY" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
    --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC}" --gas auto --gas-adjustment 1.2 --fees "1000uterp" -y
  "$V63PRE_BIN" tx gov vote 1 yes --from "$KEY2" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
    --keyring-backend "$KEYRING" --node "tcp://127.0.0.1:${RPC}" --gas auto --gas-adjustment 1.2 --fees "1000uterp" -y
  echo "v63: waiting for UPGRADE NEEDED at $HALT"
fi
for i in $(seq 1 180); do
  if [ "$MODE" = "snapshot" ] && [ ! -f "$HOME_DIR/hasher_state.json" ]; then
    SNAPSHOT=1 MIN_CODES="${MIN_CODES:-5}" SKIP_SEND=1 \
      PHASE=pre BIND="$V63PRE_BIN" HOME_DIR="$HOME_DIR" NODE="tcp://127.0.0.1:${RPC}" \
      CHAIN_ID="$CHAIN_ID" KEY="$KEY" KEY2="$KEY2" KEYRING="$KEYRING" DENOM="$DENOM" \
      STATE="$HOME_DIR/hasher_state.json" RPC="$RPC" \
      bash "$ROOT/hasher_state.sh" 2>/dev/null || true
  fi
  if ! kill -0 "$OLD_PID" 2>/dev/null; then
    echo "v63: genesis ELF exited"
    break
  fi
  if grep -q "UPGRADE \"${PLAN_A}\" NEEDED" "$OLD_LOG" 2>/dev/null; then
    echo "v63: halt signal"
    if [ "$MODE" = "snapshot" ] && [ ! -f "$HOME_DIR/hasher_state.json" ]; then
      SNAPSHOT=1 MIN_CODES="${MIN_CODES:-5}" SKIP_SEND=1 \
        PHASE=pre BIND="$V63PRE_BIN" HOME_DIR="$HOME_DIR" NODE="tcp://127.0.0.1:${RPC}" \
        CHAIN_ID="$CHAIN_ID" KEY="$KEY" KEY2="$KEY2" KEYRING="$KEYRING" DENOM="$DENOM" \
        STATE="$HOME_DIR/hasher_state.json" RPC="$RPC" \
        bash "$ROOT/hasher_state.sh" || true
    fi
    kill "$OLD_PID" 2>/dev/null || true
    wait "$OLD_PID" 2>/dev/null || true
    break
  fi
  echo "  pre-upgrade h=$(rpc_height || echo ?) try=$i"
  sleep 1
done
wait "$OLD_PID" 2>/dev/null || true
OLD_PID=""
sleep 1
[ -f "$HOME_DIR/data/upgrade-info.json" ] || { echo "missing upgrade-info.json"; tail -80 "$OLD_LOG"; exit 1; }
if [ "$MODE" = "snapshot" ]; then
  [ -s "$HOME_DIR/hasher_state.json" ] || { echo "v63: snapshot pre-state dump missing"; tail -80 "$OLD_LOG"; exit 1; }
  echo "v63: snapshot pre-state $(jq -c '{vals: ([.validators.validators[]?]|length), codes: ([.wasm_codes.code_infos[]?]|length)}' "$HOME_DIR/hasher_state.json")"
fi

export DAEMON_NAME=terpd
export DAEMON_HOME="$HOME_DIR"
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_POLL_INTERVAL=300ms
export UNSAFE_SKIP_BACKUP=true
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
ln -sfn "$HOME_DIR/cosmovisor/upgrades/${PLAN_A}" "$HOME_DIR/cosmovisor/current"

: > "$NEW_LOG"
nohup "$CV_BIND" run start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://0.0.0.0:${RPC}" --log_level info \
  ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$NEW_LOG" 2>&1 &
echo $! > "$HOME_DIR/cosmovisor.pid"
CV_PID=$(cat "$HOME_DIR/cosmovisor.pid")
wait_rpc
echo "v63: CV up height=$(rpc_height) current=$(readlink "$HOME_DIR/cosmovisor/current")"

proved_a=0
ok=0
for i in $(seq 1 180); do
  if grep -q "UPGRADE \"${PLAN_B}\" NEEDED" "$NEW_LOG" 2>/dev/null; then
    echo "v63: saw $PLAN_B NEEDED"
    if [ "$proved_a" = "0" ]; then
      BIND="$V63_BIN" NODE="tcp://127.0.0.1:${RPC}" HOME_DIR="$HOME_DIR" BANK_STORE=b3-bank \
        bash "$ROOT/hasher_proof.sh" || true
      proved_a=1
    fi
    kill "$CV_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$CV_PID" 2>/dev/null || true
    ln -sfn "$HOME_DIR/cosmovisor/upgrades/${PLAN_B}" "$HOME_DIR/cosmovisor/current"
    nohup "$CV_BIND" run start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
      --rpc.laddr="tcp://0.0.0.0:${RPC}" --log_level info \
      ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$NEW_LOG" 2>&1 &
    echo $! > "$HOME_DIR/cosmovisor.pid"
    CV_PID=$(cat "$HOME_DIR/cosmovisor.pid")
    break
  fi
  ah=$(applied "$PLAN_A" "$V63_BIN")
  bh=$(applied "$PLAN_B" "$V64_BIN")
  echo "  wait A/B a=${ah:-none} b=${bh:-none} h=$(rpc_height || echo ?) try=$i"
  if [ -n "${ah:-}" ] && [ "$ah" != "0" ] && [ "$proved_a" = "0" ]; then
    if BIND="$V63_BIN" NODE="tcp://127.0.0.1:${RPC}" HOME_DIR="$HOME_DIR" BANK_STORE=b3-bank \
      bash "$ROOT/hasher_proof.sh"; then
      proved_a=1
      echo "v63: hasher_proof after A OK"
    fi
  fi
  if [ -n "${bh:-}" ] && [ "$bh" != "0" ]; then
    ok=1
    break
  fi
  sleep 2
done

wait_rpc
ok=0
for i in $(seq 1 60); do
  ah=$(applied "$PLAN_A" "$V63_BIN")
  bh=$(applied "$PLAN_B" "$V64_BIN")
  echo "  post h=$(rpc_height || echo 0) applied A=${ah:-none} B=${bh:-none} try=$i"
  if [ -n "${ah:-}" ] && [ "$ah" != "0" ] && [ -n "${bh:-}" ] && [ "$bh" != "0" ]; then
    ok=1
    break
  fi
  sleep 2
done
[ "$ok" = "1" ] || { echo "v63: dual upgrade did not apply"; tail -80 "$NEW_LOG"; exit 1; }

ah=$(applied "$PLAN_A" "$V63_BIN")
bh=$(applied "$PLAN_B" "$V64_BIN")
gap=$((bh - ah))
if [ "$gap" -ne "$HALT_GAP" ]; then
  echo "v63: expected $PLAN_B = $PLAN_A + $HALT_GAP (got $bh - $ah = $gap)"
  exit 1
fi
echo "v63: applied $PLAN_A at $ah $PLAN_B at $bh (gap=$gap)"

if ! grep -q "v6.3: curated store\|v6.3: armed plan v6.4" "$NEW_LOG"; then
  echo "v63: missing v6.3 copy/arm logs"
  tail -80 "$NEW_LOG"
  exit 1
fi
if grep -q "refusing to rehash IBC-facing store" "$NEW_LOG"; then
  echo "v63: IBC rehash refused"
  exit 1
fi
if ! grep -q "v6.4: keepers on dest trees" "$NEW_LOG"; then
  echo "v63: missing v6.4 dest-keepers log"
  tail -80 "$NEW_LOG"
  exit 1
fi

AFTER=$(rpc_height)
TARGET=$((AFTER + POST_BLOCKS))
for i in $(seq 1 60); do
  h=$(rpc_height || echo 0)
  echo "  post-B produce h=$h target=$TARGET try=$i"
  [ "$h" -ge "$TARGET" ] && break
  sleep 2
done
h=$(rpc_height)
[ "$h" -ge "$TARGET" ] || { echo "v63: did not produce post-B blocks"; exit 1; }

req="b3-bank,b3-staking,b3-acc,b3-wasm,ibc"
if [ "$MODE" = "snapshot" ]; then
  req="b3-bank,b3-staking,b3-acc,b3-wasm,b3-gov,b3-mint,b3-distribution,b3-slashing,ibc,transfer"
fi
HASHER_ALL=1 HASHER_REQUIRE="$req" \
  BIND="$V64_BIN" NODE="tcp://127.0.0.1:${RPC}" HOME_DIR="$HOME_DIR" BANK_STORE=b3-bank \
  bash "$ROOT/hasher_proof.sh"
echo "v63: hasher_proof after B OK"

if [ "$HASH_WASM" = "1" ]; then
  PHASE=post BIND="$V64_BIN" HOME_DIR="$HOME_DIR" NODE="tcp://127.0.0.1:${RPC}" \
    CHAIN_ID="$CHAIN_ID" KEY="$KEY" KEYRING="$KEYRING" DENOM="$DENOM" \
    STATE="$HOME_DIR/hasher_wasm.state" \
    bash "$ROOT/hasher_wasm.sh"
  echo "v63: hasher_wasm after B OK"
fi

post_snap=0
post_codes=0
post_skip=0
if [ "$MODE" = "snapshot" ]; then
  post_snap=1
  post_codes=5
  post_skip=1
fi
SNAPSHOT="$post_snap" SKIP_SEND="$post_skip" MIN_CODES="$post_codes" \
  PHASE=post BIND="$V64_BIN" HOME_DIR="$HOME_DIR" NODE="tcp://127.0.0.1:${RPC}" \
  CHAIN_ID="$CHAIN_ID" KEY="$KEY" KEY2="$KEY2" KEYRING="$KEYRING" DENOM="$DENOM" \
  STATE="$HOME_DIR/hasher_state.json" RPC="$RPC" \
  bash "$ROOT/hasher_state.sh"
echo "v63: hasher_state after B OK"

rm -rf "$SCRATCH/home2"
HOME1="$HOME_DIR" HOME2="$SCRATCH/home2" ID1="$CHAIN_ID" ID2="local-2" \
  RPC1="$RPC" RPC2=27657 BIND="$V63PRE_BIN" VERIFY_BIND="$V63_BIN" \
  WASM_LC="$REPO/crates/terp-rs/artifacts/cw_ics08_wasm_terp.wasm" \
  LC_LOG="$LC_LOG" \
  bash "$ROOT/hasher_lc.sh"

echo "v63 OK dual Cosmovisor $PLAN_A@$ah → $PLAN_B@$bh"
