#!/bin/bash
####################################################################
# A. START
####################################################################
export UPGRADE_VERSION_TITLE=${UPGRADE_VERSION_TITLE:-"v6"}
export KEY="terp1"
export KEY2="terp2"
export TFDENOM="skeret"
export NEW_RELEASE_PATH="../../../"
export OLD_RELEASE_PATH="../../../../../terp-core"
export CHAIN_ID=${CHAIN_ID:-"local-1"}
export MONIKER="localterp"
export DENOM="uterp"
export KEYALGO="secp256k1"
export KEYRING=${KEYRING:-"test"}
export HOME_DIR=$(eval echo "${HOME_DIR:-"~/.terpd"}")
export BINARY=${BINARY:-terpd}
export CLEAN=${CLEAN:-"true"}
export RPC=${RPC:-"26657"}
export REST=${REST:-"1317"}
export PROFF=${PROFF:-"6060"}
export P2P=${P2P:-"26656"}
export GRPC=${GRPC:-"9090"}
export GRPC_WEB=${GRPC_WEB:-"9091"}
export TIMEOUT_COMMIT=${TIMEOUT_COMMIT:-"1s"}
POLYTONE_CONTRACTS=(
  "polytone_listener.wasm"
  "polytone_note.wasm"
  "polytone_proxy.wasm"
  "polytone_voice.wasm"
  "polytone_tester.wasm"
  )

alias BINARY="$BINARY --home=$HOME_DIR"
command -v $BINARY > /dev/null 2>&1 || { echo >&2 "$BINARY command not found. Ensure this is setup / properly installed in your GOPATH (make install)."; exit 1; }
command -v jq > /dev/null 2>&1 || { echo >&2 "jq not installed. More info: https://stedolan.github.io/jq/download/"; exit 1; }
echo "performing v6 upgrade"
pkill -f terpd
(
    echo "Building version we are updating to..."
    cd $OLD_RELEASE_PATH &&
    make install 
    echo "build complete"
) &
BUILD_PID=$!
wait $BUILD_PID
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
    echo "completed successfully"
    echo "BUILD_PID: $BUILD_PID"
else
    echo "build failed (Build: $BUILD_EXIT)"
    exit 1
fi

$BINARY config keyring-backend $KEYRING
$BINARY config chain-id $CHAIN_ID

tune_config () {
sed -i.bak -e 's/laddr = "tcp:\/\/127.0.0.1:26657"/c\laddr = "tcp:\/\/0.0.0.0:'$RPC'"/g' $HOME_DIR/config/config.toml
sed -i.bak -e 's/cors_allowed_origins = \[\]/cors_allowed_origins = \["\*"\]/g' $HOME_DIR/config/config.toml
sed -i.bak -e 's/address = "tcp:\/\/localhost:1317"/address = "tcp:\/\/0.0.0.0:'$REST'"/g' $HOME_DIR/config/app.toml
sed -i.bak -e 's/enable = false/enable = true/g' $HOME_DIR/config/app.toml
sed -i.bak -e 's/pprof_laddr = "localhost:6060"/pprof_laddr = "localhost:'$PROFF_LADDER'"/g' $HOME_DIR/config/config.toml
sed -i.bak -e 's/laddr = "tcp:\/\/0.0.0.0:26656"/laddr = "tcp:\/\/0.0.0.0:'$P2P'"/g' $HOME_DIR/config/config.toml
sed -i.bak -e 's/address = "localhost:9090"/address = "0.0.0.0:'$GRPC'"/g' $HOME_DIR/config/app.toml
sed -i.bak -e 's/address = "localhost:9091"/address = "0.0.0.0:'$GRPC_WEB'"/g' $HOME_DIR/config/app.toml
sed -i.bak -e 's/timeout_commit = "5s"/timeout_commit = "'$TIMEOUT_COMMIT'"/g' $HOME_DIR/config/config.toml
}


from_scratch () {
  make install
  rm -rf $HOME_DIR && echo "Removed $HOME_DIR"  
  # terp1efd63aw40lxf3n4mhf7dzhjkr453axurajg60e
  echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry" | BINARY keys add $KEY --keyring-backend $KEYRING --algo $KEYALGO --recover
  # terp1hj5fveer5cjtn4wd6wstzugjfdxzl0xppxm7xs
  echo "wealth flavor believe regret funny network recall kiss grape useless pepper cram hint member few certain unveil rather brick bargain curious require crowd raise" | BINARY keys add $KEY2 --keyring-backend $KEYRING --algo $KEYALGO --recover
  BINARY init $MONIKER --chain-id $CHAIN_ID --default-denom uterp
  # Function updates the config based on a jq argument as a string
  update_test_genesis () {    
    cat $HOME_DIR/config/genesis.json | jq "$1" > $HOME_DIR/config/tmp_genesis.json && mv $HOME_DIR/config/tmp_genesis.json $HOME_DIR/config/genesis.json
  }

  update_test_genesis '.consensus_params["block"]["max_gas"]="100000000"'
  update_test_genesis '.app_state["gov"]["params"]["min_deposit"]=[{"denom": "uterp","amount": "1000000"}]'
  update_test_genesis '.app_state["gov"]["voting_params"]["voting_period"]="15s"'
  update_test_genesis '.app_state["staking"]["params"]["bond_denom"]="uterp"'  
  update_test_genesis '.app_state["staking"]["params"]["min_commission_rate"]="0.050000000000000000"'  
  update_test_genesis '.app_state["gov"]["params"]["voting_period"]="5s"'
  update_test_genesis '.app_state["gov"]["params"]["expedited_voting_period"]="2s"'
  update_test_genesis '.app_state["mint"]["params"]["mint_denom"]="uterp"'  
  update_test_genesis '.app_state["crisis"]["constant_fee"]={"denom": "uterp","amount": "1000"}'  

  # Custom Modules 
  BINARY genesis add-genesis-account $KEY 1000000000000uterp,1000uthiolx --keyring-backend $KEYRING
  BINARY genesis add-genesis-account $KEY2 100000000000uterp,1000uthiolx --keyring-backend $KEYRING
  BINARY genesis gentx $KEY 1000000uterp --keyring-backend $KEYRING --chain-id $CHAIN_ID
  BINARY genesis collect-gentxs
  BINARY genesis validate-genesis
  VAL1_OP_ADDR=$(jq -r '.body.messages[0].validator_address' $HOME_DIR/config/gentx/gentx-*.json)
  echo "VAL1_OP_ADDR: $VAL1_OP_ADDR"
}

# check if CLEAN is not set to false
if [ "$CLEAN" != "false" ]; then
  echo "Starting from a clean state"
  from_scratch
  tune_config
fi

echo "Starting node..."
BINARY start --pruning=nothing  --minimum-gas-prices=0uterp --rpc.laddr="tcp://0.0.0.0:$RPC" --wasm.skip_wasmvm_version_check &
INPLACE_TESTNET=$!
echo "INPLACE_TESTNET: $INPLACE_TESTNET"
sleep 1

####################################################################
# C. UPGRADE
####################################################################
echo "lets upgrade "
sleep 1
cat <<EOF > "$HOME_DIR/upgrade.json" 
{
 "messages": [
  {
   "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
   "authority": "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
   "plan": {
    "name": "$UPGRADE_VERSION_TITLE",
    "time": "0001-01-01T00:00:00Z",
    "height": "6",
    "info": "https://github.com/permissionlessweb/terp-core/releases/download/v6.0.0/terpd",
    "upgraded_client_state": null
   }
  }
 ],
 "metadata": "ipfs://CID",
 "deposit": "5000000000$DENOM",
 "title": "$UPGRADE_VERSION_TITLE",
 "summary": "mememe",
 "expedited": true 
}
EOF
sleep 1
BINARY tx staking delegate  $VAL1_OP_ADDR  10000000000uterp --from "$KEY2" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR --keyring-backend $KEYRING -y
echo "propose upgrade using expedited proposal..."
BINARY tx gov submit-proposal $HOME_DIR/upgrade.json --gas auto --gas-adjustment 1.5 --fees="2000$DENOM" \
 --chain-id=$CHAIN_ID --home=$HOME_DIR --from="$KEY"  --keyring-backend $KEYRING -y
sleep 1
BINARY tx gov vote 1 yes --from "$KEY" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR  --keyring-backend $KEYRING -y
BINARY tx gov vote 1 yes --from "$KEY2" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR --keyring-backend $KEYRING -y
sleep 1
BINARY q gov proposal 1 --home $HOME_DIR
BINARY tx tokenfactory create-denom  $TFDENOM --from "$KEY" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR --keyring-backend $KEYRING -y
sleep 3
####################################################################
# C. UPGRADE
####################################################################
echo "performing v6 upgrade"
pkill -f terpd
(
    echo "Building version we are updating to..."
    
    cd $NEW_RELEASE_PATH &&
    make install 
    echo "build complete"
) &
BUILD_PID=$!
wait $BUILD_PID
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
    echo "completed successfully"
    echo "BUILD_PID: $BUILD_PID"
else
    echo "build failed (Build: $BUILD_EXIT)"
    exit 1
fi

echo "Running Upgrade"
trap 'pkill -f 'BINARY EXIT
BINARY start --home $HOME_DIR --wasm.skip_wasmvm_version_check &
sleep 6
BINARY q tokenfactory params --home $HOME_DIR 
BINARY tx tokenfactory create-denom  hthththt --from "$KEY2" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR --keyring-backend $KEYRING -y

## upload polytone 
  for contract in "${POLYTONE_CONTRACTS[@]}"; do
    echo "Uploading $contract WASM file..."
    # get tx hash 
    BINARY tx wasm upload ../../../artifacts/$contract --home $HOME_DIR  --from $KEY --chain-id $CHAIN_ID --gas auto --gas-adjustment 1.4 --gas auto --fees 400000uterp -y 
    sleep 1.5
    echo "Uploaded $contract WASM file successfully."
done