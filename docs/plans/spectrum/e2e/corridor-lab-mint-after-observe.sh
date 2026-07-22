#!/usr/bin/env bash
# Post-deposit host automation (D3 + D7 ACCEPTED):
#   deposit_observed → BridgeMintNote (L0 pure / mock_verify) → note persist product path
#   → oracle-bound private swap (pure) → PUT /corridor/automation/:id for UI poll
#
# Honest: lab film — not mainnet Cash App / ZEC. Oracle never mints.
# SeamNoteOutV0 only. Domain B asset map ≠ Domain C intent bind.
#
# Env:
#   HASH_MARKET_URL     default http://127.0.0.1:19090
#   INTENT_ID           optional — wait for this watch's deposit_observed
#   HEADSTASH_CONTRACT  optional label in automation status
#   SKIP_WAIT=1         do not wait for deposit_observed
#   SKIP_SERVER=1       pure harness only (no HTTP automation PUT)
#   KEEP_SERVER=1       leave server running if we started it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BASE="${HASH_MARKET_URL:-http://127.0.0.1:19090}"
AUTOMATION_DIR="${CORRIDOR_AUTOMATION_DIR:-$SCRIPT_DIR/.automation}"
HEADSTASH="${HEADSTASH_CONTRACT:-cw-headstash-lab-mock}"
mkdir -p "$AUTOMATION_DIR"

fail() { echo "FAIL: $*" >&2; exit 1; }

put_auto() {
  local intent="$1" phase="$2" detail="$3"
  local payload
  payload="$(DETAIL="$detail" PHASE="$phase" INTENT="$intent" HS="$HEADSTASH" python3 - <<'PY'
import json, os
print(json.dumps({
  "phase": os.environ["PHASE"],
  "detail": os.environ.get("DETAIL") or None,
  "mock_verify": True,
  "oracle_bound_only": True,
  "headstash_contract": os.environ.get("HS") or None,
}))
PY
)"
  echo "$payload" >"$AUTOMATION_DIR/${intent}-${phase}.json"
  if [ "${SKIP_SERVER:-0}" = "1" ]; then
    return 0
  fi
  if ! curl -sf "$BASE/health" >/dev/null 2>&1; then
    return 0
  fi
  code="$(curl -sS -o /tmp/corr-auto-out.json -w '%{http_code}' -X PUT \
    "$BASE/corridor/automation/$intent" \
    -H 'Content-Type: application/json' \
    -d "$payload" || echo 000)"
  if [ "$code" != "200" ]; then
    echo "warn: automation PUT HTTP $code" >&2
    cat /tmp/corr-auto-out.json 2>/dev/null || true
    echo >&2
  fi
}

echo "== mint-after-observe (D3 private mint + oracle-bound swap; D7 mock_verify) =="
echo "  HASH_MARKET_URL=$BASE"
echo "  AUTOMATION_DIR=$AUTOMATION_DIR"

STARTED=0
SPID=""
if [ "${SKIP_SERVER:-0}" != "1" ] && ! curl -sf "$BASE/health" >/dev/null 2>&1; then
  HM_BIN="$REPO_ROOT/crates/terp-rs/target/release/hash-market-server"
  if [ ! -x "$HM_BIN" ]; then
    echo "== build hash-market-server =="
    (cd "$REPO_ROOT/crates/terp-rs/tools/hash-market" && \
      cargo build --release --bin hash-market-server --features server)
  fi
  LAB_RUN="$(mktemp -d -t corridor-mint-XXXXXX)"
  PORT="${BASE##*:}"
  PORT="${PORT%%/*}"
  cat >"$LAB_RUN/config.toml" <<EOF
bind = "127.0.0.1:${PORT}"
chain_id = "corridor-lab-mint"
data_dir = "$LAB_RUN/data"
ve_enabled = false
cors_allow_origin = "*"
EOF
  mkdir -p "$LAB_RUN/data"
  echo "== start hash-market-server $BASE =="
  "$HM_BIN" -c "$LAB_RUN/config.toml" >"$LAB_RUN/server.log" 2>&1 &
  SPID=$!
  STARTED=1
  for _ in $(seq 1 50); do
    curl -sf "$BASE/health" >/dev/null 2>&1 && break
    sleep 0.1
  done
  curl -sf "$BASE/health" >/dev/null || {
    cat "$LAB_RUN/server.log" >&2 || true
    fail "could not start hash-market"
  }
fi

cleanup() {
  if [ "${KEEP_SERVER:-0}" != "1" ] && [ "$STARTED" = "1" ] && [ -n "$SPID" ]; then
    kill "$SPID" 2>/dev/null || true
    wait "$SPID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

INTENT="${INTENT_ID:-}"

if [ -n "$INTENT" ] && [ "${SKIP_WAIT:-0}" != "1" ] && [ "${SKIP_SERVER:-0}" != "1" ]; then
  echo "== wait deposit_observed intent=$INTENT =="
  for i in $(seq 1 60); do
    st="$(curl -sf "$BASE/corridor/watches/$INTENT" 2>/dev/null || echo '{}')"
    case "$st" in
      *deposit_observed*) echo "observed"; break ;;
    esac
    sleep 0.5
    if [ "$i" -eq 60 ]; then
      fail "timeout waiting for deposit_observed on $INTENT"
    fi
  done
  put_auto "$INTENT" "deposit_observed" "watch deposit_observed"
else
  INTENT="${INTENT:-labmint$(date +%s)}"
  echo "== no INTENT wait (label $INTENT) =="
  put_auto "$INTENT" "deposit_observed" "host automation start"
fi

put_auto "$INTENT" "bridging" "BridgeMintNote: cw-headstash mock_verify (pure L0 + optional L1 Mock)"

echo "== pure cashapp_zec_corridor + harness W0–W7 Simulated =="
(
  cd "$REPO_ROOT/docs/plans/spectrum/fixtures/cashapp_zec_corridor" && cargo test --quiet
)
(
  cd "$REPO_ROOT/crates/headstash" && \
    cargo test -p zk-test-press --lib cashapp_zec_w0_w7_happy_simulated \
      --features 'interface,l0-seams' -- --nocapture
) || fail "cashapp_zec W0–W7 harness"

if curl -sf "$BASE/health" >/dev/null 2>&1; then
  echo "== oracle bounds probe (optional; 503 if bounds off) =="
  curl -sS "$BASE/oracle/bounds?market_id=BTC-ZEC" | head -c 200 || true
  echo
fi

put_auto "$INTENT" "swapping" "oracle-bound private swap (pure); oracle bound_only never mints"

RECEIPT="$AUTOMATION_DIR/receipt-$INTENT.json"
python3 - <<PY
import json, time, pathlib
p = pathlib.Path("$RECEIPT")
doc = {
  "version": 0,
  "intent_id": "$INTENT",
  "phase": "complete",
  "mock_verify": True,
  "oracle_bound_only": True,
  "headstash_contract": "$HEADSTASH",
  "note_format": "SeamNoteOutV0_382B",
  "domain_separation": {
    "asset_map": "terp-tacit-asset-v1 (Domain B)",
    "intent_bind": "terp-cashapp-intent-v0 (Domain C) — never merged"
  },
  "steps": [
    "deposit_observed",
    "BridgeMintNote mock_verify / L0 authorize",
    "put_note_after_mint product call site when notes_base set",
    "oracle-bound private swap",
    "receipt"
  ],
  "completed_at": int(time.time()),
  "honest_non_claims": [
    "no mainnet Cash App",
    "no mainnet ZEC send",
    "notify bus not mint authority",
    "Zakura local residual (D6)"
  ]
}
p.write_text(json.dumps(doc, indent=2))
print("wrote", p)
PY

# Final automation with receipt payload
if [ "${SKIP_SERVER:-0}" != "1" ] && curl -sf "$BASE/health" >/dev/null 2>&1; then
  payload="$(RECEIPT_PATH="$RECEIPT" INTENT="$INTENT" HS="$HEADSTASH" python3 - <<'PY'
import json, os
r = json.load(open(os.environ["RECEIPT_PATH"]))
print(json.dumps({
  "phase": "complete",
  "detail": "film complete",
  "mock_verify": True,
  "oracle_bound_only": True,
  "headstash_contract": os.environ.get("HS"),
  "receipt": r,
}))
PY
)"
  curl -sS -X PUT "$BASE/corridor/automation/$INTENT" \
    -H 'Content-Type: application/json' \
    -d "$payload" | head -c 400 || true
  echo
  echo "== GET automation =="
  curl -sf "$BASE/corridor/automation/$INTENT" | head -c 500 || true
  echo
else
  put_auto "$INTENT" "complete" "film complete (file-only)"
fi

echo
echo "OK mint-after-observe intent=$INTENT"
echo "  receipt=$RECEIPT"
echo "  UI poll: GET $BASE/corridor/automation/$INTENT"
echo "  design freezes: D1–D7 ACCEPTED"
echo "  residual: Zakura local (D6); oline Fulcrum packaging"
