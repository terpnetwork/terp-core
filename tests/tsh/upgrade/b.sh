#!/bin/bash
####################################################################
# A. START
####################################################################

# terpd sub-1 ./data 26657 26656 6060 9090 uterp
BIND=terpd
CHAINID=test-1
CHAINDIR=./data

VAL1HOME=$CHAINDIR/$CHAINID/val1
# Define the new ports for val1
VAL1_API_PORT=1317
VAL1_GRPC_PORT=9090
VAL1_GRPC_WEB_PORT=9091
VAL1_PROXY_APP_PORT=26658
VAL1_RPC_PORT=26657
VAL1_PPROF_PORT=6060
VAL1_P2P_PORT=26656

 
# upgrade details
UPGRADE_VERSION_TITLE="v5"
UPGRADE_VERSION_TAG="v5"

echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
echo "»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»"
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
echo "»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»"
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
echo "Creating $BINARY instance for VAL1: home=$VAL1HOME | chain-id=$CHAINID | p2p=:$VAL1_P2P_PORT | rpc=:$VAL1_RPC_PORT | profiling=:$VAL1_PPROF_PORT | grpc=:$VAL1_GRPC_PORT"
trap 'pkill -f '"$BIND" EXIT
echo "»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»"
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"
echo "»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»»"
echo "««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««««"

defaultCoins="100000000000000uterp"  # 1M
fundCommunityPool="1000000000uterp" # 1K
delegate="1000000uterp" # 1btsg

rm -rf $VAL1HOME  
# Clone the repository if it doesn't exist
git clone https://github.com/terpnetwork/terp-core
# # Change into the cloned directory
cd terp-core &&
# # Checkout the version of terp-core that doesnt submit slashing hooks
git checkout main
make install 
cd ../ &&

rm -rf $VAL1HOME/test-keys

$BIND init $CHAINID --overwrite --home $VAL1HOME --chain-id $CHAINID
sleep 1

mkdir $VAL1HOME/test-keys

$BIND --home $VAL1HOME config keyring-backend test
sleep 1
#       .app_state.gov.params.expedited_voting_period = \"10s\" | 
# modify val1 genesis 
jq ".app_state.crisis.constant_fee.denom = \"uterp\" |
      .app_state.staking.params.bond_denom = \"uterp\" |
      .app_state.mint.params.blocks_per_year = \"10000000\" |
      .app_state.mint.params.mint_denom = \"uterp\" |
      .app_state.gov.voting_params.voting_period = \"30s\" |
      .app_state.gov.params.voting_period = \"15s\" |

      .app_state.gov.params.min_deposit[0].denom = \"uterp\" |
      .app_state.fantoken.params.burn_fee.denom = \"uterp\" |
      .app_state.fantoken.params.issue_fee.denom = \"uterp\" |
      .app_state.slashing.params.signed_blocks_window = \"10\" |
      .app_state.slashing.params.min_signed_per_window = \"1.000000000000000000\" |
      .app_state.fantoken.params.mint_fee.denom = \"uterp\"" $VAL1HOME/config/genesis.json > $VAL1HOME/config/tmp.json
# give val2 a genesis
mv $VAL1HOME/config/tmp.json $VAL1HOME/config/genesis.json

# setup test keys.
yes | $BIND  --home $VAL1HOME keys add validator1 --output json > $VAL1HOME/test-keys/val.json 2>&1 
sleep 1
yes | $BIND  --home $VAL1HOME keys add user --output json > $VAL1HOME/test-keys/user.json 2>&1
sleep 1
yes | $BIND  --home $VAL1HOME keys add delegator1 --output json > $VAL1HOME/test-keys/del.json 2>&1
sleep 1
$BIND --home $VAL1HOME genesis add-genesis-account "$($BIND --home $VAL1HOME keys show user -a)" $defaultCoins
sleep 1
$BIND --home $VAL1HOME genesis add-genesis-account "$($BIND --home $VAL1HOME keys show validator1 -a)" $defaultCoins
sleep 1
$BIND --home $VAL1HOME genesis add-genesis-account "$($BIND --home $VAL1HOME keys show delegator1 -a)" $defaultCoins
sleep 1
$BIND --home $VAL1HOME genesis gentx validator1 $delegate --chain-id $CHAINID 
sleep 1
$BIND genesis collect-gentxs --home $VAL1HOME
sleep 1


# keys 
DEL1=$(jq -r '.name' $CHAINDIR/$CHAINID/val1/test-keys/del.json)
DEL1ADDR=$(jq -r '.address' $CHAINDIR/$CHAINID/val1/test-keys/del.json)
VAL1=$(jq -r '.name' $CHAINDIR/$CHAINID/val1/test-keys/val.json)
USERADDR=$(jq -r '.address'  $CHAINDIR/$CHAINID/val1/test-keys/user.json)


# app & config modiifications
# config.toml
sed -i.bak -e "s/^proxy_app *=.*/proxy_app = \"tcp:\/\/127.0.0.1:$VAL1_PROXY_APP_PORT\"/g" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[rpc\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[rpc\]/,/^\[/ s/address.*/address = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[p2p\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/0.0.0.0:$VAL1_P2P_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak -e "s/^grpc_laddr *=.*/grpc_laddr = \"\"/g" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"1s\"/" "$VAL1HOME/config/config.toml"

# app.toml
sed -i.bak "/^\[api\]/,/^\[/ s/minimum-gas-prices.*/minimum-gas-prices = \"0.0uterp\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/0.0.0.0:$VAL1_API_PORT\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_PORT\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[grpc-web\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_WEB_PORT\"/" $VAL1HOME/config/app.toml &&
 

# Start bitsong
echo "Starting Genesis validator..."
$BIND start --home $VAL1HOME & 
VAL1_PID=$!
echo "VAL1_PID: $VAL1_PID"
sleep 7

####################################################################
# C. UPGRADE
####################################################################
echo "lets upgrade "
sleep 6

LATEST_HEIGHT=$( $BIND status --home $VAL1HOME | jq -r '.sync_info.latest_block_height' )
UPGRADE_HEIGHT=$(( $LATEST_HEIGHT + 35 ))
echo "UPGRADE HEIGHT: $UPGRADE_HEIGHT"
sleep 6


cat <<EOF > "$VAL1HOME/upgrade.json" 
{
 "messages": [
  {
   "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
   "authority": "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
   "plan": {
    "name": "$UPGRADE_VERSION_TAG",
    "time": "0001-01-01T00:00:00Z",
    "height": "$UPGRADE_HEIGHT",
    "info": "https://github.com/permissionlessweb/terp-core/releases/download/v5.0.0/terpd",
    "upgraded_client_state": null
   }
  }
 ],
 "metadata": "ipfs://CID",
 "deposit": "5000000000uterp",
 "title": "$UPGRADE_VERSION_TITLE",
 "summary": "mememe",
 "expedited": true 
}
EOF

echo "propose upgrade using expedited proposal..."
$BIND tx gov submit-proposal $VAL1HOME/upgrade.json --gas auto --gas-adjustment 1.5 --fees="2000uterp" --chain-id=$CHAINID --home=$VAL1HOME --from="$VAL1" -y
sleep 6

# echo "vote upgrade"
$BIND tx gov vote 1 yes --from "$DEL1" --gas auto --gas-adjustment 1.2 --fees 1000uterp --chain-id $CHAINID --home $VAL1HOME -y
$BIND tx gov vote 1 yes --from "$VAL1" --gas auto --gas-adjustment 1.2 --fees 1000uterp --chain-id $CHAINID --home $VAL1HOME -y
sleep 10


VAL1_OP_ADDR=$(jq -r '.body.messages[0].validator_address' $VAL1HOME/config/gentx/gentx-*.json)
echo "VAL1_OP_ADDR: $VAL1_OP_ADDR"
echo "DEL1ADDR: $DEL1ADDR"

echo "querying rewards and balances pre upgrade"

####################################################################
# C. CONFIRM
####################################################################
echo "performing v023 upgrade"
sleep 25

# # install v0.23
pkill -f $BIND
cd terp-core && 
git checkout v050-upgrade
make install 
cd ..


# Start bitsong
echo "Running upgradehandler to fix community-pool issue..."
$BIND start --home $VAL1HOME & 
VAL1_PID=$!
echo "VAL1_PID: $VAL1_PID"
sleep 21



echo "UPGRADE APPLIED SUCCESSFULLY"
pkill -f terpd