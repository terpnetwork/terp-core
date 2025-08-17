#!/bin/sh

ENABLE_FAUCET=${1:-"true"}
KEYRING=${KEYRING:-"test"}
custom_script_path=${POST_INIT_SCRIPT:-"/root/post_init.sh"}
LOG_LEVEL=trace

init_bootstrap() {

      if [ "${ENABLE_FAUCET}" = "true" ]; then
            _pid_=$(ps -ef | grep "node.*faucet.*" | grep -v grep | awk '{print $2}')
            if [ ! -z "${_pid_}" ]; then
                  echo "Faucet app is running with PID:${_pid_}. Stopping..."
                  kill -HUP "${_pid_}" && echo "Successfully stopped PID:" {"$_pid_"}
            fi
      fi

      v_mnemonic="push certain add next grape invite tobacco bubble text romance again lava crater pill genius vital fresh guard great patch knee series era tonight"
      a_mnemonic="grant rice replace explain federal release fix clever romance raise often wild taxi quarter soccer fiber love must tape steak together observe swap guitar"
      b_mnemonic="jelly shadow frog dirt dragon use armed praise universe win jungle close inmate rain oil canvas beauty pioneer chef soccer icon dizzy thunder meadow"
      c_mnemonic="chair love bleak wonder skirt permit say assist aunt credit roast size obtain minute throw sand usual age smart exact enough room shadow charge"
      d_mnemonic="word twist toast cloth movie predict advance crumble escape whale sail such angry muffin balcony keen move employ cook valve hurt glimpse breeze brick"
      x_mnemonic="black foot thrive monkey tenant fashion blouse general adult orient grass enact eight tiger color castle rebuild puzzle much gap connect slice print gossip"
      z_mnemonic="obscure arrest leader echo truth puzzle police evolve robust remain vibrant name firm bulk filter mandate library mention walk can increase absurd aisle token"

      echo "$v_mnemonic" | terpd keys add validator --recover
      echo "$a_mnemonic" | terpd keys add a --recover
      echo "$b_mnemonic" | terpd keys add b --recover
      echo "$c_mnemonic" | terpd keys add c --recover
      echo "$d_mnemonic" | terpd keys add d --recover
      echo "$z_mnemonic" | terpd keys add z --recover

      terpd keys list --output json | jq

      ico=1000000000000000000

      terpd genesis add-genesis-account validator ${ico}uscrt
      terpd genesis add-genesis-account a ${ico}uscrt
      terpd genesis add-genesis-account b ${ico}uscrt
      terpd genesis add-genesis-account c ${ico}uscrt
      terpd genesis add-genesis-account d ${ico}uscrt
      terpd genesis add-genesis-account z ${ico}uscrt

      terpd genesis gentx validator ${ico}uscrt --chain-id "$chain_id"

      terpd genesis collect-gentxs
      terpd genesis validate-genesis
      terpd genesis validate-genesis

      if [ "${ENABLE_FAUCET}" = "true" ]; then
            # Setup faucet
            setsid /usr/bin/node ./faucet/faucet_server.js &
      fi

      # terpd keys list | jq
      # echo $x_mnemonic | terpd keys add userx --recover
      # x_address=$(terpd keys show -a userx)
      # # Now that we have genesis with some genesis accounts - load up the new wallet userx
      # curl http://${FAUCET_URL}/faucet?address=${x_address}
}

init_node() {
      echo "Initializing chain: $chain_id with node moniker: $MONIKER"
      # This node is not ready yet, temporarily point it to a bootstrap node
      terpd config node tcp://"${RPC_URL}"

      echo "Give a bootstrap node time to start..."
      sleep 5s

      # Download genesis.json from the bootstrap node
      curl http://"${RPC_URL}"/genesis | jq '.result.genesis' >"${TERP_HOME}"/config/genesis.json

      if [ ! -e "${TERP_HOME}"/config/genesis.json ]; then
            echo "Genesis file failed to download"
            exit 1
      fi
      # verify genesis.json checksum
      cat "${TERP_HOME}"/config/genesis.json | sha256sum
      cat "${TERP_HOME}"/config/genesis.json | jq

      terpd init-enclave
      if [ $? -ne 0 ]; then
            echo "Error: failed to initialize enclave"
            exit 1
      fi


      a_mnemonic="grant rice replace explain federal release fix clever romance raise often wild taxi quarter soccer fiber love must tape steak together observe swap guitar"
      mnemonic_userx="black foot thrive monkey tenant fashion blouse general adult orient grass enact eight tiger color castle rebuild puzzle much gap connect slice print gossip"
      echo "$mnemonic_userx" | terpd keys add userx --recover
      echo "$a_mnemonic" | terpd keys add a --recover
      terpd keys list --output json | jq

      x_address=$(terpd keys show -a userx)
      if [ -z "$x_address" ]; then
            echo "Error: cannot find key userx"
            exit 1
      fi

      # Set additiona network parameters necessary before the node start
      mkdir -p "${TERP_HOME}"/.node

      # Set minimum gas price
      perl -i -pe 's/^minimum-gas-prices = .+?$/minimum-gas-prices = "0.0125uscrt"/' "${TERP_HOME}"/config/app.toml

      # Get this node's id
      terpd tendermint show-node-id

      # Get ready to run our own node:
      # Open RPC port to all interfaces
      perl -i -pe 's/laddr = .+?26657"/laddr = "tcp:\/\/0.0.0.0:26657"/' "${TERP_HOME}"/config/config.toml
      # Open P2P port to all interfaces
      perl -i -pe 's/laddr = .+?26656"/laddr = "tcp:\/\/0.0.0.0:26656"/' "${TERP_HOME}"/config/config.toml

      terpd config node tcp://0.0.0.0:26657

      RUST_BACKTRACE=1 terpd start --rpc.laddr tcp://0.0.0.0:26657 --log_level "${LOG_LEVEL}" &&

      sleep 10s

      # Now that we have genesis with some genesis accounts - load up the new wallet userx
      curl http://${FAUCET_URL}/faucet?address=${x_address}
      sleep 5s

      terpd q bank balances ${x_address} | jq

      echo "<<<<<=====================================>>>>>"
      echo "Setting this node up as a validator"
      staking_amount=1000000uscrt

      echo "Staking amount: $staking_amount"

      terpd tx staking create-validator \
            --amount=$staking_amount \
            --pubkey=$(terpd tendermint show-validator) \
            --from=userx \
            --moniker=$(hostname) \
            --commission-rate="0.10" \
            --commission-max-rate="0.20" \
            --commission-max-change-rate="0.01" \
            --min-self-delegation="1"

}

if [ -z ${BOOTSTRAP+x} ]; then
      init_node
#      RUST_BACKTRACE=1 terpd start --rpc.laddr tcp://0.0.0.0:36657 --log_level ${LOG_LEVEL}
else
      init_bootstrap
      RUST_BACKTRACE=1 terpd start --rpc.laddr tcp://0.0.0.0:26657 --log_level ${LOG_LEVEL}
fi