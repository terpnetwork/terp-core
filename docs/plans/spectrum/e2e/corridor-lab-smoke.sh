#!/usr/bin/env bash
# Host smoke: watch → observe → status (hash-market corridor notify).
# Requires: hash-market lab server (Layer A host or docker compose corridor-lab).
#
# Defaults:
#   HASH_MARKET_URL=http://127.0.0.1:19090
#
# Honest scope: lab notify plane only — not mainnet BTC/ZEC.
set -euo pipefail

BASE="${HASH_MARKET_URL:-http://127.0.0.1:19090}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Capture body + status without SIGPIPE from `head` breaking set -e.
curl_json() {
  # usage: curl_json METHOD URL [JSON_BODY]
  # sets global CURL_BODY; returns 0 only for 200/201
  local method="$1" url="$2" body="${3:-}"
  local tmp code
  tmp="$(mktemp)"
  if [ -n "$body" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$url" \
      -H 'Content-Type: application/json' -d "$body" || echo "000")"
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$url" || echo "000")"
  fi
  CURL_BODY="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  if [ "$code" != "200" ] && [ "$code" != "201" ]; then
    echo "HTTP $code $method $url" >&2
    echo "$CURL_BODY" >&2
    return 1
  fi
  return 0
}

preview() {
  # Print up to N chars without SIGPIPE killing the script.
  local n="${1:-400}"
  printf '%s' "$CURL_BODY" | head -c "$n" || true
  echo
}

echo "== health $BASE =="
curl_json GET "$BASE/health" || fail "hash-market not up at $BASE (start lab server first)"
preview 240
echo

# macOS: avoid `date | tail -c` (includes trailing newline → invalid intent_id).
INTENT="labintent$(date +%s)"
ADDR="bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
BIND="$(printf 'a%.0s' {1..64})"
# G4: prefer golden primary dest seal; lab residual may set CORRIDOR_ALLOW_PLACEHOLDER_DEST=1.
GOLDEN_DEST="8b5cac11e39905d56126a0c538b84ff8daa379d8009d4e8b121112479607f09b"
if [ "${CORRIDOR_ALLOW_PLACEHOLDER_DEST:-0}" = "1" ]; then
  DEST="$(printf 'b%.0s' {1..64})"
  echo "WARN: lab smoke using placeholder dest (CORRIDOR_ALLOW_PLACEHOLDER_DEST=1)"
else
  DEST="${CORRIDOR_DEST_OWNER_BINDING:-$GOLDEN_DEST}"
fi
PROOF="$(printf 'c%.0s' {1..64})"

echo "== open watch intent=$INTENT =="
curl_json POST "$BASE/corridor/watches" "{
  \"intent_id\": \"$INTENT\",
  \"corridor_id\": \"cashapp-btc-zec-v0\",
  \"btc_deposit_addr\": \"$ADDR\",
  \"domain_bind\": \"$BIND\",
  \"dest_owner_binding\": \"$DEST\",
  \"client_proof_digest\": \"$PROOF\",
  \"client_pubkey_hex\": \"02ab\",
  \"ttl_secs\": 3600
}" || fail "open watch"
preview 400
echo

echo "== list watches =="
curl_json GET "$BASE/corridor/watches" || fail "list watches"
preview 400
echo

echo "== post observation =="
curl_json POST "$BASE/corridor/observations" "{
  \"intent_id\": \"$INTENT\",
  \"btc_deposit_addr\": \"$ADDR\",
  \"txid\": \"deadbeefcafebabe\",
  \"amount_sats\": 100000,
  \"confirmations\": 1,
  \"observed_at\": 0,
  \"reporter\": \"corridor-lab-smoke\",
  \"domain_bind\": \"$BIND\"
}" || fail "post observation"
preview 400
echo

echo "== status =="
curl_json GET "$BASE/corridor/watches/$INTENT" || fail "get status"
STATUS="$CURL_BODY"
echo "$STATUS"
echo
case "$STATUS" in
  *'"status":"deposit_observed"'*|*'"status": "deposit_observed"'*)
    ;;
  *)
    fail "expected status=deposit_observed in response"
    ;;
esac

# Optional SSE probe (timeout): first event should be deposit_observed after reconnect.
echo "== SSE reconnect (expect deposit_observed) =="
SSE_OUT="$(mktemp)"
# curl --max-time aborts; ignore its exit
curl -sS -N --max-time 2 "$BASE/corridor/watches/$INTENT/events" >"$SSE_OUT" 2>/dev/null || true
if grep -q 'deposit_observed' "$SSE_OUT" 2>/dev/null; then
  echo "SSE OK (deposit_observed event seen)"
else
  # Non-fatal if SSE client tooling is flaky; status poll already green.
  echo "SSE soft-skip (no event in 2s); poll status already deposit_observed"
fi
rm -f "$SSE_OUT"

echo
echo "OK corridor lab smoke (notify plane) BASE=$BASE intent=$INTENT"
echo "  script=$SCRIPT_DIR/corridor-lab-smoke.sh"
echo "  design freezes: D1–D7 (DESIGN-DECISIONS-CORRIDOR-2026-07-20.md)"
