#!/bin/bash
####################################################################
# GOAL: ensure migrating the home path via the patch script works properly
####################################################################
# A. START
####################################################################
BIND=terpd
CHAINID=test-1
CHAINDIR=./data
VAL1HOME_OLD=$CHAINDIR/$CHAINID/val1/.terp
VAL1HOME_NEW=$CHAINDIR/$CHAINID/val1/.terpd
VAL1_API_PORT=1317
VAL1_GRPC_PORT=9090
VAL1_GRPC_WEB_PORT=9091
VAL1_PROXY_APP_PORT=26658
VAL1_RPC_PORT=26657
VAL1_PPROF_PORT=6060
VAL1_P2P_PORT=26656
defaultCoins="100000000000000uterp"  # 1M
delegate="1000000uterp" # 1terp
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
echo "»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»"
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
echo "»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»"
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
echo "Creating $BINARY instance for VAL1: home=$VAL1HOME_OLD | chain-id=$CHAINID | p2p=:$VAL1_P2P_PORT | rpc=:$VAL1_RPC_PORT | profiling=:$VAL1_PPROF_PORT | grpc=:$VAL1_GRPC_PORT"
trap 'pkill -f '"$BIND" EXIT
echo "»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»"
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
echo "»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»"
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
rm -rf $VAL1HOME_OLD  
git clone https://github.com/terpnetwork/terp-core
cd terp-core &&
git checkout main
make install 
cd ../ &&
rm -rf $VAL1HOME_OLD/test-keys
$BIND init $CHAINID --overwrite --home $VAL1HOME_OLD --chain-id $CHAINID
sleep 1
mkdir $VAL1HOME_OLD/test-keys
$BIND --home $VAL1HOME_OLD config keyring-backend test
sleep 1
jq ".app_state.crisis.constant_fee.denom = \"uterp\" |
      .app_state.staking.params.bond_denom = \"uterp\" |
      .consensus.params.block.max_bytes = \"4404020\" |
      .consensus.params.block.max_gas = \"7100000\" |
      .app_state.mint.params.blocks_per_year = \"10000000\" |
      .app_state.mint.params.mint_denom = \"uterp\" |
      .app_state.gov.voting_params.voting_period = \"30s\" |
      .app_state.gov.params.voting_period = \"15s\" |
      .app_state.gov.params.expedited_voting_period = \"10s\" | 
      .app_state.gov.params.min_deposit[0].denom = \"uterp\" |
      .app_state.fantoken.params.burn_fee.denom = \"uterp\" |
      .app_state.fantoken.params.issue_fee.denom = \"uterp\" |
      .app_state.slashing.params.signed_blocks_window = \"10\" |
      .app_state.slashing.params.min_signed_per_window = \"1.000000000000000000\" |
      .app_state.fantoken.params.mint_fee.denom = \"uterp\"" $VAL1HOME_OLD/config/genesis.json > $VAL1HOME_OLD/config/tmp.json
mv $VAL1HOME_OLD/config/tmp.json $VAL1HOME_OLD/config/genesis.json
yes | $BIND  --home $VAL1HOME_OLD keys add validator1 --output json > $VAL1HOME_OLD/test-keys/val.json 2>&1 
yes | $BIND  --home $VAL1HOME_OLD keys add user --output json > $VAL1HOME_OLD/test-keys/user.json 2>&1
yes | $BIND  --home $VAL1HOME_OLD keys add delegator1 --output json > $VAL1HOME_OLD/test-keys/del.json 2>&1
$BIND --home $VAL1HOME_OLD genesis add-genesis-account "$($BIND --home $VAL1HOME_OLD keys show user -a)" $defaultCoins
$BIND --home $VAL1HOME_OLD genesis add-genesis-account "$($BIND --home $VAL1HOME_OLD keys show validator1 -a)" $defaultCoins
$BIND --home $VAL1HOME_OLD genesis add-genesis-account "$($BIND --home $VAL1HOME_OLD keys show delegator1 -a)" $defaultCoins
$BIND --home $VAL1HOME_OLD genesis gentx validator1 $delegate --chain-id $CHAINID 
$BIND genesis collect-gentxs --home $VAL1HOME_OLD
sed -i.bak -e "s/^proxy_app *=.*/proxy_app = \"tcp:\/\/127.0.0.1:$VAL1_PROXY_APP_PORT\"/g" $VAL1HOME_OLD/config/config.toml &&
sed -i.bak "/^\[rpc\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" $VAL1HOME_OLD/config/config.toml &&
sed -i.bak "/^\[rpc\]/,/^\[/ s/address.*/address = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" $VAL1HOME_OLD/config/config.toml &&
sed -i.bak "/^\[p2p\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/0.0.0.0:$VAL1_P2P_PORT\"/" $VAL1HOME_OLD/config/config.toml &&
sed -i.bak -e "s/^grpc_laddr *=.*/grpc_laddr = \"\"/g" $VAL1HOME_OLD/config/config.toml &&
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"1s\"/" "$VAL1HOME_OLD/config/config.toml"
sed -i.bak "/^\[api\]/,/^\[/ s/minimum-gas-prices.*/minimum-gas-prices = \"0.0uterp\"/" $VAL1HOME_OLD/config/app.toml &&
sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/0.0.0.0:$VAL1_API_PORT\"/" $VAL1HOME_OLD/config/app.toml &&
sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_PORT\"/" $VAL1HOME_OLD/config/app.toml &&
sed -i.bak "/^\[grpc-web\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_WEB_PORT\"/" $VAL1HOME_OLD/config/app.toml &&
echo "Starting Genesis validator with default wasm size..."
MAX_WASM_SIZE=819200 $BIND start --home $VAL1HOME_OLD & 
VAL1_PID=$!
echo "VAL1_PID: $VAL1_PID"
sleep 7
MIGRATE_PATH_SCRIPT="../../../../scripts/patches/update-home-dir.sh"
pkill -f $BIND
sh $MIGRATE_PATH_SCRIPT "$VAL1HOME_OLD" "$VAL1HOME_NEW"
$BIND start --home $VAL1HOME_NEW & 
VAL1_PID=$!
echo "VAL1_PID: $VAL1_PID"
sleep 7
$BIND status --home $VAL1HOME_NEW
sh $MIGRATE_PATH_SCRIPT