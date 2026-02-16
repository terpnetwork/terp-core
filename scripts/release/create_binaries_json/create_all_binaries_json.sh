#!/bin/bash

tags=(
    "v4.2.0" 
)

echo "## Upgrade binaries"

for tag in "${tags[@]}"; do
    echo
    echo "### ${tag}"
    echo
    echo '```json'
    python create_binaries_json.py --tag $tag
    echo '```'
done