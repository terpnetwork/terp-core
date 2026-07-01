#!/bin/bash

# Read the JSON file
json=$(cat data/exported-balances.json)

# Extract the total_balances and address for each terp1 data structure
terp1_data=$(echo "$json" | jq -r '.accounts | to_entries[] | .key as $address | .value | { address: $address, total_balances: .total_balances }')

# Print the extracted total_balances and address
echo "$terp1_data"