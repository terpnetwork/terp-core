#!/bin/sh
# Lab observer: when a watch has no observation, post a synthetic funding.
# Production oline: replace with corridor-btc-reporter + Fulcrum.
#
# Honest scope: lab only — synthetic txids, not mainnet Bitcoin observation.
set -eu
BASE="${HASH_MARKET_URL:-http://hash-market:9090}"
POLL="${POLL_SECS:-5}"
echo "[lab-observer] $BASE poll=${POLL}s"
while true; do
  body=$(curl -sf "$BASE/corridor/watches" 2>/dev/null || echo '{"watches":[]}')
  # Prefer first watch that is still "watching" (status endpoint), not only first list entry.
  # Crude extract without jq (alpine/curl image).
  intent=$(echo "$body" | sed -n 's/.*"intent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  addr=$(echo "$body" | sed -n 's/.*"btc_deposit_addr"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  bind=$(echo "$body" | sed -n 's/.*"domain_bind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "${intent:-}" ] && [ -n "${addr:-}" ]; then
    st=$(curl -sf "$BASE/corridor/watches/$intent" 2>/dev/null || echo '{}')
    case "$st" in
      *\"status\":\"deposit_observed\"*|*deposit_observed*)
        # already funded
        ;;
      *)
        # Unique lab txid (hex-ish) per post attempt
        ts=$(date +%s 2>/dev/null || echo 0)
        txid="labdeadbeef${ts}"
        echo "[lab-observer] posting observation for $intent addr=$addr"
        curl -sf -X POST "$BASE/corridor/observations" \
          -H 'Content-Type: application/json' \
          -d "{\"intent_id\":\"$intent\",\"btc_deposit_addr\":\"$addr\",\"txid\":\"$txid\",\"amount_sats\":100000,\"confirmations\":1,\"observed_at\":0,\"reporter\":\"lab-observer\",\"domain_bind\":\"${bind:-}\"}" \
          || true
        echo
        ;;
    esac
  fi
  sleep "$POLL"
done
