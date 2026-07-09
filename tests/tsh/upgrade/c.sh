#!/bin/bash
echo "performing v520 upgrade"

# ####################################################################
# # A. START
# ####################################################################
# export UPGRADE_VERSION_TITLE=${UPGRADE_VERSION_TITLE:-"v520"}
# export KEY="terp1"
# export KEY2="terp2"
# export TFDENOM="skeret"
# export NEW_RELEASE_PATH="../../../"
# export OLD_RELEASE_PATH="../../../../../terp-core"
# export CONFIG_FLAGS="--keyring-backend $KEYRING"

# # Chain definitions - easy to extend to 3+ chains later
# declare -A CHAIN1=(
#     [id]="local-1"
#     [home]="${HOME_DIR:-~/.terpd}"
#     [rpc]=26657
#     [rest]=1317
#     [p2p]=26656
#     [grpc]=9090
#     [grpc_web]=9091
#     [prof]=6060
# )

# declare -A CHAIN2=(
#     [id]="local-2"
#     [home]="${HOME_DIR2:-~/.terpd2}"
#     [rpc]=23657
#     [rest]=1337
#     [p2p]=23656
#     [grpc]=9390
#     [grpc_web]=9391
#     [prof]=6061
# )

# MONIKER="localterp"
# DENOM="uterp"
# KEYRING=${KEYRING:-"test"}
# KEYALGO="secp256k1"
# TIMEOUT_COMMIT=${TIMEOUT_COMMIT:-"1s"}
# BINARY=${BINARY:-terpd}
# CLEAN=${CLEAN:-"true"}

# POLYTONE_CONTRACTS=(
#     "polytone_listener.wasm"
#     "polytone_note.wasm"
#     "polytone_proxy.wasm"
#     "polytone_voice.wasm"
#     "polytone_tester.wasm"
# )

# POLYTONE_CONTRACTS=(
#   "polytone_listener.wasm"
#   "polytone_note.wasm"
#   "polytone_proxy.wasm"
#   "polytone_voice.wasm"
#   "polytone_tester.wasm"
#   )

# command -v $BINARY > /dev/null 2>&1 || { echo >&2 "$BINARY command not found. Ensure this is setup / properly installed in your GOPATH (make install)."; exit 1; }
# command -v jq > /dev/null 2>&1 || { echo >&2 "jq not installed. More info: https://stedolan.github.io/jq/download/"; exit 1; }
# pkill -f $BINARY


# $BINARY config keyring-backend $KEYRING
# $BINARY config chain-id "${CHAIN1[id]}"

# $BINARY config keyring-backend $KEYRING
# $BINARY config chain-id "${CHAIN2[id]}"

# run_on_chain() {
#     local home_dir=$1
#     shift
#     "$BINARY" --home="$home_dir" $CONFIG_FLAGS "$@"
# }

# # Run same command on both chains
# for_each_chain() {
#     local cmd="$1"
#     shift
#     for chain in "${!CHAIN1[@]}" "${!CHAIN2[@]}"; do
#         if [[ $chain == "CHAIN1" ]]; then
#             eval "local home=\${CHAIN1[home]}"
#         else
#             eval "local home=\${CHAIN2[home]}"
#         fi
#         echo "→ Running on ${home}: $cmd $*"
#         run_on_chain "$home" "$cmd" "$@"
#     done
# }

# build_version() {
#     local path=$1
#     echo "Building from $path..."
#     (cd "$path" && make install)
# }

# update_genesis() {
#     local home=$1
#     local jq_cmd=$2

#     cat "$home/config/genesis.json" | jq "$jq_cmd" > "$home/config/tmp_genesis.json"
#     mv "$home/config/tmp_genesis.json" "$home/config/genesis.json"
# }


# tune_config() {
#     local home=$1 rpc rest p2p grpc grpc_web prof
#     sed -i.bak -e "s|laddr = \"tcp://127.0.0.1:26657\"|laddr = \"tcp://0.0.0.0:$rpc\"|g" "$home/config/config.toml"
#     sed -i.bak -e 's|cors_allowed_origins = \[\]|cors_allowed_origins = ["*"]|g' "$home/config/config.toml"
#     sed -i.bak -e "s|address = \"tcp://localhost:1317\"|address = \"tcp://0.0.0.0:$rest\"|g" "$home/config/app.toml"
#     sed -i.bak -e 's|enable = false|enable = true|g' "$home/config/app.toml"
#     sed -i.bak -e "s|pprof_laddr = \"localhost:6060\"|pprof_laddr = \"localhost:$prof\"|g" "$home/config/config.toml"
#     sed -i.bak -e "s|laddr = \"tcp://0.0.0.0:26656\"|laddr = \"tcp://0.0.0.0:$p2p\"|g" "$home/config/config.toml"
#     sed -i.bak -e "s|address = \"localhost:9090\"|address = \"0.0.0.0:$grpc\"|g" "$home/config/app.toml"
#     sed -i.bak -e "s|address = \"localhost:9091\"|address = \"0.0.0.0:$grpc_web\"|g" "$home/config/app.toml"
#     sed -i.bak -e "s|timeout_commit = \"5s\"|timeout_commit = \"$TIMEOUT_COMMIT\"|g" "$home/config/config.toml"
# }


# from_scratch() {
#     rm -rf "${CHAIN1[home]}" "${CHAIN2[home]}"
#     (
#     echo "Building version we are updating to..."
#     cd $OLD_RELEASE_PATH &&
#     make install 
#     echo "build complete"
#     ) &
#     BUILD_PID=$!
#     wait $BUILD_PID
#     BUILD_EXIT=$?
#     if [ $BUILD_EXIT -eq 0 ]; then
#         echo "completed successfully"
#         echo "BUILD_PID: $BUILD_PID"
#     else
#         echo "build failed (Build: $BUILD_EXIT)"
#         exit 1
#     fi
#     for home in "${CHAIN1[home]}" "${CHAIN2[home]}"; do
#     run_on_chain "$home" config keyring-backend "$KEYRING"
#     run_on_chain "$home" config chain-id "$( [[ $home == "${CHAIN1[home]}" ]] && echo "${CHAIN1[id]}" || echo "${CHAIN2[id]}" )"
#     done
#     # Recover keys
#   echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry" | $BINARY keys add $KEY --keyring-backend $KEYRING --algo $KEYALGO --recover
#   echo "wealth flavor believe regret funny network recall kiss grape useless pepper cram hint member few certain unveil rather brick bargain curious require crowd raise" | $BINARY keys add $KEY2 --keyring-backend $KEYRING --algo $KEYALGO --recover


#     run_on_chain "${CHAIN1[home]}" init "$MONIKER" --chain-id "${CHAIN1[id]}" --default-denom "$DENOM"
#     run_on_chain "${CHAIN2[home]}" init "$MONIKER" --chain-id "${CHAIN2[id]}" --default-denom "$DENOM"

#         # Use --source instead of piping (more reliable in recent SDKs)
#     run_on_chain "${CHAIN1[home]}" keys add "$KEY" \
#         --keyring-backend "$KEYRING" \
#         --algo "$KEYALGO" \
#         \
#         --source <(echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry") \
#         --no-backup 2>/dev/null || true

#     run_on_chain "${CHAIN1[home]}" keys add "$KEY2" \
#         --keyring-backend "$KEYRING" \
#         --algo "$KEYALGO" \
#         --recover \
#         --source <(echo "wealth flavor believe regret funny network recall kiss grape useless pepper cram hint member few certain unveil rather brick bargain curious require crowd raise") \
#         --no-backup 2>/dev/null || true

#     # Also add them to the second chain's keyring
#     run_on_chain "${CHAIN2[home]}" keys add "$KEY" \
#         --keyring-backend "$KEYRING" \
#         --algo "$KEYALGO" \
#         --recover \
#         --source <(echo "decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry") \
#         --no-backup 2>/dev/null || true

#     run_on_chain "${CHAIN2[home]}" keys add "$KEY2" \
#         --keyring-backend "$KEYRING" \
#         --algo "$KEYALGO" \
#         --recover \
#         --source <(echo "wealth flavor believe regret funny network recall kiss grape useless pepper cram hint member few certain unveil rather brick bargain curious require crowd raise") \
#         --no-backup 2>/dev/null || true

#     # Common genesis updates
#     for home in "${CHAIN1[home]}" "${CHAIN2[home]}"; do
#         update_genesis "$home" '.consensus_params["block"]["max_gas"]="100000000"'
#         update_genesis "$home" '.app_state["gov"]["params"]["min_deposit"]=[{"denom": "uterp","amount": "1000000"}]'
#         update_genesis "$home" '.app_state["gov"]["voting_params"]["voting_period"]="15s"'
#         update_genesis "$home" '.app_state["staking"]["params"]["bond_denom"]="uterp"'
#         update_genesis "$home" '.app_state["staking"]["params"]["min_commission_rate"]="0.050000000000000000"'
#         update_genesis "$home" '.app_state["gov"]["params"]["voting_period"]="5s"'
#         update_genesis "$home" '.app_state["gov"]["params"]["expedited_voting_period"]="2s"'
#         update_genesis "$home" '.app_state["mint"]["params"]["mint_denom"]="uterp"'
#         update_genesis "$home" '.app_state["crisis"]["constant_fee"]={"denom": "uterp","amount": "1000"}'
#     done

#     # Genesis accounts + gentxs
#     run_on_chain "${CHAIN1[home]}" genesis add-genesis-account "$KEY"  1000000000000uterp,1000uthiolx --keyring-backend "$KEYRING"
#     run_on_chain "${CHAIN1[home]}" genesis add-genesis-account "$KEY2" 100000000000uterp,1000uthiolx --keyring-backend "$KEYRING"
#     run_on_chain "${CHAIN2[home]}" genesis add-genesis-account "$KEY"  1000000000000uterp,1000uthiolx --keyring-backend "$KEYRING"
#     run_on_chain "${CHAIN2[home]}" genesis add-genesis-account "$KEY2" 100000000000uterp,1000uthiolx --keyring-backend "$KEYRING"

#     run_on_chain "${CHAIN1[home]}" genesis gentx "$KEY" 10000000000uterp --keyring-backend "$KEYRING" --chain-id "${CHAIN1[id]}"
#     run_on_chain "${CHAIN2[home]}" genesis gentx "$KEY" 1000000uterp --keyring-backend "$KEYRING" --chain-id "${CHAIN2[id]}"

#     run_on_chain "${CHAIN1[home]}" genesis collect-gentxs
#     run_on_chain "${CHAIN2[home]}" genesis collect-gentxs

#     run_on_chain "${CHAIN1[home]}" genesis validate-genesis
#     run_on_chain "${CHAIN2[home]}" genesis validate-genesis
# }


# ####################################################################
# # Main Flow
# ####################################################################
# pkill -f "$BINARY" || true

# if [ "$CLEAN" != "false" ]; then
#     echo "Starting from clean state..."
#     build_version "$OLD_RELEASE_PATH"
#     from_scratch

#     tune_config "${CHAIN1[home]}" "${CHAIN1[rpc]}" "${CHAIN1[rest]}" "${CHAIN1[p2p]}" "${CHAIN1[grpc]}" "${CHAIN1[grpc_web]}" "${CHAIN1[prof]}"
#     tune_config "${CHAIN2[home]}" "${CHAIN2[rpc]}" "${CHAIN2[rest]}" "${CHAIN2[p2p]}" "${CHAIN2[grpc]}" "${CHAIN2[grpc_web]}" "${CHAIN2[prof]}"
# fi

# # Start both nodes
# run_on_chain "${CHAIN1[home]}" start --pruning=nothing --minimum-gas-prices=0uterp --rpc.laddr="tcp://0.0.0.0:${CHAIN1[rpc]}" --wasm.skip_wasmvm_version_check &
# run_on_chain "${CHAIN2[home]}" start --pruning=nothing --minimum-gas-prices=0uterp --rpc.laddr="tcp://0.0.0.0:${CHAIN2[rpc]}" --wasm.skip_wasmvm_version_check &
# echo "Both nodes started..."
# sleep 10
# ####################################################################
# # B. RELAYER CONFIG
# ####################################################################
# (
# ## create mnemonic file, grab menmonic from relayer key file, print to new txt file
# REL_MNEMONIC=$(jq -r '.mnemonic' $VAL1HOME/$RELAYERFILE)
# echo "$REL_MNEMONIC" >  $VAL1HOME/mnemonic.txt
# ## if hermes command does not exist, install hermes
# if ! command -v hermes &> /dev/null
# then
#     cargo install ibc-relayer-cli --bin hermes --locked
# fi

# ## configure hermes with chain & and b
# rm -rf $HERMES && mkdir -p $HERMES
# cp ../$HERMES_CFG_TEMPLATE_PATH $HERMES/config.toml

# ## modify $HERMES_CFG toml with correct values 
# sed -i.bak "/^\[chains\]/,/^\[/ { 
#     /id = \"$CHAINID_A\"/ { 
#         s/rpc_addr.*/rpc_addr = \"http:\/\/127.0.0.1:$VAL1_RPC_PORT\"/; 
#         s/grpc_addr.*/grpc_addr = \"http:\/\/127.0.0.1:$VAL1_GRPC_PORT\"/; 
#         s/event_source.url.*/event_source.url = \"ws:\/\/127.0.0.1:$VAL1_RPC_PORT\/websocket\"/; 
#         s/key_name.*/key_name = \"$VAL\"/; 
#     } 
# }" "$HERMES/config.toml"

# sed -i.bak "/^\[chains\]/,/^\[/ { 
#     /id = \"$CHAINID_B\"/ { 
#         s/rpc_addr.*/rpc_addr = \"http:\/\/127.0.0.1:$VAL2_RPC_PORT\"/; 
#         s/grpc_addr.*/grpc_addr = \"http:\/\/127.0.0.1:$VAL2_GRPC_PORT\"/; 
#         s/event_source.url.*/event_source.url = \"ws:\/\/127.0.0.1:$VAL2_RPC_PORT\/websocket\"/; 
#         s/key_name.*/key_name = \"$VAL\"/; 
#     } 
# }" "$HERMES/config.toml"


# echo "Clean up hermes"
# hermes keys delete --chain "$CHAINID_A" --all
# hermes keys delete --chain "$CHAINID_B" --all

# echo "import keys"
# hermes keys add --key-name $RELAYER --chain $CHAINID_A --hd-path "m/44'/118'/0'/0/0" --mnemonic-file $VAL1HOME/mnemonic.txt
# hermes keys add --key-name $RELAYER --chain $CHAINID_B --hd-path "m/44'/118'/0'/0/0" --mnemonic-file $VAL1HOME/mnemonic.txt

# sleep 15
# ) &
# BUILD_RELAYER_PID=$!
# wait $BUILD_RELAYER_PID
# RELAYER_EXIT=$?

# ####################################################################
# # C. POLYTONE CONFIG
# ####################################################################
# (
# POLYONE_LISTENER_ID=1
# POLYONE_NOTE_ID=2
# POLYONE_PROXY_ID=3
# POLYONE_VOICE_ID=4
# POLYONE_TESTER_ID=5

# # init note
#  BINARY tx wasm i $POLYONE_NOTE_ID '{"block_max_gas": "100000000" }' --from $DEL --home $VAL1HOME --chain-id $CHAINID_A --no-admin --label="note contract chain1" --fees 400000uterp --gas auto --gas-adjustment 1.3 -y 
#  BINARY tx wasm i $POLYONE_NOTE_ID '{"block_max_gas": "100000000" }' --from $USER --home $VAL2HOME --chain-id $CHAINID_B --no-admin --label="note contract chain2" --fees 400000uterp --gas auto --gas-adjustment 1.3 -y
# sleep 1
#  BINARY tx wasm i $POLYONE_VOICE_ID '{"proxy_code_id":"3","block_max_gas":"100000000" }' --from $DEL --home $VAL1HOME --chain-id $CHAINID_A --no-admin --label="voice contract chain1" -y --fees 400000uterp --gas auto --gas-adjustment 1.3
#  BINARY tx wasm i $POLYONE_VOICE_ID '{"proxy_code_id":"3","block_max_gas":"100000000" }' --from $DEL --home $VAL2HOME --chain-id $CHAINID_B --no-admin --label="voice contract chain1" -y --fees 400000uterp --gas auto --gas-adjustment 1.3
# sleep 1
#  BINARY tx wasm i $POLYONE_TESTER_ID '{}' --from $DEL --home $VAL1HOME --no-admin --label="tester contract chain1" --fees 400000uterp --gas auto --gas-adjustment 1.3 -y 
#  BINARY tx wasm i $POLYONE_TESTER_ID '{}' --from $DEL --home $VAL2HOME --no-admin --label="tester contract chain2" --fees 400000uterp --gas auto --gas-adjustment 1.3 -y 
# sleep 1
# POLYONE_NOTE_ADDR_A=$(BINARY q wasm lca $POLYONE_NOTE_ID  --home $VAL1HOME -o json | jq -r .contracts[0])
# POLYONE_NOTE_ADDR_B=$(BINARY q wasm lca $POLYONE_NOTE_ID  --home $VAL2HOME -o json | jq -r .contracts[0])
# POLYONE_TESTER_ADDR_A=$(BINARY q wasm lca $POLYONE_TESTER_ID --home $VAL1HOME -o json | jq -r .contracts[0])
# POLYONE_TESTER_ADDR_B=$(BINARY q wasm lca $POLYONE_TESTER_ID --home $VAL2HOME -o json | jq -r .contracts[0])
# POLYONE_VOICE_ADDR_A=$(BINARY q wasm lca $POLYONE_VOICE_ID  --home $VAL1HOME -o json | jq -r .contracts[0])
# POLYONE_VOICE_ADDR_B=$(BINARY q wasm lca $POLYONE_VOICE_ID  --home $VAL2HOME -o json | jq -r .contracts[0])
# echo "POLYONE_NOTE_ADDR_A: $POLYONE_NOTE_ADDR_A"
# echo "POLYONE_NOTE_ADDR_B: $POLYONE_NOTE_ADDR_B"
# echo "POLYONE_TESTER_ADDR_A: $POLYONE_TESTER_ADDR_A"
# echo "POLYONE_TESTER_ADDR_B: $POLYONE_TESTER_ADDR_B"
# echo "POLYONE_VOICE_ADDR_A: $POLYONE_VOICE_ADDR_A"
# echo "POLYONE_VOICE_ADDR_B: $POLYONE_VOICE_ADDR_B"
# BINARY tx wasm i $POLYONE_LISTENER_ID "{\"note\":\"$POLYONE_NOTE_ADDR_A\"}" --from $DEL --home $VAL1HOME --no-admin --label="listener contract chain1" --fees 400000uterp --gas auto --gas-adjustment 1.3 -y 
# BINARY tx wasm i $POLYONE_LISTENER_ID "{\"note\":\"$POLYONE_NOTE_ADDR_B\"}" --from $DEL --home $VAL2HOME --no-admin --label="listener contract chain2" --fees 400000uterp --gas auto --gas-adjustment 1.3 -y 
# ) &
# POLYTONE_WASM_PID=$!
# wait $POLYTONE_WASM_PID
# POLYTONE_EXIT=$?

# ####################################################################
# # A. UPLOAD WASM 
# ####################################################################
# ## if polytone wasm files dont exist in  ./bin, download 
# if [ -z "$(ls -A ./bins)" ]; then
#   sh download.sh
#   while [ -z "$(ls -A ./bin)" ]; do
#     sleep 1
#   done
# fi

# ## upload polytone 
#   for contract in "${POLYTONE_CONTRACTS[@]}"; do
#     echo "Uploading $contract WASM file..."
#     # get tx hash 
#     BINARY tx wasm upload --home $VAL2HOME ./bins/$contract --from $USER --chain-id $CHAINID_B --gas auto --gas-adjustment 1.4 --gas auto --fees 400000uterp -y 
#     BINARY tx wasm upload --home $VAL1HOME ./bins/$contract --from $DEL  --chain-id $CHAINID_A --gas auto --gas-adjustment 1.4 --gas auto --fees 400000uterp -y 
#     sleep 2
#     echo "Uploaded $contract WASM file successfully."
#     sleep 4
# done

# ####################################################################
# # C. UPGRADE
# ####################################################################
# echo "lets upgrade "
# sleep 1
# cat <<EOF > "$HOME_DIR/upgrade.json" 
# {
#  "messages": [
#   {
#    "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
#    "authority": "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
#    "plan": {
#     "name": "$UPGRADE_VERSION_TITLE",
#     "time": "0001-01-01T00:00:00Z",
#     "height": "6",
#     "info": "https://github.com/permissionlessweb/terp-core/releases/download/v6.0.0/terpd",
#     "upgraded_client_state": null
#    }
#   }
#  ],
#  "metadata": "ipfs://CID",
#  "deposit": "5000000000$DENOM",
#  "title": "$UPGRADE_VERSION_TITLE",
#  "summary": "mememe",
#  "expedited": true 
# }
# EOF
# sleep 1
# BINARY tx staking delegate  $VAL1_OP_ADDR  10000000000uterp --from "$KEY2" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR --keyring-backend $KEYRING -y
# echo "propose upgrade using expedited proposal..."
# BINARY tx gov submit-proposal $HOME_DIR/upgrade.json --gas auto --gas-adjustment 1.5 --fees="2000$DENOM" \
#  --chain-id=$CHAIN_ID --home=$HOME_DIR --from="$KEY"  --keyring-backend $KEYRING -y
# sleep 1
# BINARY tx gov vote 1 yes --from "$KEY" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR  --keyring-backend $KEYRING -y
# BINARY tx gov vote 1 yes --from "$KEY2" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR --keyring-backend $KEYRING -y
# sleep 1
# BINARY q gov proposal 1 --home $HOME_DIR
# BINARY tx tokenfactory create-denom  $TFDENOM --from "$KEY" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR --keyring-backend $KEYRING -y
# sleep 3
# pkill -f terpd
# (
#     echo "Building version we are updating to..."
    
#     cd $NEW_RELEASE_PATH &&
#     make install 
#     echo "build complete"
# ) &
# BUILD_PID=$!
# wait $BUILD_PID
# BUILD_EXIT=$?
# if [ $BUILD_EXIT -eq 0 ]; then
#     echo "completed successfully"
#     echo "BUILD_PID: $BUILD_PID"
# else
#     echo "build failed (Build: $BUILD_EXIT)"
#     exit 1
# fi

# if [ $POLYTONE_EXIT -eq 0 ] && [ $RELAYER_EXIT -eq 0 ]; then
#     echo "completed successfully"
#     echo "BUILD_PID: $BUILD_PID"
# else
#     echo "build failed (Build: $BUILD_EXIT)"
#     exit 1
# fi

# echo "Running Upgrade"
# BINARY start --home $HOME_DIR --log_level trace
# sleep 2
# BINARY q tokenfactory params  $TFDENOM --from "$KEY2" --home $HOME_DIR 
# BINARY tx tokenfactory create-denom  $TFDENOM2 --from "$KEY2" --gas auto --gas-adjustment 1.2 --fees 1000$DENOM --chain-id $CHAIN_ID --home $HOME_DIR --keyring-backend $KEYRING -y

# ####################################################################
# # E. VERIFY
# ####################################################################
# # check ibc wasm still works
# # check 08-wasm light client works
# # validate uploads of vanilla wasm works
# # validate custom vm 