#!/bin/sh
# copy current terp directory to new location
# Usage: ./script.sh <source_terp_path> <new_terpd_path>

if [ $# -ne 2 ]; then
    echo "Usage: $0 <source_terp_path> <new_terpd_path>"
    echo "Example: $0 \"\$HOME/.terp\" \"\$HOME/.terpd\""
    exit 1
fi

SOURCE_DIR="$1"
DEST_DIR="$2"

# Copy
cp -r "$SOURCE_DIR" "$DEST_DIR"

# Validate
terpd genesis validate-genesis --home "$DEST_DIR"

# Remove original
rm -rf "$SOURCE_DIR"