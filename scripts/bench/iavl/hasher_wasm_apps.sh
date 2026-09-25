#!/usr/bin/env bash
# A+C dual 08-wasm + ibc-hooks + polytone. Fail-closed. No B/PFM.
#
#   TERP_IMAGE_VERSION=v6.3.0-dev ./scripts/bench/hasher_wasm_apps.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export HASHER_SMOKE=1
export HASHER_APPS=1
export HASHER_BENCH_N="${HASHER_BENCH_N:-1}"
export HASHER_BENCH_WARMUP=0
export HASHER_SKIP_TM_AC=1
export TERP_IMAGE_VERSION="${TERP_IMAGE_VERSION:?set TERP_IMAGE_VERSION}"
export HERMES_IMAGE_REPO="${HERMES_IMAGE_REPO:-terpnetwork/hermes}"
export HERMES_IMAGE_VERSION="${HERMES_IMAGE_VERSION:-08-wasm}"
export RUST_LOG="${RUST_LOG:-info}"
export CARGO_TERM_COLOR=always

"$ROOT/scripts/bench/hasher_preflight.sh"

echo "==> A+C dual 08-wasm + hooks + polytone (fail-closed)"
cd "$ROOT/crates/ict-rs"
exec cargo run -p ict-rs --example hasher_ibc_bench --features docker,testing,terp
