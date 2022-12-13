#!/bin/sh

# create users
rm -rf $HOME/.terp
terpd config chain-id johnson-1
terpd config keyring-backend test
terpd config output json
yes | terpd keys add validator
yes | terpd keys add creator
yes | terpd keys add investor
yes | terpd keys add funder --pubkey "{\"@type\":\"/cosmos.crypto.secp256k1.PubKey\",\"key\":\"AtObiFVE4s+9+RX5SP8TN9r2mxpoaT4eGj9CJfK7VRzN\"}"
VALIDATOR=$(terpd keys show validator -a)
TENDER=$(terpd keys show creator -a)
FARMER=$(terpd keys show investor -a)
BREEDER=$(terpd keys show funder -a)

# setup chain
terpd init stargaze --chain-id johnson-1
# modify config for development
config="$HOME/.terp/config/config.toml"
if [ "$(uname)" = "Linux" ]; then
  sed -i "s/cors_allowed_origins = \[\]/cors_allowed_origins = [\"*\"]/g" $config
else
  sed -i '' "s/cors_allowed_origins = \[\]/cors_allowed_origins = [\"*\"]/g" $config
fi


terpd add-genesis-account $VALIDATOR 10000000000000000stake
terpd add-genesis-account $CREATOR 10000000000000000stake
terpd add-genesis-account $INVESTOR 10000000000000000stake
terpd add-genesis-account $FUNDER 10000000000000000stake
terpd gentx validator 10000000000stake --chain-id johnson-1 --keyring-backend test
terpd collect-gentxs
terpd validate-genesis
terpd start