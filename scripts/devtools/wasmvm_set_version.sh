#!/bin/bash
set -o errexit -o nounset -o pipefail
command -v shellcheck >/dev/null && shellcheck "$0"

gnused="$(command -v gsed || echo sed)"

function print_usage() {
  echo "Usage: $0 NEW_VERSION"
  echo ""
  echo "e.g. $0 4.0.0-zk"
  echo "Edits x/wasm/wasmvm/libwasmvm/Cargo.toml. Does not commit or push."
}

if [ "$#" -ne 1 ]; then
  print_usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VM="$ROOT/x/wasm/wasmvm"

NEW="$1"
echo "Setting libwasmvm version to $NEW ..."

CARGO_TOML="$VM/libwasmvm/Cargo.toml"
"$gnused" -i -e "s/^version[[:space:]]*=.*/version = \"$NEW\"/" "$CARGO_TOML"
echo "Updated $CARGO_TOML"
echo "Review the diff, then cargo check in x/wasm/wasmvm/libwasmvm. This script does not commit."
