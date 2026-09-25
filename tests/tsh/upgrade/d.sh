#!/usr/bin/env bash
# CosmWasm guest survival across v6.3 → v6.4 (hasher two-step).
# v6.0 bulk_memory guest survival lives in archive/v6.0/d.sh.
set -euo pipefail
export HASH_WASM="${HASH_WASM:-1}"
exec "$(cd "$(dirname "$0")" && pwd)/v63.sh" "$@"
