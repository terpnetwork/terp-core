#!/bin/bash
set -x
set -oe errexit

ENABLE_FAUCET=${1:-"true"}
CUSTOM_SCRIPT_PATH=${POST_INIT_SCRIPT:-"/root/post_init.sh"}

file=~/.terpd/config/genesis.json
if [ ! -e "$file" ]; then
  # init the node
  rm -rf ~/.terpd/*

  chain_id=${CHAINID:-120u-1}
  LOG_LEVEL=${LOG_LEVEL:-INFO}
  fast_blocks=${FAST_BLOCKS:-"false"}

  terpd config chain-id "$chain_id"
  terpd config keyring-backend test

  terpd init banana --chain-id "$chain_id"

  jq '
    .app_state.staking.params.unbonding_time = "90s" |
    .app_state.gov.params.voting_period = "90s" |
    .app_state.gov.params.expedited_voting_period = "15s" |
    .app_state.gov.deposit_params.min_deposit[0].denom = "uterp" |
    .app_state.gov.params.min_deposit[0].denom = "uterp" |
    .app_state.gov.params.expedited_min_deposit[0].denom = "uterp" |
    .app_state.mint.params.mint_denom = "uterp" |
    .app_state.staking.params.bond_denom = "uterp" |
    .consensus.params.block.max_bytes = "16777216" |
    .consensus.params.block.max_gas = "-1"
  ' ~/.terpd/config/genesis.json >~/.terpd/config/genesis.json.tmp && mv ~/.terpd/config/genesis.json{.tmp,}

  if [ "${fast_blocks}" = "true" ]; then
    sed -E -i '/timeout_(propose|prevote|precommit|commit)/s/[0-9]+m?s/200ms/' ~/.terpd/config/config.toml
  else
    # Default: ~2s block times for local development
    sed -E -i 's/timeout_propose = "[0-9]+m?s"/timeout_propose = "500ms"/' ~/.terpd/config/config.toml
    sed -E -i 's/timeout_prevote = "[0-9]+m?s"/timeout_prevote = "250ms"/' ~/.terpd/config/config.toml
    sed -E -i 's/timeout_precommit = "[0-9]+m?s"/timeout_precommit = "250ms"/' ~/.terpd/config/config.toml
    sed -E -i 's/timeout_commit = "[0-9]+m?s"/timeout_commit = "1s"/' ~/.terpd/config/config.toml
  fi

  if [ ! -e "$CUSTOM_SCRIPT_PATH" ]; then
    echo "Custom script not found. Continuing..."
  else
    echo "Running custom post init script..."
    bash "$CUSTOM_SCRIPT_PATH"
    echo "Done running custom script!"
  fi

  v_mnemonic="push certain add next grape invite tobacco bubble text romance again lava crater pill genius vital fresh guard great patch knee series era tonight"
  a_mnemonic="grant rice replace explain federal release fix clever romance raise often wild taxi quarter soccer fiber love must tape steak together observe swap guitar"
  b_mnemonic="jelly shadow frog dirt dragon use armed praise universe win jungle close inmate rain oil canvas beauty pioneer chef soccer icon dizzy thunder meadow"
  c_mnemonic="chair love bleak wonder skirt permit say assist aunt credit roast size obtain minute throw sand usual age smart exact enough room shadow charge"
  d_mnemonic="word twist toast cloth movie predict advance crumble escape whale sail such angry muffin balcony keen move employ cook valve hurt glimpse breeze brick"

  echo "$v_mnemonic" | terpd keys add validator --recover
  echo "$a_mnemonic" | terpd keys add a --recover
  echo "$b_mnemonic" | terpd keys add b --recover
  echo "$c_mnemonic" | terpd keys add c --recover
  echo "$d_mnemonic" | terpd keys add d --recover

  terpd keys list --output json | jq

  ico=1000000000000000000

  terpd genesis add-genesis-account validator ${ico}uterp,${ico}uthiol
  terpd genesis add-genesis-account a ${ico}uterp,${ico}uthiol
  terpd genesis add-genesis-account b ${ico}uterp,${ico}uthiol
  terpd genesis add-genesis-account c ${ico}uterp,${ico}uthiol
  terpd genesis add-genesis-account d ${ico}uterp,${ico}uthiol
  
  terpd genesis gentx validator ${ico::-1}uterp --chain-id "$chain_id"

  terpd genesis collect-gentxs
  terpd genesis validate-genesis

  # Setup LCD
  perl -i -pe 's/localhost/0.0.0.0/' ~/.terpd/config/app.toml
  perl -i -pe 's;address = "tcp://0.0.0.0:1317";address = "tcp://0.0.0.0:1316";' ~/.terpd/config/app.toml
  perl -i -pe 's/enable-unsafe-cors = false/enable-unsafe-cors = true/' ~/.terpd/config/app.toml
  perl -i -pe 's/concurrency = false/concurrency = true/' ~/.terpd/config/app.toml

  # Prevent max connections error
  perl -i -pe 's/max_subscription_clients.+/max_subscription_clients = 100/' ~/.terpd/config/config.toml
  perl -i -pe 's/max_subscriptions_per_client.+/max_subscriptions_per_client = 50/' ~/.terpd/config/config.toml
fi

setsid lcp --proxyUrl http://127.0.0.1:1316 --port 1317 --proxyPartial '' &

if [ "${ENABLE_FAUCET}" = "true" ]; then
  # Setup faucet
  setsid node faucet_server.js &
fi

if [ "${SLEEP}" = "true" ]; then
  sleep infinity
fi

# Allow large wasm uploads for local development (default 819200 = 800KB)
export MAX_WASM_SIZE=${MAX_WASM_SIZE:-"16777216"}

RUST_BACKTRACE=1 terpd start --rpc.laddr tcp://0.0.0.0:26657 --log_level "${LOG_LEVEL}"