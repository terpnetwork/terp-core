#!/bin/bash
set -x
set -oe errexit

ENABLE_FAUCET=${1:-"true"}

custom_script_path=${POST_INIT_SCRIPT:-"/root/post_init.sh"}

file=~/.terp/config/genesis.json
if [ ! -e "$file" ]; then
  # init the node
  rm -rf ~/.terp/*

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
    .app_state.staking.params.bond_denom = "uterp"
  ' ~/.terp/config/genesis.json >~/.terp/config/genesis.json.tmp && mv ~/.terp/config/genesis.json{.tmp,}

  if [ "${fast_blocks}" = "true" ]; then
    sed -E -i '/timeout_(propose|prevote|precommit|commit)/s/[0-9]+m?s/200ms/' ~/.terp/config/config.toml
  fi

  if [ ! -e "$custom_script_path" ]; then
    echo "Custom script not found. Continuing..."
  else
    echo "Running custom post init script..."
    bash "$custom_script_path"
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

  terpd genesis add-genesis-account validator ${ico}uterp
  terpd genesis add-genesis-account a ${ico}uterp
  terpd genesis add-genesis-account b ${ico}uterp
  terpd genesis add-genesis-account c ${ico}uterp
  terpd genesis add-genesis-account d ${ico}uterp
  
  terpd genesis gentx validator ${ico::-1}uterp --chain-id "$chain_id"

  terpd genesis collect-gentxs
  terpd genesis validate-genesis

  # Setup LCD
  perl -i -pe 's/localhost/0.0.0.0/' ~/.terp/config/app.toml
  perl -i -pe 's;address = "tcp://0.0.0.0:1317";address = "tcp://0.0.0.0:1316";' ~/.terp/config/app.toml
  perl -i -pe 's/enable-unsafe-cors = false/enable-unsafe-cors = true/' ~/.terp/config/app.toml
  perl -i -pe 's/concurrency = false/concurrency = true/' ~/.terp/config/app.toml

  # Prevent max connections error
  perl -i -pe 's/max_subscription_clients.+/max_subscription_clients = 100/' ~/.terp/config/config.toml
  perl -i -pe 's/max_subscriptions_per_client.+/max_subscriptions_per_client = 50/' ~/.terp/config/config.toml
fi

setsid lcp --proxyUrl http://localhost:1316 --port 1317 --proxyPartial '' &

if [ "${ENABLE_FAUCET}" = "true" ]; then
  # Setup faucet
  setsid node faucet_server.js &
  # Setup terpd
  cp "$(which terpd)" "$(dirname "$(which terpd)")"/terpd
fi

if [ "${SLEEP}" = "true" ]; then
  sleep infinity
fi

RUST_BACKTRACE=1 terpd start --rpc.laddr tcp://0.0.0.0:26657 --log_level "${LOG_LEVEL}"