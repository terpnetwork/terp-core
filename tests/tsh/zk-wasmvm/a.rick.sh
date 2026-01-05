#!/bin/bash
BIND=terpd
CHAINID_A=test-1

# setup test keys.
VAL=val
RELAYER=relayer
DEL=del
USER=user
DELFILE="test-keys/$DEL.json"
VALFILE="test-keys/$VAL.json"
RELAYERFILE="test-keys/$RELAYER.json"
USERFILE="test-keys/$USER.json"

# file paths
CHAINDIR=../data/polytone
VAL1HOME=$CHAINDIR/$CHAINID_A/val1
ZK_COSMWASM=../../interchaintest/contracts/zk_wasmvm_test.wasm
ZK_VK=../../interchaintest/circuits/no_rick.bin
PROOF_FILE="../../interchaintest/circuits/no_rick_proof.json"
# Define the new ports for val1 on chain a
VAL1_API_PORT=1317
VAL1_GRPC_PORT=9090
VAL1_GRPC_WEB_PORT=9091
VAL1_PROXY_APP_PORT=26658
VAL1_RPC_PORT=26657
VAL1_PPROF_PORT=6060
VAL1_P2P_PORT=26656

echo "Creating $BIND instance for VAL1_A: home=$VAL1HOME | chain-id=$CHAINID_A | p2p=:$VAL1_P2P_PORT | rpc=:$VAL1_RPC_PORT | profiling=:$VAL1_PPROF_PORT | grpc=:$VAL1_GRPC_PORT"
trap 'pkill -f '"$BIND" EXIT

defaultCoins="100000000000uterp"  # 100K
delegate="1000000uterp" # 1btsg



####################################################################
# A. CHAINS CONFIG
####################################################################

rm -rf $VAL1HOME $VAL2HOME 
rm -rf $VAL1HOME/test-keys

# initialize chains
$BIND init $CHAINID_A --overwrite --home $VAL1HOME --chain-id $CHAINID_A &&
sleep 1

mkdir $VAL1HOME/test-keys

# cli config
$BIND --home $VAL1HOME config keyring-backend test
$BIND --home $VAL1HOME config chain-id $CHAINID_A &&
$BIND --home $VAL1HOME config node tcp://localhost:$VAL1_RPC_PORT &&
sleep 1

# optimize val1 genesis for testing
jq ".app_state.crisis.constant_fee.denom = \"uterp\" |
      .app_state.staking.params.bond_denom = \"uterp\" |
      .app_state.mint.params.blocks_per_year = \"20000000\" |
      .app_state.mint.params.mint_denom = \"uterp\" |
      .app_state.merkledrop.params.creation_fee.denom = \"uterp\" |
      .app_state.gov.voting_params.voting_period = \"15s\" |
      .app_state.gov.voting_params.voting_period = \"15s\" |
      .app_state.gov.params.voting_period = \"15s\" |
      .app_state.gov.params.expedited_voting_period = \"12s\" |
      .app_state.gov.params.min_deposit[0].denom = \"uterp\" |
      .app_state.fantoken.params.burn_fee.denom = \"uterp\" |
      .app_state.fantoken.params.issue_fee.denom = \"uterp\" |
      .app_state.slashing.params.signed_blocks_window = \"15\" |
      .app_state.slashing.params.min_signed_per_window = \"0.500000000000000000\" |
      .app_state.fantoken.params.mint_fee.denom = \"uterp\"" $VAL1HOME/config/genesis.json > $VAL1HOME/config/tmp.json
# give val2 genesis optimized genesis
mv $VAL1HOME/config/tmp.json $VAL1HOME/config/genesis.json

yes | $BIND  --home $VAL1HOME keys add $VAL --output json > $VAL1HOME/$VALFILE 2>&1 &&
yes | $BIND  --home $VAL1HOME keys add $USER --output json > $VAL1HOME/$USERFILE 2>&1 &&
yes | $BIND  --home $VAL1HOME keys add $DEL --output json > $VAL1HOME/$DELFILE 2>&1 && 
yes | $BIND  --home $VAL1HOME keys add $RELAYER  --output json > $VAL1HOME/$RELAYERFILE 2>&1 &&
RELAYERADDR=$(jq -r '.address' $VAL1HOME/$RELAYERFILE)
DEL1ADDR=$(jq -r '.address' $VAL1HOME/$DELFILE)
VAL1A_ADDR=$(jq -r '.address'  $VAL1HOME/$VALFILE)
USERAADDR=$(jq -r '.address' $VAL1HOME/$USERFILE)


$BIND --home $VAL1HOME genesis add-genesis-account "$USERAADDR" $defaultCoins &&
$BIND --home $VAL1HOME genesis add-genesis-account "$RELAYERADDR" $defaultCoins &&
$BIND --home $VAL1HOME genesis add-genesis-account "$VAL1A_ADDR" $defaultCoins &&
$BIND --home $VAL1HOME genesis add-genesis-account "$DEL1ADDR" $defaultCoins &&
$BIND --home $VAL1HOME genesis gentx $VAL $delegate --chain-id $CHAINID_A &&
$BIND genesis collect-gentxs --home $VAL1HOME &&

# app & config modiifications
# config.toml
sed -i.bak -e "s/^proxy_app *=.*/proxy_app = \"tcp:\/\/127.0.0.1:$VAL1_PROXY_APP_PORT\"/g" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[rpc\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[rpc\]/,/^\[/ s/address.*/address = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[p2p\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/0.0.0.0:$VAL1_P2P_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak -e "s/^grpc_laddr *=.*/grpc_laddr = \"\"/g" $VAL1HOME/config/config.toml &&
sed -i.bak -e "s/^pprof_laddr *=.*/pprof_laddr = \"localhost:6060\"/g" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"1s\"/" "$VAL1HOME/config/config.toml"
# app.toml
sed -i.bak "/^\[api\]/,/^\[/ s/minimum-gas-prices.*/minimum-gas-prices = \"0.0uterp\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/0.0.0.0:$VAL1_API_PORT\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_PORT\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[grpc-web\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_WEB_PORT\"/" $VAL1HOME/config/app.toml &&

# Start chains
echo "Starting chain 1..."
RUST_BACKTRACE=1 $BIND start --home $VAL1HOME --wasm.skip_wasmvm_version_check --log_level "*:info" & 
VAL1A_PID=$!
echo "VAL1A_PID: $VAL1A_PID"
sleep 3

echo "RELAYERADDR: $RELAYERADDR"
echo "DEL1ADDR: $DEL1ADDR"
echo "VAL1A_ADDR: $VAL1A_ADDR"
echo "USERAADDR: $USERAADDR"

####################################################################
# B. PROOF GENERATION
####################################################################
# we have pre-generated the proofs.
# this can be done by simply `cargo run` in the same directory as this file.

####################################################################
# A. UPLOAD WASM 
####################################################################
$BIND tx wasm headstash --home $VAL1HOME $ZK_COSMWASM $ZK_VK --from $USER --chain-id $CHAINID_A --gas auto --gas-adjustment 1.4 --gas auto --fees 400000uterp -y 
sleep 2
$BIND tx wasm i 1 '{}' --from $USER --home $VAL1HOME --chain-id $CHAINID_A --no-admin --label="note contract chain2" --fees 400000uterp --gas auto --gas-adjustment 1.3 -y

# ## CONFIRM CHECKSUMS 
# echo "Computing local checksums..."
# WASM_CHECKSUM=$(sha256sum "$ZK_COSMWASM" | awk '{print $1}')
# CIRCUIT_CHECKSUM=$(sha256sum "$ZK_VK" | awk '{print $1}')
# ONCHAIN_WASM_CHECKSUM=$($BIND query wasm code-info 1 --home $VAL1HOME --output json | jq -r '.checksum // empty')
# ONCHAIN_CIRCUIT_CHECKSUM=$($BIND query wasm circuit-info 1 --home $VAL1HOME --output json | jq -r '.checksum // empty')
# [ "$WASM_CHECKSUM" = "$ONCHAIN_WASM_CHECKSUM" ] && echo "✅ WASM checksums match!" || {
#     echo "❌ WASM checksums DO NOT match!"
#     echo "   Local: $WASM_CHECKSUM"
#     echo "   On-chain: $ONCHAIN_WASM_CHECKSUM"
#     exit 1
# }
# [ "$CIRCUIT_CHECKSUM" = "$ONCHAIN_CIRCUIT_CHECKSUM" ] && echo "✅ Circuit checksums match!" || {
#     echo "❌ Circuit checksums DO NOT match!"
#     echo "   Local: $CIRCUIT_CHECKSUM"
#     echo "   On-chain: $ONCHAIN_CIRCUIT_CHECKSUM"
#     exit 1
# }
####################################################################
# C. PROOF VERIFICATION
####################################################################
sleep 3
ZK_COSMWASM_ADDR=$($BIND q wasm lca 1  --home $VAL1HOME -o json | jq -r .contracts[0])


# Validate proof file exists
if [ ! -f "$PROOF_FILE" ]; then
    echo "Error: Proof file not found at $PROOF_FILE"
    exit 1
fi

echo "Reading proofs from JSON file..."
echo ""

# Read all words from the JSON file
WORDS=$(jq 'keys[]' "$PROOF_FILE" -r)

if [ -z "$WORDS" ]; then
    echo "Error: No proofs found in $PROOF_FILE"
    exit 1
fi

# Iterate through each word and its proof
COUNT=0
for WORD in $WORDS; do
    COUNT=$((COUNT + 1))

    # Extract proof for this word
    BASE64_PROOF=$(jq -r ".\"$WORD\".proof" "$PROOF_FILE")

    # Check if proof exists
    if [ "$BASE64_PROOF" = "null" ] || [ -z "$BASE64_PROOF" ]; then
        echo "⚠️  Skipping '$WORD': proof not found or empty"
        continue
    fi

    # Check if this is a placeholder proof
    if [[ "$BASE64_PROOF" == "ADD_"* ]]; then
        echo "⚠️  Skipping '$WORD': placeholder proof not implemented yet"
        continue
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Proof #$COUNT: $WORD"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Construct the contract execution message
    # The contract expects:
    # {
    #   "proove": {
    #     "forbidden": "<word>",
    #     "proof": "<base64_encoded_proof>"
    #   }
    # }
    MSG="{\"proove\":{\"cid\":1,\"forbidden\":\"$WORD\",\"proof\":\"$BASE64_PROOF\"}}"

    echo "Word: $WORD"
    echo "Proof size: $((${#BASE64_PROOF} / 1024 + 1)) KB"
    echo "Executing proof verification on contract..."
    echo ""

    # Execute the proof verification message on the contract
    RESULT=$($BIND tx wasm execute "$ZK_COSMWASM_ADDR" "$MSG" \
        --home "$VAL1HOME" \
        --from "$DEL" \
        -y \
        --fees 400000uterp \
        --gas auto \
        --gas-adjustment 1.3 \
        2>&1) || true

    # Check result
    if echo "$RESULT" | grep -q "code: 0\|success"; then
        echo "✅ Proof verification successful for '$WORD'"
    else
        echo "❌ Proof verification failed for '$WORD'"
        echo "Response: $RESULT"
    fi

    echo ""
    sleep 2
done
####################################################################
# D. VM VERIFICATION
####################################################################
# # query callback history for test contract 
# $BIND q wasm contract-state smart $ZK_COSMWASM_ADDR '{"history":{}}' -o json  --home $VAL1HOME

## history should exist, and the callback initiator should equal the test addr
pkill -f terpd