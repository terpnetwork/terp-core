#!/usr/bin/env bash
# Build linux/amd64 (and optionally arm64) Terp images on groot2 and run the
# three-chain hasher IBC bench there. Library work stays on the laptop.
#
#   TERP_IMAGE_VERSION=v6.3.0-dev ./scripts/bench/hasher_ibc_groot2.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GROOT2_HOST="${GROOT2_HOST:-groot2}"
GROOT2_REPO="${GROOT2_REPO:-$ROOT}"
TAG="${TERP_IMAGE_VERSION:?set TERP_IMAGE_VERSION (not local/local-zk)}"
PLATFORMS="${HASHER_BENCH_PLATFORMS:-linux/amd64}"

if [ "${HASHER_FULL:-}" != "1" ]; then
  echo "Refusing the three-chain bench (5+ min, hides A→C as a late NOTE)." >&2
  echo "1. Instant: ./scripts/bench/hasher_preflight.sh" >&2
  echo "2. A+C smoke: TERP_IMAGE_VERSION=$TAG ./scripts/bench/hasher_wasm_smoke.sh" >&2
  echo "3. Only then: HASHER_FULL=1 TERP_IMAGE_VERSION=$TAG $0" >&2
  exit 2
fi

if [ "$(uname -s)" = Darwin ] || [ "$(uname -m)" = arm64 ]; then
  echo "NOTE: this host is for library work. Docker bench belongs on $GROOT2_HOST (amd64)."
fi

ssh -o BatchMode=yes -o ConnectTimeout=12 "$GROOT2_HOST" "test -d '$GROOT2_REPO'" \
  || { echo "ERROR: $GROOT2_HOST:$GROOT2_REPO missing. Sync feat/6.3.0-dev there first." >&2; exit 1; }

echo "==> $GROOT2_HOST docker buildx $PLATFORMS tag=$TAG"
ssh "$GROOT2_HOST" "set -euo pipefail
  cd '$GROOT2_REPO'
  git rev-parse --abbrev-ref HEAD
  TERP_IMAGE_VERSION='$TAG' IMAGE_REPO=registry.terp.network/terp-core \
    make docker-build-zk
  ./scripts/ibc-ops/build_hermes.sh
"

echo "==> hasher_ibc_bench on $GROOT2_HOST (A blake3, B hybrid, C sha256)"
ssh "$GROOT2_HOST" "set -euo pipefail
  cd '$GROOT2_REPO/crates/ict-rs'
  TERP_IMAGE_VERSION='$TAG' HASHER_BENCH_N=\"\${HASHER_BENCH_N:-20}\" \
    HERMES_IMAGE_REPO=terpnetwork/hermes HERMES_IMAGE_VERSION=08-wasm \
    cargo run -p ict-rs --example hasher_ibc_bench --features docker,testing,terp
"

echo "JSON on $GROOT2_HOST: $GROOT2_REPO/tests/benchmarks/hasher-ibc/"
echo "copy back: scp $GROOT2_HOST:$GROOT2_REPO/tests/benchmarks/hasher-ibc/hasher-ibc-*-latest.json tests/benchmarks/hasher-ibc/"
