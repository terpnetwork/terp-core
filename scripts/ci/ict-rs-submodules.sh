#!/usr/bin/env bash
# Sparse submodule checkout for compiling ict-rs in CI (not the full crates/* tree).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mods=(
  crates/ict-rs
  crates/cosmos-rust
  crates/tendermint-rs
  crates/cw-orchestrator
  crates/terp-rs
  crates/ibc-proto-rs
)
git submodule update --init --depth 1 "${mods[@]}"
