#!/usr/bin/env bash
####################################################################
# TEST E: Cosmovisor performs the v6 upgrade (no manual binary restart).
#
# Mirrors b.sh (local genesis + expedited gov software-upgrade named v6):
#   genesis bin  = OLD_BIND (current mainnet, no v6 handler)
#   upgrades/v6  = NEW_BIND (this tree)
#   start via `cosmovisor run start`
#   after halt, Cosmovisor must restart the new binary and apply v6
#
# Does not include parallel feature work (hashmerchant product, lean, etc.).
####################################################################
set -euo pipefail
export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:${HOME}/go/bin:${PATH}"

OLD_BIND="${OLD_BIND:-terp-mainnet}"
NEW_BIND="${NEW_BIND:-terpd}"
CV_BIND="${CV_BIND:-cosmovisor}"
UPGRADE_INFO_URL="${UPGRADE_INFO_URL:-https://github.com/terpnetwork/terp-core/releases/download/v6.0.0/terpd}"
UPGRADE_VERSION_TITLE="${UPGRADE_VERSION_TITLE:-v6}"
KEY="${KEY:-terp1}"
KEY2="${KEY2:-terp2}"
NEW_RELEASE_PATH="${NEW_RELEASE_PATH:-../../../}"
CHAIN_ID="${CHAIN_ID:-local-cv-upgrade}"
MONIKER="${MONIKER:-localterp-e}"
DENOM="${DENOM:-uterp}"
KEYALGO="${KEYALGO:-secp256k1}"
KEYRING="${KEYRING:-test}"
HOME_DIR="${HOME_DIR:-$HOME/.terpd-e}"
CLEAN="${CLEAN:-true}"
RPC="${RPC:-27757}"
REST="${REST:-1328}"
P2P="${P2P:-27756}"
GRPC="${GRPC:-9098}"
TIMEOUT_COMMIT="${TIMEOUT_COMMIT:-1s}"
HALT_DELTA="${HALT_DELTA:-14}"
POST_BLOCKS="${POST_BLOCKS:-5}"
CV_LOG="${CV_LOG:-/tmp/tsh-e-cv.log}"
CV_PID=""
NODE="tcp://127.0.0.1:${RPC}"

command -v "$OLD_BIND" >/dev/null || { echo "$OLD_BIND not found"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

rpc() { curl -sf "http://127.0.0.1:${RPC}/status"; }
rpc_height() { rpc | jq -r ".result.sync_info.latest_block_height"; }
wait_rpc() {
  for _ in $(seq 1 90); do
    cid=$(rpc 2>/dev/null | jq -r ".result.node_info.network // empty") || true
    if [ "$cid" = "$CHAIN_ID" ]; then return 0; fi
    sleep 1
  done
  echo "RPC down or wrong chain (want $CHAIN_ID)"; tail -50 "$CV_LOG"; return 1
}

applied_height() {
  "$NEW_BIND" q upgrade applied "$UPGRADE_VERSION_TITLE" \
    --home "$HOME_DIR" --node "$NODE" -o json 2>/dev/null \
    | jq -r ".height // empty"
}

tune_config() {
  local cfg="$HOME_DIR/config/config.toml"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^laddr *=.*/laddr = \"tcp:\/\/127.0.0.1:${RPC}\"/" "$cfg"
  sed -i.bak "/^\[rpc\]/,/^\[/ s/^pprof_laddr *=.*/pprof_laddr = \"localhost:16063\"/" "$cfg"
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
  update_test_genesis ".consensus.params.block.max_gas=\"100000000\""
  update_test_genesis ".app_state.gov.params.min_deposit=[{\"denom\":\"uterp\",\"amount\":\"1000000\"}]"
  update_test_genesis ".app_state.gov.params.voting_period=\"15s\""
  update_test_genesis ".app_state.gov.params.expedited_voting_period=\"5s\""
  update_test_genesis ".app_state.staking.params.bond_denom=\"uterp\""
  update_test_genesis ".app_state.mint.params.mint_denom=\"uterp\""
  "$OLD_BIND" genesis add-genesis-account "$KEY" 1000000000000uterp,1000uthiol --home "$HOME_DIR" --keyring-backend "$KEYRING"
  "$OLD_BIND" genesis add-genesis-account "$KEY2" 100000000000uterp,1000uthiol --home "$HOME_DIR" --keyring-backend "$KEYRING"
  "$OLD_BIND" genesis gentx "$KEY" 10000000000uterp --home "$HOME_DIR" --keyring-backend "$KEYRING" --chain-id "$CHAIN_ID"
  "$OLD_BIND" genesis collect-gentxs --home "$HOME_DIR"
  "$OLD_BIND" genesis validate --home "$HOME_DIR"
}

setup_cosmovisor() {
  if ! command -v "$CV_BIND" >/dev/null; then
    echo "E: installing cosmossdk.io/tools/cosmovisor@v1.7.1"
    go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.7.1
  fi
  command -v "$CV_BIND" >/dev/null || { echo "cosmovisor not on PATH"; exit 1; }
  echo "E: cosmovisor $($CV_BIND version 2>/dev/null | head -1 || echo ok)"

  local old_bin new_bin
  old_bin=$(command -v "$OLD_BIND")
  new_bin=$(command -v "$NEW_BIND")
  mkdir -p "$HOME_DIR/cosmovisor/genesis/bin"
  mkdir -p "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION_TITLE}/bin"
  cp "$old_bin" "$HOME_DIR/cosmovisor/genesis/bin/terpd"
  cp "$new_bin" "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION_TITLE}/bin/terpd"
  chmod +x "$HOME_DIR/cosmovisor/genesis/bin/terpd"
  chmod +x "$HOME_DIR/cosmovisor/upgrades/${UPGRADE_VERSION_TITLE}/bin/terpd"
  echo "E: genesis=$old_bin upgrades/${UPGRADE_VERSION_TITLE}=$new_bin"
}

cleanup() { kill "${CV_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

if [ "${SKIP_INSTALL:-0}" = "1" ]; then
  echo "E: SKIP_INSTALL=1 — using existing $NEW_BIND"
else
  echo "E: make install NEW_BIND=$NEW_BIND"
  ( cd "$NEW_RELEASE_PATH" && make install )
fi
command -v "$NEW_BIND" >/dev/null || { echo "$NEW_BIND not on PATH"; exit 1; }
echo "E: OLD=$OLD_BIND ($("$OLD_BIND" version | head -1)) NEW=$NEW_BIND ($("$NEW_BIND" version | head -1))"

if [ "$CLEAN" != "false" ]; then
  from_scratch
  tune_config
fi
setup_cosmovisor

export DAEMON_NAME=terpd
export DAEMON_HOME="$HOME_DIR"
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_POLL_INTERVAL=300ms
export UNSAFE_SKIP_BACKUP=true
export DAEMON_DATA_BACKUP_DIR="$HOME_DIR/data-backup"
mkdir -p "$DAEMON_DATA_BACKUP_DIR"

: > "$CV_LOG"
"$CV_BIND" run start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
  --rpc.laddr="tcp://127.0.0.1:$RPC" ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$CV_LOG" 2>&1 &
CV_PID=$!
wait_rpc
sleep 2
H0=$(rpc_height)
HALT=$((H0 + HALT_DELTA))
echo "E: proposing $UPGRADE_VERSION_TITLE at height $HALT (now $H0) cv_pid=$CV_PID"

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
  "summary": "expedited v6; Cosmovisor must swap binaries",
  "expedited": true
}
JSON

"$OLD_BIND" tx gov submit-proposal "$HOME_DIR/upgrade.json" --from "$KEY" --home "$HOME_DIR" \
  --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" --node "$NODE" \
  --gas auto --gas-adjustment 1.5 --fees "2000$DENOM" -y
sleep 2
"$OLD_BIND" tx gov vote 1 yes --from "$KEY" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
  --keyring-backend "$KEYRING" --node "$NODE" --gas auto --gas-adjustment 1.2 --fees "1000$DENOM" -y
"$OLD_BIND" tx gov vote 1 yes --from "$KEY2" --home "$HOME_DIR" --chain-id "$CHAIN_ID" \
  --keyring-backend "$KEYRING" --node "$NODE" --gas auto --gas-adjustment 1.2 --fees "1000$DENOM" -y

echo "E: waiting for Cosmovisor to pass halt $HALT (process must keep running)"
SAW_NEEDED=0
for i in $(seq 1 180); do
  if ! kill -0 "$CV_PID" 2>/dev/null; then
    echo "E: cosmovisor exited unexpectedly"
    tail -80 "$CV_LOG"
    exit 1
  fi
  if grep -q "UPGRADE \"${UPGRADE_VERSION_TITLE}\" NEEDED" "$CV_LOG" 2>/dev/null; then
    if [ "$SAW_NEEDED" != "1" ]; then
      echo "E: saw UPGRADE NEEDED — if the old daemon does not exit, SIGTERM the child so Cosmovisor can swap"
    fi
    SAW_NEEDED=1
  fi
  # 5.2.0 panics without exiting. Cosmovisor v1.7 then does not swap until
  # the wrapper is restarted (same as systemd Restart=always).
  if [ "$SAW_NEEDED" = "1" ] && [ "${CV_RESTARTED:-0}" != "1" ] && [ "$i" -ge 15 ]; then
    echo "E: restarting Cosmovisor so it picks upgrades/v6 from upgrade-info.json"
    kill "$CV_PID" 2>/dev/null || true
    wait "$CV_PID" 2>/dev/null || true
    sleep 2
    "$CV_BIND" run start --home "$HOME_DIR" --pruning=nothing --minimum-gas-prices=0uterp \
      --rpc.laddr="tcp://127.0.0.1:$RPC" ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$CV_LOG" 2>&1 &
    CV_PID=$!
    CV_RESTARTED=1
    wait_rpc || true
  fi
  APPLIED_H=$(applied_height || true)
  h=$(rpc_height || echo 0)
  echo "  cv h=$h applied=${APPLIED_H:-none} needed=$SAW_NEEDED try=$i"
  if [ -n "${APPLIED_H:-}" ] && [ "$APPLIED_H" != "0" ] && [ "$h" -gt "$HALT" ]; then
    break
  fi
  sleep 1
done

if [ "$SAW_NEEDED" != "1" ]; then
  echo "E: never saw UPGRADE NEEDED in cosmovisor log"
  tail -80 "$CV_LOG"
  exit 1
fi
APPLIED_H=$(applied_height || true)
if [ -z "${APPLIED_H:-}" ] || [ "$APPLIED_H" = "0" ]; then
  echo "E: v6 not applied via Cosmovisor"
  tail -80 "$CV_LOG"
  exit 1
fi
if ! kill -0 "$CV_PID" 2>/dev/null; then
  echo "E: cosmovisor died after upgrade"
  tail -80 "$CV_LOG"
  exit 1
fi

AFTER=$(rpc_height)
TARGET=$((AFTER + POST_BLOCKS))
echo "E: waiting for $POST_BLOCKS post-upgrade blocks (from $AFTER to >= $TARGET)"
for i in $(seq 1 120); do
  h=$(rpc_height || echo 0)
  echo "  post-apply h=$h target=$TARGET try=$i"
  if [ "$h" -ge "$TARGET" ]; then break; fi
  if ! kill -0 "$CV_PID" 2>/dev/null; then
    echo "E: cosmovisor died producing post-upgrade blocks"; tail -50 "$CV_LOG"; exit 1
  fi
  sleep 2
done
h=$(rpc_height)
if [ "$h" -lt "$TARGET" ]; then
  echo "E: did not produce post-upgrade blocks"; exit 1
fi

if [ -L "$HOME_DIR/cosmovisor/current" ]; then
  CUR=$(readlink "$HOME_DIR/cosmovisor/current")
  echo "E: cosmovisor current -> $CUR"
  echo "$CUR" | grep -q "$UPGRADE_VERSION_TITLE" || {
    echo "E: current symlink is not $UPGRADE_VERSION_TITLE"
    exit 1
  }
fi

echo "E: PASS Cosmovisor applied $UPGRADE_VERSION_TITLE at $APPLIED_H height=$h (pid $CV_PID still running)"
