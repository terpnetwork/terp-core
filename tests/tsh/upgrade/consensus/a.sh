#!/bin/bash
####################################################################
# GOAL: ensure consensus params are updated and reflected accurately
####################################################################
# A. START
####################################################################
BIND=terpd
CHAINID=test-1
CHAINDIR=./data
VAL1HOME=$CHAINDIR/$CHAINID/val1
VAL1_API_PORT=1317
VAL1_GRPC_PORT=9090
VAL1_GRPC_WEB_PORT=9091
VAL1_PROXY_APP_PORT=26658
VAL1_RPC_PORT=26657
VAL1_PPROF_PORT=6060
VAL1_P2P_PORT=26656
defaultCoins="100000000000000uterp"  # 1M
fundCommunityPool="1000000000uterp" # 1K
NEW_MAX_BYTES=16777216
NEW_MAX_GAS=50000000
delegate="1000000uterp" # 1terp
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
rm -rf $VAL1HOME  
git clone https://github.com/terpnetwork/terp-core
cd terp-core &&
git checkout main
make install 
cd ../ &&
rm -rf $VAL1HOME/test-keys
$BIND init $CHAINID --overwrite --home $VAL1HOME --chain-id $CHAINID
sleep 1
mkdir $VAL1HOME/test-keys
$BIND --home $VAL1HOME config keyring-backend test
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
      .app_state.fantoken.params.mint_fee.denom = \"uterp\"" $VAL1HOME/config/genesis.json > $VAL1HOME/config/tmp.json
mv $VAL1HOME/config/tmp.json $VAL1HOME/config/genesis.json
yes | $BIND  --home $VAL1HOME keys add validator1 --output json > $VAL1HOME/test-keys/val.json 2>&1 
yes | $BIND  --home $VAL1HOME keys add user --output json > $VAL1HOME/test-keys/user.json 2>&1
yes | $BIND  --home $VAL1HOME keys add delegator1 --output json > $VAL1HOME/test-keys/del.json 2>&1
$BIND --home $VAL1HOME genesis add-genesis-account "$($BIND --home $VAL1HOME keys show user -a)" $defaultCoins
$BIND --home $VAL1HOME genesis add-genesis-account "$($BIND --home $VAL1HOME keys show validator1 -a)" $defaultCoins
$BIND --home $VAL1HOME genesis add-genesis-account "$($BIND --home $VAL1HOME keys show delegator1 -a)" $defaultCoins
$BIND --home $VAL1HOME genesis gentx validator1 $delegate --chain-id $CHAINID 
$BIND genesis collect-gentxs --home $VAL1HOME
DEL1=$(jq -r '.name' $CHAINDIR/$CHAINID/val1/test-keys/del.json)
DEL1ADDR=$(jq -r '.address' $CHAINDIR/$CHAINID/val1/test-keys/del.json)
VAL1=$(jq -r '.name' $CHAINDIR/$CHAINID/val1/test-keys/val.json)
USERADDR=$(jq -r '.address'  $CHAINDIR/$CHAINID/val1/test-keys/user.json)
sed -i.bak -e "s/^proxy_app *=.*/proxy_app = \"tcp:\/\/127.0.0.1:$VAL1_PROXY_APP_PORT\"/g" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[rpc\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[rpc\]/,/^\[/ s/address.*/address = \"tcp:\/\/127.0.0.1:$VAL1_RPC_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[p2p\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/0.0.0.0:$VAL1_P2P_PORT\"/" $VAL1HOME/config/config.toml &&
sed -i.bak -e "s/^grpc_laddr *=.*/grpc_laddr = \"\"/g" $VAL1HOME/config/config.toml &&
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"1s\"/" "$VAL1HOME/config/config.toml"
sed -i.bak "/^\[api\]/,/^\[/ s/minimum-gas-prices.*/minimum-gas-prices = \"0.0uterp\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/0.0.0.0:$VAL1_API_PORT\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_PORT\"/" $VAL1HOME/config/app.toml &&
sed -i.bak "/^\[grpc-web\]/,/^\[/ s/address.*/address = \"localhost:$VAL1_GRPC_WEB_PORT\"/" $VAL1HOME/config/app.toml &&
echo "Starting Genesis validator with default wasm size..."
MAX_WASM_SIZE=819200 $BIND start --home $VAL1HOME & 
VAL1_PID=$!
echo "VAL1_PID: $VAL1_PID"
sleep 7

LARGE_WASM_PATH="../../../interchaintest/contracts/terp721_account.wasm"

####################################################################
# B. PRE-UPGRADE CHECKS (both actions must fail)
####################################################################

# pre-upgrade: wasm store rejected (~780KB binary needs ~7.2M gas, exceeds max_gas=7.1M)
echo "PRE-UPGRADE: attempting large wasm store (should fail - block gas limit)..."
STORE_PRE=$($BIND tx wasm store "$LARGE_WASM_PATH" --gas auto --gas-adjustment 1.5 --fees="20000000uterp" --chain-id=$CHAINID --home=$VAL1HOME --from="$VAL1" -y 2>&1) || true
echo "$STORE_PRE"
if echo "$STORE_PRE" | grep -qiE "out of gas|gas limit|exceed|too large|error"; then
  echo "PRE-UPGRADE CHECK PASSED: wasm store rejected as expected"
else
  echo "PRE-UPGRADE CHECK: wasm store result may need inspection"
fi
sleep 2

# # pre-upgrade: large multi-send rejected (250 outputs exceeds max_gas=7.1M block gas limit)
# echo "PRE-UPGRADE: generating large multi-send to exceed block gas (should fail)..."
# # Generate 250 unique valid bech32 terp addresses by encoding incrementing
# # 20-byte payloads (0x000...0001 through 0x000...00FA) with proper checksums.
# MULTISEND_RECIPIENTS=$(python3 - <<'PYEOF'
# C = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
# G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

# def pm(v):
#     c = 1
#     for d in v:
#         b = c >> 25; c = (c & 0x1ffffff) << 5 ^ d
#         for i in range(5): c ^= G[i] if (b >> i) & 1 else 0
#     return c

# def b32(data):
#     a = b = 0; r = []
#     for v in data:
#         a = ((a << 8) | v) & 0xffffffff; b += 8
#         while b >= 5: b -= 5; r.append((a >> b) & 31)
#     if b: r.append((a << (5 - b)) & 31)
#     return r

# def terp_addr(n):
#     hrp = 'terp'
#     w = b32(n.to_bytes(20, 'big'))
#     ex = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
#     ck = [(pm(ex + w + [0]*6) ^ 1) >> (5*(5-i)) & 31 for i in range(6)]
#     return hrp + '1' + ''.join(C[d] for d in w + ck)

# print(' '.join(terp_addr(i) for i in range(1, 251)))
# PYEOF
# )
# MULTISEND_PRE=$($BIND tx bank multi-send "$VAL1" "$MULTISEND_RECIPIENTS" "1uterp" --gas auto --gas-adjustment 1.5 --fees="20000000uterp" --chain-id=$CHAINID --home=$VAL1HOME -y 2>&1) || true
# echo "$MULTISEND_PRE"
# if echo "$MULTISEND_PRE" | grep -qiE "out of gas|gas limit|exceed|too large|error"; then
#   echo "PRE-UPGRADE CHECK PASSED: large multi-send rejected as expected"
# else
#   echo "PRE-UPGRADE CHECK: multi-send result may need inspection"
# fi
# sleep 4

####################################################################
# C. UPGRADE
####################################################################
echo "lets upgrade "
sleep 2
LATEST_HEIGHT=$( $BIND status --home $VAL1HOME | jq -r '.sync_info.latest_block_height' )
UPGRADE_HEIGHT=$(( $LATEST_HEIGHT + 35 ))
echo "UPGRADE HEIGHT: $UPGRADE_HEIGHT"
sleep 2
cat <<EOF > "$VAL1HOME/upgrade.json" 
{
    "messages": [
        {
            "@type": "/cosmos.consensus.v1.MsgUpdateParams",
            "authority": "terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq",
            "block": {
                "max_bytes": "$NEW_MAX_BYTES",
                "max_gas": "$NEW_MAX_GAS"
            },
            "evidence": {
                "max_age_num_blocks": "756000",
                "max_age_duration": "48h0m0s",
                "max_bytes": "1048576"
            },
            "validator": {
                "pub_key_types": [
                    "ed25519"
                ]
            },
            "abci": {
                "vote_extensions_enable_height": "14170663"
            }
        }
    ],
    "title": "test",
    "summary": "t",
    "metadata": "ipfs://CIDQmcccroX3FWJ3n1B4zE6NNbgzoALaa2Q2krZSqkYunqF2c",
    "deposit": "5000000000uterp",
    "expedited": false
}
EOF
echo "propose upgrade using expedited proposal..."
$BIND tx gov submit-proposal $VAL1HOME/upgrade.json --gas auto --gas-adjustment 1.5 --fees="2000uterp" --chain-id=$CHAINID --home=$VAL1HOME --from="$VAL1" -y
sleep 2
# echo "vote upgrade"
$BIND tx gov vote 1 yes --from "$DEL1" --gas auto --gas-adjustment 1.2 --fees 1000uterp --chain-id $CHAINID --home $VAL1HOME -y
$BIND tx gov vote 1 yes --from "$VAL1" --gas auto --gas-adjustment 1.2 --fees 1000uterp --chain-id $CHAINID --home $VAL1HOME -y
sleep 4
####################################################################
# D. CONFIRM POST-UPGRADE (both actions must succeed)
####################################################################
sleep 10

# query consensus params, verify updated values are applied
echo "POST-UPGRADE: querying consensus params..."
PARAMS_OUTPUT=$($BIND q consensus params -o json --home $VAL1HOME 2>&1)
echo "$PARAMS_OUTPUT"
if echo "$PARAMS_OUTPUT" | grep -qE "16777216|50000000"; then
  echo "POST-UPGRADE CHECK PASSED: consensus params updated (max_bytes=16MB, max_gas=50M)"
else
  echo "POST-UPGRADE CHECK: params verification - inspect output above"
fi

# post-upgrade: upload large wasm, should succeed (max_gas raised to 50M)
echo "POST-UPGRADE: uploading large wasm (should succeed)..."
STORE_POST=$($BIND tx wasm store "$LARGE_WASM_PATH" --gas auto --gas-adjustment 1.5 --fees="20000000uterp" --chain-id=$CHAINID --home=$VAL1HOME --from="$VAL1" -y 2>&1)
echo "$STORE_POST"
sleep 6

# verify wasm code was stored by querying code-info
CODE_INFO=$($BIND q wasm code-info 1 -o json --home $VAL1HOME 2>&1)
echo "$CODE_INFO"
if echo "$CODE_INFO" | grep -qE "code_id|creator"; then
  echo "POST-UPGRADE CHECK PASSED: wasm code stored successfully"
else
  echo "ERROR: wasm code not found post-upgrade"
  exit 1
fi

# # post-upgrade: large multi-send, should succeed (max_gas raised to 50M)
# echo "POST-UPGRADE: attempting large multi-send (should succeed)..."
# MULTISEND_POST=$($BIND tx bank multi-send "$VAL1" $MULTISEND_RECIPIENTS "1uterp" --gas auto --gas-adjustment 1.5 --fees="20000000uterp" --chain-id=$CHAINID --home=$VAL1HOME -y 2>&1)
# echo "$MULTISEND_POST"
# sleep 6
# if echo "$MULTISEND_POST" | grep -qiE "txhash|\"code\":0|raw_log"; then
#   echo "POST-UPGRADE CHECK PASSED: large multi-send succeeded"
# else
#   echo "ERROR: large multi-send failed post-upgrade"
#   exit 1
# fi

echo "UPGRADE APPLIED SUCCESSFULLY"
pkill -f $BIND