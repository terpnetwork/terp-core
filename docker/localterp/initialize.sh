#!/bin/bash
set -x
set -oe errexit

LOG_LEVEL=${LOG_LEVEL:-"debug"}
KEYRING=${KEYRING:-"test"}
MONIKER=${MONIKER:-"banana"}
CUSTOM_SCRIPT_PATH=${POST_INIT_SCRIPT:-"/root/post_init.sh"}
 

if [ -v ${TERP_RPC_IP} ]; then
  echo "Set TERP_RPC_IP to point to the network interface to bind the rpc service to"
  exit 1
fi
RPC_URL="${TERP_RPC_IP}:26657"
FAUCET_URL="${TERP_RPC_IP}:5000"

TERP_HOME=${TERPD_HOME:-$HOME/.terpd}

GENESIS_file=${TERP_HOME}/config/genesis.json
if [ ! -e "$GENESIS_file" ]; then
  # No genesis file found. Fresh start. Clean up
  rm -rf "$TERP_HOME"

  chain_id=${CHAINID:-"120u-1"}
  fast_blocks=${FAST_BLOCKS:-"false"}

  terpd config chain-id "${chain_id}"
  terpd config keyring-backend "${KEYRING}"

  terpd init ${MONIKER} --chain-id ${chain_id}

  cp ~/node_key.json "${TERP_HOME}"/config/node_key.json

  jq '
    .app_state.staking.params.unbonding_time = "90s" |
    .app_state.gov.params.voting_period = "90s" |
    .app_state.gov.params.expedited_voting_period = "15s" |
    .app_state.gov.deposit_params.min_deposit[0].denom = "uterp" |
    .app_state.gov.params.min_deposit[0].denom = "uterp" |
    .app_state.gov.params.expedited_min_deposit[0].denom = "uterp" |
    .app_state.mint.params.mint_denom = "uterp" |
    .app_state.staking.params.bond_denom = "uterp"
  ' "${TERP_HOME}"/config/genesis.json > "${TERP_HOME}"/config/genesis.json.tmp
  mv "${TERP_HOME}"/config/genesis.json{.tmp,}

  if [ "${fast_blocks}" = "true" ]; then
    sed -E -i '/timeout_(propose|prevote|precommit|commit)/s/[0-9]+m?s/200ms/' ~/.terpd/config/config.toml
  fi

  if [ -e "$CUSTOM_SCRIPT_PATH" ]; then
    echo "Running custom post init script..."
    bash "$CUSTOM_SCRIPT_PATH"
    echo "Done running custom script!"
  fi

  # Setup LCD
  perl -i -pe 's;address = "tcp://0.0.0.0:1317";address = "tcp://0.0.0.0:1316";' ~/.terpd/config/app.toml
  perl -i -pe 's/enable-unsafe-cors = false/enable-unsafe-cors = true/' ~/.terpd/config/app.toml
  perl -i -pe 's/concurrency = false/concurrency = true/' ~/.terpd/config/app.toml

  # Prevent max connections error
  perl -i -pe 's/max_subscription_clients.+/max_subscription_clients = 100/' ~/.terpd/config/config.toml
  perl -i -pe 's/max_subscriptions_per_client.+/max_subscriptions_per_client = 50/' ~/.terpd/config/config.toml
fi

# CORS bypass proxy [if missing, install via npm: npm install -g local-cors-proxy]
setsid lcp --proxyUrl http://localhost:1316 --port 1317 --proxyPartial '' &

. ./node_start.sh