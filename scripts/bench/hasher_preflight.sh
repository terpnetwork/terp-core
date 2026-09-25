#!/usr/bin/env bash
# Instant hasher IBC gate. No Docker chains. Fail here instead of after 5 minutes.
#
#   ./scripts/bench/hasher_preflight.sh
#   TERP_IMAGE_VERSION=v6.3.0-dev ./scripts/bench/hasher_preflight.sh   # also inspect images
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/crates/ict-rs"

echo "==> unit tests (no Docker)"
cargo test -p ict-rs --features testing --lib -- \
  hermes_json_status_error \
  hermes_json_later_error \
  hermes_json_success \
  hermes_nonzero_exit \
  collect_recv \
  collect_prefers_tx_responses \
  collect_gas_info \
  packet_receipt_json \
  markdown_table_lists_recv \
  collect_create_client_and_conn_open \
  hooks_counter_missing \
  hooks_counter_first_increment \
  hooks_counter_second_increment

cargo test -p ict-rs --features testing --test relayer_tests -- \
  test_newest_local_channel_id_ignores_counterparty \
  test_client_options_wasm_checksum_is_directional \
  test_client_options_wasm_checksum_none_host_means_both \
  test_hermes_create_wasm_client_cmd

if [ "${HASHER_PREFLIGHT_UNIT:-}" = "1" ]; then
  echo "==> preflight ok (unit only)"
  exit 0
fi

WASM="${IBC_WASM_LC:-$ROOT/crates/terp-rs/artifacts/cw_ics08_wasm_terp.wasm}"
if [ ! -f "$WASM" ]; then
  echo "ERROR: missing 08-wasm artifact: $WASM" >&2
  echo "Build once: ./scripts/build-ics08-wasm-terp.sh" >&2
  exit 1
fi
echo "==> wasm ok $WASM ($(wc -c < "$WASM") bytes)"

HERMES_IMAGE="${HERMES_IMAGE_REPO:-terpnetwork/hermes}:${HERMES_IMAGE_VERSION:-08-wasm}"
if ! docker image inspect "$HERMES_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: missing $HERMES_IMAGE" >&2
  echo "Build once (not in the smoke loop): ./scripts/ibc-ops/build_hermes.sh" >&2
  exit 1
fi
echo "==> hermes image ok $HERMES_IMAGE"

if [ -n "${TERP_IMAGE_VERSION:-}" ]; then
  REPO="${IMAGE_REPO:-registry.terp.network/terp-core}"
  for mode in blake3 sha256; do
    img="${REPO}:${TERP_IMAGE_VERSION}-${mode}"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "ERROR: missing $img" >&2
      echo "Build on groot2: TERP_IMAGE_VERSION=$TERP_IMAGE_VERSION make docker-build-zk" >&2
      exit 1
    fi
    echo "==> terp image ok $img"
  done
  if [ "${HASHER_SMOKE:-}" != "1" ]; then
    img="${REPO}:${TERP_IMAGE_VERSION}-hybrid"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "ERROR: missing $img (needed for three-chain bench)" >&2
      exit 1
    fi
    echo "==> terp image ok $img"
  fi
fi

echo "==> preflight ok"
