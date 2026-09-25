#!/usr/bin/env bash
# Same-hasher 07-tendermint pairs (no 08-wasm): blake3↔blake3 and sha256↔sha256.
# Stock TM uses SHA-256 IavlSpec; blake3↔blake3 ConnOpenTry is expected to fail
# unless ibc-go is HashOp-aware. SHA-256↔SHA-256 is the native TM control.
#
#   TERP_IMAGE_VERSION=v6.3.0-dev ./scripts/bench/hasher_native_pair.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export HASHER_PAIR="${HASHER_PAIR:-both}"
export HASHER_SMOKE=1
export HASHER_APPS=0
export HASHER_BENCH_N="${HASHER_BENCH_N:-1}"
export HASHER_BENCH_WARMUP=0
export TERP_IMAGE_VERSION="${TERP_IMAGE_VERSION:?set TERP_IMAGE_VERSION}"
export HERMES_IMAGE_REPO="${HERMES_IMAGE_REPO:-terpnetwork/hermes}"
export HERMES_IMAGE_VERSION="${HERMES_IMAGE_VERSION:-08-wasm}"
export RUST_LOG="${RUST_LOG:-info}"
export CARGO_TERM_COLOR=always

HASHER_PREFLIGHT_UNIT=1 "$ROOT/scripts/bench/hasher_preflight.sh"
for img in blake3 sha256; do
  docker image inspect "${IMAGE_REPO:-registry.terp.network/terp-core}:${TERP_IMAGE_VERSION}-${img}" >/dev/null
done

echo "==> native TM pairs hasher=${HASHER_PAIR}"
cd "$ROOT/crates/ict-rs"
exec cargo run -p ict-rs --example hasher_ibc_bench --features docker,testing,terp
