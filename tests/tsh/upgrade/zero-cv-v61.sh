#!/usr/bin/env bash
####################################################################
# 120u-1: export --for-zero-height, 2-minute gov, Cosmovisor + pre-placed v6.1
#
# Genesis binary stays the current testnet bind. upgrades/v6.1/bin/terpd is
# the feat/6.1.0-dev binary. Cosmovisor swaps at halt (validator-shaped).
#
#   # stop is required so export reads a quiescent app DB
#   HOME_DIR=$HOME/.terpd-testnet RPC=36657 KEY=validator \
#     NEW_BIND=terpd-testnet-v61 OLD_BIND=terpd-testnet-v6 \
#     bash tests/tsh/upgrade/zero-cv-v61.sh
#
# SUBMIT=1 also files the v6.1 software-upgrade after blocks start.
####################################################################
set -euo pipefail
export PATH="/usr/local/go/bin:${HOME}/go/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PACK="$ROOT/networks/upgrades/v6.1"
HOME_DIR="${HOME_DIR:-$HOME/.terpd-testnet}"
CHAIN_ID="${CHAIN_ID:-120u-1}"
RPC="${RPC:-26657}"
NODE="tcp://127.0.0.1:${RPC}"
OLD_BIND="${OLD_BIND:-terpd-testnet-v6}"
NEW_BIND="${NEW_BIND:-terpd-testnet-v61}"
CV_BIND="${CV_BIND:-cosmovisor}"
KEY="${KEY:-validator}"
SUBMIT_FROM="${SUBMIT_FROM:-faucet}"
VOTE_FROM="${VOTE_FROM:-validator}"
KEYRING="${KEYRING:-test}"
DENOM="${DENOM:-uterp}"
UPGRADE_VERSION="${UPGRADE_VERSION:-v6.1}"
VOTING_PERIOD="${VOTING_PERIOD:-120s}"
EXPEDITED_VOTING_PERIOD="${EXPEDITED_VOTING_PERIOD:-60s}"
MIN_DEPOSIT="${MIN_DEPOSIT:-1000000}"
TIMEOUT_COMMIT="${TIMEOUT_COMMIT:-1s}"
HALT_DELTA="${HALT_DELTA:-90}"
POST_BLOCKS="${POST_BLOCKS:-3}"
SUBMIT="${SUBMIT:-0}"
SKIP_EXPORT="${SKIP_EXPORT:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-$ROOT}"
CV_LOG="${CV_LOG:-/tmp/tsh-zero-cv-v61.log}"
EXPORT_JSON="${EXPORT_JSON:-$HOME_DIR/exported-zero.json}"
BACKUP_DIR="${BACKUP_DIR:-$HOME_DIR/zero-export-backup}"

if [ "$HOME_DIR" = "$HOME/.terpd-mainnet" ] || [ "$CHAIN_ID" = "morocco-1" ]; then
  echo "refusing mainnet home/chain"
  exit 1
fi
command -v "$OLD_BIND" >/dev/null || { echo "$OLD_BIND not on PATH"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

rpc() { curl -sf --max-time 3 "http://127.0.0.1:${RPC}/status"; }
rpc_height() { rpc | jq -r ".result.sync_info.latest_block_height"; }

stop_testnet() {
  local pids
  pids=$(pgrep -f "$OLD_BIND start --home $HOME_DIR" || true)
  if [ -n "${pids:-}" ]; then
    echo "Z: stopping $OLD_BIND pids=$pids"
    kill $pids 2>/dev/null || true
    for _ in $(seq 1 30); do
      pgrep -f "$OLD_BIND start --home $HOME_DIR" >/dev/null || break
      sleep 1
    done
    pgrep -f "$OLD_BIND start --home $HOME_DIR" >/dev/null && kill -9 $pids 2>/dev/null || true
  fi
  pids=$(pgrep -f "cosmovisor run start --home $HOME_DIR" || true)
  if [ -n "${pids:-}" ]; then
    echo "Z: stopping cosmovisor pids=$pids"
    kill $pids 2>/dev/null || true
    sleep 2
  fi
}

patch_genesis() {
  local src=$1 dest=$2
  jq \
    --arg vp "$VOTING_PERIOD" \
    --arg evp "$EXPEDITED_VOTING_PERIOD" \
    --arg denom "$DENOM" \
    --arg amt "$MIN_DEPOSIT" \
    '
      .app_state.gov.params.voting_period = $vp
      | .app_state.gov.params.expedited_voting_period = $evp
      | .app_state.gov.params.min_deposit = [{"denom":$denom,"amount":$amt}]
      | .app_state.gov.params.expedited_min_deposit = [{"denom":$denom,"amount":$amt}]
    ' "$src" > "$dest"
}

PLAN="${PLAN:-v6.1}" TAG="${TAG:-${RELEASE_TAG:-v6.1.0-dev}}" ALLOW_PARTIAL="${ALLOW_PARTIAL:-1}" \
  SKIP_WASMVM_CURATE="${SKIP_WASMVM_CURATE:-0}" \
  bash "$ROOT/scripts/release/preflight_upgrade.sh"

RELEASE_ELF="${RELEASE_ELF:-$ROOT/build/terpd-linux-amd64}"
if [ -x "$RELEASE_ELF" ]; then
  echo "Z: using release ELF $RELEASE_ELF (skip host go build)"
  NEW_BIN="$RELEASE_ELF"
elif [ "$SKIP_INSTALL" != "1" ]; then
  echo "Z: go build $NEW_BIND from $NEW_RELEASE_PATH"
  ( cd "$NEW_RELEASE_PATH" && GOTOOLCHAIN=auto GOWORK=off CGO_ENABLED=1 go build -mod=mod -tags "netgo ledger" -o "$HOME/go/bin/$NEW_BIND" ./cmd/terpd )
  NEW_BIN="$(command -v "$NEW_BIND" 2>/dev/null || echo "$HOME/go/bin/$NEW_BIND")"
else
  command -v "$NEW_BIND" >/dev/null || [ -x "$HOME/go/bin/$NEW_BIND" ] || { echo "$NEW_BIND missing"; exit 1; }
  NEW_BIN="$(command -v "$NEW_BIND" 2>/dev/null || echo "$HOME/go/bin/$NEW_BIND")"
fi
[ -x "$NEW_BIN" ] || { echo "$NEW_BIN missing"; exit 1; }
OLD_BIN="$(command -v "$OLD_BIND")"
if ! command -v "$CV_BIND" >/dev/null; then
  echo "Z: installing cosmovisor v1.7.1"
  GOTOOLCHAIN=auto go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1
fi
command -v "$CV_BIND" >/dev/null || { echo "cosmovisor missing"; exit 1; }

if [ "$SKIP_EXPORT" != "1" ]; then
  if rpc >/dev/null 2>&1; then
    NET=$(rpc | jq -r ".result.node_info.network")
    [ "$NET" = "$CHAIN_ID" ] || { echo "RPC :$RPC is $NET not $CHAIN_ID"; exit 1; }
    echo "Z: live $CHAIN_ID height=$(rpc_height) — stopping for export"
  fi
  stop_testnet
  mkdir -p "$BACKUP_DIR"
  cp -a "$HOME_DIR/config/genesis.json" "$BACKUP_DIR/genesis.pre-export.json"
  cp -a "$HOME_DIR/data/priv_validator_state.json" "$BACKUP_DIR/priv_validator_state.json"
  echo "Z: export --for-zero-height → $EXPORT_JSON"
  "$OLD_BIN" export --home "$HOME_DIR" --for-zero-height --output-document "$EXPORT_JSON"
  echo "Z: patch voting_period=$VOTING_PERIOD expedited=$EXPEDITED_VOTING_PERIOD min_deposit=${MIN_DEPOSIT}${DENOM}"
  patch_genesis "$EXPORT_JSON" "$HOME_DIR/config/genesis.json"
  echo "Z: comet unsafe-reset-all"
  "$OLD_BIN" comet unsafe-reset-all --home "$HOME_DIR"
  cp -a "$BACKUP_DIR/priv_validator_state.json" "$HOME_DIR/data/priv_validator_state.json"
  # zero-height must start with height 0 / round 0
  printf '%s\n' '{"height":"0","round":0,"step":0}' > "$HOME_DIR/data/priv_validator_state.json"
  "$OLD_BIN" genesis validate --home "$HOME_DIR" || true
fi

# Keep ports from existing config; only tighten timeout_commit for soak.
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"${TIMEOUT_COMMIT}\"/" "$HOME_DIR/config/config.toml"

mkdir -p "$HOME_DIR/cosmovisor/genesis/bin" "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION}/bin"
cp "$OLD_BIN" "$HOME_DIR/cosmovisor/genesis/bin/terpd"
cp "$NEW_BIN" "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd"
chmod +x "$HOME_DIR/cosmovisor/genesis/bin/terpd" "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd"
echo "Z: CV genesis=$OLD_BIN upgrades/${UPGRADE_VERSION}=$NEW_BIN"

export DAEMON_NAME=terpd
export DAEMON_HOME="$HOME_DIR"
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_POLL_INTERVAL=300ms
export UNSAFE_SKIP_BACKUP=true
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_DATA_BACKUP_DIR="$HOME_DIR/data-backup"
mkdir -p "$DAEMON_DATA_BACKUP_DIR"

: > "$CV_LOG"
echo "Z: cosmovisor run start --home $HOME_DIR"
nohup "$CV_BIND" run start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://0.0.0.0:${RPC}" --log_level info \
  --wasm.skip_wasmvm_version_check >>"$CV_LOG" 2>&1 &
echo $! > "$HOME_DIR/cosmovisor.pid"
echo "Z: cv pid=$(cat "$HOME_DIR/cosmovisor.pid") log=$CV_LOG"

ok=0
for _ in $(seq 1 90); do
  cid=$(rpc 2>/dev/null | jq -r ".result.node_info.network // empty" || true)
  if [ "$cid" = "$CHAIN_ID" ]; then ok=1; break; fi
  sleep 2
done
if [ "$ok" != "1" ]; then
  echo "Z: RPC did not come up"; tail -80 "$CV_LOG"; exit 1
fi
H0=$(rpc_height)
echo "Z: restarted $CHAIN_ID height=$H0 voting=$VOTING_PERIOD"

if [ "$SUBMIT" != "1" ]; then
  echo "Z: Cosmovisor is up. SUBMIT=1 SUBMIT_FROM=$SUBMIT_FROM VOTE_FROM=$VOTE_FROM to file plan $UPGRADE_VERSION"
  exit 0
fi

HALT=$((H0 + HALT_DELTA))
echo "Z: proposing $UPGRADE_VERSION halt=$HALT from $SUBMIT_FROM"
jq --arg h "$HALT" --arg name "$UPGRADE_VERSION" --arg denom "$DENOM" --arg amt "$MIN_DEPOSIT" \
  '.messages[0].plan.height=$h | .messages[0].plan.name=$name | .deposit=($amt+$denom) | .expedited=true' \
  "$PACK/draft_proposal.json" > "$HOME_DIR/upgrade-v61.json"

"$OLD_BIN" tx gov submit-proposal "$HOME_DIR/upgrade-v61.json" --from "$SUBMIT_FROM" --home "$HOME_DIR" \
  --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" --node "$NODE" \
  --gas auto --gas-adjustment 1.6 --fees "2500$DENOM" -y
sleep 4
PID=$( "$OLD_BIN" q gov proposals --home "$HOME_DIR" --node "$NODE" -o json 2>/dev/null \
  | jq -r '.proposals[-1].id // .proposals[0].id // "1"' )
"$OLD_BIN" tx gov vote "$PID" yes --from "$VOTE_FROM" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
  --keyring-backend "$KEYRING" --node "$NODE" --gas auto --gas-adjustment 1.4 --fees "2000uthiol" -y
echo "Z: voted yes on $PID — waiting for halt $HALT"

for _ in $(seq 1 180); do
  if grep -q "UPGRADE \"${UPGRADE_VERSION}\" NEEDED" "$CV_LOG" 2>/dev/null; then
    echo "Z: saw UPGRADE NEEDED — genesis binary panics without exit; point current at upgrades/${UPGRADE_VERSION} and restart"
    CVPID=$(cat "$HOME_DIR/cosmovisor.pid" 2>/dev/null || true)
    if [ -n "${CVPID:-}" ]; then
      kill "$CVPID" 2>/dev/null || true
      sleep 2
      kill -9 "$CVPID" 2>/dev/null || true
    fi
    ln -sfn "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION}" "$HOME_DIR/cosmovisor/current"
    nohup "$CV_BIND" run start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
      --rpc.laddr="tcp://0.0.0.0:${RPC}" --log_level info \
      --wasm.skip_wasmvm_version_check >>"$CV_LOG" 2>&1 &
    echo $! > "$HOME_DIR/cosmovisor.pid"
    break
  fi
  sleep 2
done

ok=0
for _ in $(seq 1 60); do
  ah=$("$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION}/bin/terpd" q upgrade applied "$UPGRADE_VERSION" \
    --home "$HOME_DIR" --node "$NODE" -o json 2>/dev/null | jq -r '.height // empty' || true)
  h=$(rpc_height || echo 0)
  if [ -n "${ah:-}" ] && [ "$ah" != "0" ] && [ "${h:-0}" -gt "$HALT" ]; then
    echo "Z: applied $UPGRADE_VERSION at $ah height=$h current=$(readlink "$HOME_DIR/cosmovisor/current")"
    ok=1
    break
  fi
  sleep 2
done
[ "$ok" = "1" ] || { echo "Z: upgrade did not apply"; tail -80 "$CV_LOG"; exit 1; }
