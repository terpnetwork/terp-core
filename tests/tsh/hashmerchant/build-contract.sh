#!/bin/bash
# Build the hashmerchant test contract and copy the optimized WASM to the test dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTRACT_DIR="$SCRIPT_DIR/contracts/hashmerchant-test"

echo "Building hashmerchant-test contract..."
cd "$CONTRACT_DIR"

# Use the CosmWasm rust optimizer if available, otherwise plain cargo build.
if command -v docker &>/dev/null; then
    docker run --rm -v "$CONTRACT_DIR":/code \
        --mount type=volume,source=hashmerchant_test_cache,target=/target \
        --mount type=volume,source=registry_cache,target=/usr/local/cargo/registry \
        cosmwasm/optimizer:0.16.1
    cp "$CONTRACT_DIR/artifacts/hashmerchant_test.wasm" "$SCRIPT_DIR/contracts/"
    echo "Optimized WASM copied to contracts/hashmerchant_test.wasm"
else
    echo "Docker not found; falling back to cargo build..."
    RUSTFLAGS='-C link-arg=-s' cargo build --release --target wasm32-unknown-unknown --lib
    cp "$CONTRACT_DIR/target/wasm32-unknown-unknown/release/hashmerchant_test.wasm" "$SCRIPT_DIR/contracts/"
    echo "WASM copied to contracts/hashmerchant_test.wasm (not optimized)"
fi
