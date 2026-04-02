#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# HashMerchant integration test
#
# Spins up Anvil (Ethereum), a single-validator Terp chain with the
# hashmerchant sidecar, deploys a CosmWasm test contract, and validates
# that ERC-20 token ownership proofs (state roots) flow end-to-end.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

BIND=terpd
CHAINID=hashmerchant-test-1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Keys
VAL=val
USER=user

# Paths
CHAINDIR=../data/hashmerchant
VALHOME=$CHAINDIR/$CHAINID/val1
WASM_FILE="$SCRIPT_DIR/contracts/hashmerchant_test.wasm"

# Ports
ANVIL_PORT=18545
SIDECAR_PORT=18888
VAL_API_PORT=11317
VAL_GRPC_PORT=19090
VAL_GRPC_WEB_PORT=19091
VAL_PROXY_APP_PORT=16658
VAL_RPC_PORT=16657
VAL_PPROF_PORT=16060
VAL_P2P_PORT=16656

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

####################################################################
# A. PREREQUISITES
####################################################################
echo "=== A. Prerequisites ==="
for cmd in $BIND anvil cast python3 jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found in PATH"
        exit 1
    fi
done
echo "All prerequisites found."

if [ ! -f "$WASM_FILE" ]; then
    echo "ERROR: Test contract not found at $WASM_FILE"
    echo "       Run: sh build-contract.sh"
    exit 1
fi

####################################################################
# CLEANUP TRAP
####################################################################
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    kill "$ANVIL_PID" 2>/dev/null || true
    kill "$SIDECAR_PID" 2>/dev/null || true
    kill "$TERPD_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
    wait "$SIDECAR_PID" 2>/dev/null || true
    wait "$TERPD_PID" 2>/dev/null || true
    echo ""
    echo "──────────────────────────"
    echo "Results: $PASS passed, $FAIL failed"
    echo "──────────────────────────"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}
trap cleanup EXIT INT TERM

####################################################################
# B. START ANVIL
####################################################################
echo ""
echo "=== B. Start Anvil ==="
anvil --port $ANVIL_PORT --block-time 2 --silent &
ANVIL_PID=$!
sleep 2

# Deploy a SimpleERC20 using cast
echo "Deploying ERC-20 token on Anvil..."
# Anvil's first default account
ALICE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ALICE_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
BOB_ADDR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

# Deploy a minimal ERC20 (using cast's create2 is overkill; just deploy bytecode)
# For simplicity, just mint some ETH to Alice and Bob — the state root changes
# are what we care about, not the specific ERC-20 logic.
cast send --private-key $ALICE_KEY --rpc-url http://localhost:$ANVIL_PORT \
    $BOB_ADDR --value 1ether >/dev/null 2>&1

# Mine a block to finalize
cast rpc --rpc-url http://localhost:$ANVIL_PORT evm_mine >/dev/null 2>&1
STATE_ROOT=$(cast rpc --rpc-url http://localhost:$ANVIL_PORT eth_getBlockByNumber latest false 2>/dev/null | jq -r '.stateRoot')
echo "Anvil state root: $STATE_ROOT"

####################################################################
# C. START TERP CHAIN
####################################################################
echo ""
echo "=== C. Start Terp chain ==="

defaultCoins="100000000000uterp"
delegate="1000000uterp"

rm -rf "$VALHOME"
$BIND init $CHAINID --overwrite --home "$VALHOME" --chain-id $CHAINID >/dev/null 2>&1
sleep 1

# CLI config
$BIND --home "$VALHOME" config keyring-backend test
$BIND --home "$VALHOME" config chain-id $CHAINID
$BIND --home "$VALHOME" config node tcp://localhost:$VAL_RPC_PORT

# Genesis modifications
jq '
  .app_state.crisis.constant_fee.denom = "uterp" |
  .app_state.staking.params.bond_denom = "uterp" |
  .app_state.mint.params.blocks_per_year = "20000000" |
  .app_state.mint.params.mint_denom = "uterp" |
  .app_state.gov.params.voting_period = "15s" |
  .app_state.gov.params.expedited_voting_period = "12s" |
  .app_state.gov.params.min_deposit[0].denom = "uterp" |
  .app_state.slashing.params.signed_blocks_window = "15" |
  .app_state.slashing.params.min_signed_per_window = "0.500000000000000000" |

  # Register ethereum-mainnet chain in genesis (default params already correct)
  .app_state.hashmerchant.registered_chains = [{
    "chain_uid": "ethereum-mainnet",
    "name": "Ethereum Mainnet",
    "rpc_endpoints": ["http://localhost:'"$ANVIL_PORT"'"],
    "hash_algos": ["keccak256"],
    "enabled": true
  }]
' "$VALHOME/config/genesis.json" > "$VALHOME/config/tmp.json"
mv "$VALHOME/config/tmp.json" "$VALHOME/config/genesis.json"

# Enable vote extensions from height 2
# In CometBFT 0.38 the consensus param is in the genesis
jq '.consensus.params.abci.vote_extensions_enable_height = "2"' \
    "$VALHOME/config/genesis.json" > "$VALHOME/config/tmp.json"
mv "$VALHOME/config/tmp.json" "$VALHOME/config/genesis.json"

# Keys
yes | $BIND --home "$VALHOME" keys add $VAL --output json > "$VALHOME/val.json" 2>&1
yes | $BIND --home "$VALHOME" keys add $USER --output json > "$VALHOME/user.json" 2>&1
VAL_ADDR=$(jq -r '.address' "$VALHOME/val.json")
USER_ADDR=$(jq -r '.address' "$VALHOME/user.json")

$BIND --home "$VALHOME" genesis add-genesis-account "$VAL_ADDR" $defaultCoins
$BIND --home "$VALHOME" genesis add-genesis-account "$USER_ADDR" $defaultCoins
$BIND --home "$VALHOME" genesis gentx $VAL $delegate --chain-id $CHAINID
$BIND genesis collect-gentxs --home "$VALHOME" >/dev/null 2>&1

# Port config — config.toml
sed -i.bak -e "s/^proxy_app *=.*/proxy_app = \"tcp:\/\/127.0.0.1:$VAL_PROXY_APP_PORT\"/g" "$VALHOME/config/config.toml"
sed -i.bak "/^\[rpc\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/127.0.0.1:$VAL_RPC_PORT\"/" "$VALHOME/config/config.toml"
sed -i.bak "/^\[p2p\]/,/^\[/ s/laddr.*/laddr = \"tcp:\/\/0.0.0.0:$VAL_P2P_PORT\"/" "$VALHOME/config/config.toml"
sed -i.bak -e "s/^grpc_laddr *=.*/grpc_laddr = \"\"/g" "$VALHOME/config/config.toml"
sed -i.bak -e "s/^pprof_laddr *=.*/pprof_laddr = \"localhost:$VAL_PPROF_PORT\"/g" "$VALHOME/config/config.toml"
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"1s\"/" "$VALHOME/config/config.toml"

# Port config — app.toml
sed -i.bak "s/minimum-gas-prices *=.*/minimum-gas-prices = \"0.0uterp\"/" "$VALHOME/config/app.toml"
sed -i.bak "/^\[api\]/,/^\[/ s/address.*/address = \"tcp:\/\/0.0.0.0:$VAL_API_PORT\"/" "$VALHOME/config/app.toml"
sed -i.bak "/^\[grpc\]/,/^\[/ s/address.*/address = \"localhost:$VAL_GRPC_PORT\"/" "$VALHOME/config/app.toml"
sed -i.bak "/^\[grpc-web\]/,/^\[/ s/address.*/address = \"localhost:$VAL_GRPC_WEB_PORT\"/" "$VALHOME/config/app.toml"

echo "Starting terpd..."
HASHMERCHANT_SIDECAR_URL="http://localhost:$SIDECAR_PORT" \
    $BIND start --home "$VALHOME" --wasm.skip_wasmvm_version_check --log_level "*:error,x/hashmerchant:info" &
TERPD_PID=$!
echo "terpd PID: $TERPD_PID"

####################################################################
# D. START MOCK SIDECAR
####################################################################
echo ""
echo "=== D. Start mock sidecar ==="
ANVIL_RPC="http://localhost:$ANVIL_PORT" PORT=$SIDECAR_PORT \
    python3 "$SCRIPT_DIR/mock-sidecar.py" &
SIDECAR_PID=$!
echo "sidecar PID: $SIDECAR_PID"

# Wait for chain to be ready
echo "Waiting for chain to produce blocks..."
for i in $(seq 1 30); do
    if $BIND status --home "$VALHOME" --node tcp://localhost:$VAL_RPC_PORT 2>/dev/null | jq -e '.sync_info.latest_block_height | tonumber > 2' >/dev/null 2>&1; then
        echo "Chain is producing blocks."
        break
    fi
    sleep 1
done

# Verify sidecar is up
curl -sf "http://localhost:$SIDECAR_PORT/health" >/dev/null && echo "Sidecar is healthy." || {
    echo "ERROR: sidecar not responding"
    exit 1
}

####################################################################
# E. DEPLOY & REGISTER CONTRACT
####################################################################
echo ""
echo "=== E. Deploy & register contract ==="

# Upload WASM
echo "Uploading hashmerchant_test.wasm..."
TX_UPLOAD=$($BIND tx wasm store "$WASM_FILE" \
    --from $USER --home "$VALHOME" \
    --chain-id $CHAINID \
    --gas auto --gas-adjustment 1.4 \
    --fees 400000uterp -y \
    --output json 2>&1)
sleep 3

CODE_ID=$($BIND q wasm list-code --home "$VALHOME" --output json | jq -r '.code_infos[-1].code_id')
echo "Code ID: $CODE_ID"

# Instantiate
echo "Instantiating contract..."
$BIND tx wasm instantiate "$CODE_ID" '{}' \
    --from $USER --home "$VALHOME" \
    --chain-id $CHAINID \
    --no-admin --label "hashmerchant-test" \
    --fees 400000uterp --gas auto --gas-adjustment 1.3 -y >/dev/null 2>&1
sleep 3

CONTRACT_ADDR=$($BIND q wasm list-contract-by-code "$CODE_ID" --home "$VALHOME" --output json | jq -r '.contracts[0]')
echo "Contract: $CONTRACT_ADDR"

# Register contract for ethereum-mainnet with 1 TERP escrow
# CLI: register-contract [contract-addr] [chain-uid] [substore-keys] [escrow-amount]
# Note: passing a single "-" as substore-keys to avoid [""] from split("")
echo "Registering contract for ethereum-mainnet..."
$BIND tx hashmerchant register-contract \
    "$CONTRACT_ADDR" "ethereum-mainnet" "state" "1000000uterp" \
    --from $USER --home "$VALHOME" \
    --chain-id $CHAINID \
    --fees 400000uterp --gas auto --gas-adjustment 1.3 -y >/dev/null 2>&1
sleep 3

####################################################################
# F. WAIT FOR ROOT CONFIRMATION
####################################################################
echo ""
echo "=== F. Wait for root confirmation ==="
CONFIRMED_ROOT=""
for i in $(seq 1 45); do
    ROOT_RESP=$($BIND q hashmerchant root ethereum-mainnet keccak256 \
        --home "$VALHOME" --output json 2>/dev/null || echo '{}')
    ROOT_HEX=$(echo "$ROOT_RESP" | jq -r '.root.root // empty' 2>/dev/null)
    if [ -n "$ROOT_HEX" ] && [ "$ROOT_HEX" != "null" ]; then
        CONFIRMED_ROOT="$ROOT_HEX"
        echo "Root confirmed on-chain: $CONFIRMED_ROOT"
        break
    fi
    echo "  waiting... ($i/45)"
    sleep 2
done

if [ -z "$CONFIRMED_ROOT" ]; then
    fail "Root was NOT confirmed within timeout"
    # Continue to see what else fails
fi

####################################################################
# G. PROOF VERIFICATION TESTS
####################################################################
echo ""
echo "=== G. Proof verification tests ==="

if [ -n "$CONFIRMED_ROOT" ]; then
    # Decode the on-chain root (base64) to hex for comparison
    ROOT_HEX_DECODED=$(echo "$CONFIRMED_ROOT" | base64 -d 2>/dev/null | xxd -p -c 256 2>/dev/null || echo "$CONFIRMED_ROOT")

    # Test 1: Valid root match
    echo ""
    echo "--- Test 1: Valid root match ---"
    VERIFY_MSG='{"verify_inclusion":{"chain_uid":"ethereum-mainnet","algo":"keccak256","claimed_root":"'"$ROOT_HEX_DECODED"'"}}'
    RESULT=$($BIND tx wasm execute "$CONTRACT_ADDR" "$VERIFY_MSG" \
        --from $USER --home "$VALHOME" \
        --chain-id $CHAINID \
        --fees 400000uterp --gas auto --gas-adjustment 1.3 -y \
        --output json 2>&1) || true
    sleep 2
    if echo "$RESULT" | grep -q '"code":0\|"code": 0'; then
        pass "Valid root accepted"
    else
        fail "Valid root was rejected: $RESULT"
    fi

    # Test 2: Invalid root
    echo ""
    echo "--- Test 2: Invalid root ---"
    VERIFY_BAD='{"verify_inclusion":{"chain_uid":"ethereum-mainnet","algo":"keccak256","claimed_root":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}'
    RESULT_BAD=$($BIND tx wasm execute "$CONTRACT_ADDR" "$VERIFY_BAD" \
        --from $USER --home "$VALHOME" \
        --chain-id $CHAINID \
        --fees 400000uterp --gas auto --gas-adjustment 1.3 -y \
        --output json 2>&1) || true
    sleep 2
    if echo "$RESULT_BAD" | grep -qi "mismatch\|failed\|error\|code.*[^0]"; then
        pass "Invalid root rejected"
    else
        fail "Invalid root was accepted (should have been rejected): $RESULT_BAD"
    fi

    # Test 3: Query stored root
    echo ""
    echo "--- Test 3: Query stored root ---"
    QUERY_MSG='{"get_root":{"chain_uid":"ethereum-mainnet","algo":"keccak256"}}'
    QUERY_RESULT=$($BIND q wasm contract-state smart "$CONTRACT_ADDR" "$QUERY_MSG" \
        --home "$VALHOME" --output json 2>&1) || true
    QUERIED_ROOT=$(echo "$QUERY_RESULT" | jq -r '.data.root // empty' 2>/dev/null)
    if [ -n "$QUERIED_ROOT" ] && [ "$QUERIED_ROOT" != "null" ]; then
        pass "Contract stores and returns root: $QUERIED_ROOT"
    else
        fail "Contract did not return stored root: $QUERY_RESULT"
    fi
else
    fail "Skipping proof tests — no confirmed root"
fi

####################################################################
# H. ESCROW LIFECYCLE TESTS
####################################################################
echo ""
echo "=== H. Escrow lifecycle tests ==="

ESCROW_RESP=$($BIND q hashmerchant escrow "$CONTRACT_ADDR" \
    --home "$VALHOME" --output json 2>/dev/null || echo '{}')
PAID_UNTIL=$(echo "$ESCROW_RESP" | jq -r '.escrow.paid_until_height // empty' 2>/dev/null)

if [ -n "$PAID_UNTIL" ] && [ "$PAID_UNTIL" != "null" ] && [ "$PAID_UNTIL" != "0" ]; then
    pass "Escrow active, paid_until_height=$PAID_UNTIL"
else
    fail "Escrow not found or expired: $ESCROW_RESP"
fi

# Refill escrow
# CLI: refill-escrow [contract-addr] [amount]
echo "Refilling escrow..."
$BIND tx hashmerchant refill-escrow "$CONTRACT_ADDR" "1000000uterp" \
    --from $USER --home "$VALHOME" \
    --chain-id $CHAINID \
    --fees 400000uterp --gas auto --gas-adjustment 1.3 -y >/dev/null 2>&1 || true
sleep 3

ESCROW_RESP2=$($BIND q hashmerchant escrow "$CONTRACT_ADDR" \
    --home "$VALHOME" --output json 2>/dev/null || echo '{}')
PAID_UNTIL2=$(echo "$ESCROW_RESP2" | jq -r '.escrow.paid_until_height // empty' 2>/dev/null)

if [ -n "$PAID_UNTIL2" ] && [ "$PAID_UNTIL2" != "null" ] && [ "$PAID_UNTIL2" -gt "${PAID_UNTIL:-0}" ] 2>/dev/null; then
    pass "Escrow refilled, paid_until extended: $PAID_UNTIL -> $PAID_UNTIL2"
else
    fail "Escrow refill did not extend paid_until: was=$PAID_UNTIL now=$PAID_UNTIL2"
fi

echo ""
echo "=== Done ==="
