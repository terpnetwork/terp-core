#!/bin/bash
set -o errexit -o nounset -o pipefail

BASE_ACCOUNT=$(terpd keys show validator -a)
terpd q account "$BASE_ACCOUNT" -o json | jq

echo "## Add new account"
terpd keys add fred

echo "## Check balance"
NEW_ACCOUNT=$(terpd keys show fred -a)
terpd q bank balances "$NEW_ACCOUNT" -o json || true

echo "## Transfer tokens"
terpd tx bank send validator "$NEW_ACCOUNT" 1ustake --gas 1000000 -y --chain-id=testing --node=http://localhost:26657 -b block -o json | jq

echo "## Check balance again"
terpd q bank balances "$NEW_ACCOUNT" -o json | jq
