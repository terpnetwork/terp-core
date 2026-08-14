#!/usr/bin/env bash
# Generate No-Rick CosmWasm-footer VK + host Halo2 proofs into testdata.
# Native rust only — no wasm-bindgen, no chain, no mnemonic.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MANIFEST="$ROOT/tests/tsh/zk/norick-testdata/Cargo.toml"
if [ "$#" -gt 0 ]; then
  cargo run --manifest-path "$MANIFEST" --bin gen_norick_testdata -- "$@"
else
  cargo run --manifest-path "$MANIFEST" --bin gen_norick_testdata
fi
