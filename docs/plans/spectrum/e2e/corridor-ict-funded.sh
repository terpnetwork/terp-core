#!/usr/bin/env bash
# ict_local_funded proof path (S1/S2/S6) — mainnet-workflow fidelity on local nets.
#
# Does NOT spend mainnet money. Profile label: ict_local_funded (≠ lab_simulated).
#
# Steps:
#   0. preflight docker + prepare cw_headstash.wasm
#   1. start BTC regtest (compose) + hash-market host
#   2. open watch with min_amount_sats (S6)
#   3. fund deposit via bitcoind + run reporter (bitcoind_rpc backend) → observation
#   4. chain BridgeMintNote via corridor_ict_funded (ict-rs + Daemon) — no silent skip
#   5. mint-after-observe pure swap film + automation API
#
# Exit 0 only if observe + chain mint succeed. Soft-skip of mint is a FAIL.
#
# Env:
#   HASH_MARKET_URL       default http://127.0.0.1:19090
#   SKIP_REGTEST=1        skip BTC observe (FAIL for full S1 unless CORRIDOR_ALLOW_MINT_ONLY=1)
#   CORRIDOR_ALLOW_MINT_ONLY=1  allow chain-mint without regtest (dev only; STATUS residual)
#   CORRIDOR_MOCK_VERIFY  default true (labeled on funded deploy)
#   ZAKURA_DEST_ADDR      optional dest_display override (digest recomputed)
#   CORRIDOR_DEST_OWNER_BINDING  optional pin (must equal sealed hex)
#   CORRIDOR_REQUIRE_ZAKURA_RPC  if 1, fail when Zakura RPC down
#   KEEP_CHAIN=1          leave ict containers up
#   KEEP_REGTEST=1        leave bitcoind up
#   KEEP_SERVER=1         leave hash-market up
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HEADSTASH="$REPO_ROOT/crates/headstash"
PLAY="$REPO_ROOT/crates/o-line/plays/private-bridge-corridor"
HM_DIR="$REPO_ROOT/crates/terp-rs/tools/hash-market"
BASE="${HASH_MARKET_URL:-http://127.0.0.1:19090}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.corridor-funded.yml"
ZAKURA_SCRIPT="$SCRIPT_DIR/zakura/zakura-local.sh"
export CORRIDOR_MOCK_VERIFY="${CORRIDOR_MOCK_VERIFY:-true}"
# Product funded path: reject lab fillers as dest seal (hash-market open_watch).
export CORRIDOR_REJECT_PLACEHOLDER_DEST="${CORRIDOR_REJECT_PLACEHOLDER_DEST:-1}"
unset CORRIDOR_ALLOW_PLACEHOLDER_DEST || true

fail() { echo "FAIL: $*" >&2; exit 1; }
log() { echo "== $* =="; }

# G4: seal dest_owner_binding from golden primary / ZAKURA_DEST_ADDR (never "b"*64).
is_placeholder_binding_hex() {
  local h
  h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [ -z "$h" ] && return 0
  [ "${#h}" -ne 64 ] && return 1
  case "$h" in
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) return 0 ;;
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) return 0 ;;
    cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc) return 0 ;;
    0000000000000000000000000000000000000000000000000000000000000000) return 0 ;;
  esac
  return 1
}

seal_funded_dest_shell() {
  local dest bind source rpc_ready_flag
  dest="${ZAKURA_DEST_ADDR:-tmJymvcUCn1ctbghvTJpXBwHiMEB8P6wxNV}"
  source="golden_primary"
  if [ -n "${ZAKURA_DEST_ADDR:-}" ]; then
    source="env_override"
  fi
  if [ -x "$ZAKURA_SCRIPT" ] || [ -f "$ZAKURA_SCRIPT" ]; then
    chmod +x "$ZAKURA_SCRIPT" 2>/dev/null || true
    # Capture dest line from zakura-local.sh dest (offline OK).
    local dest_out
    dest_out="$(bash "$ZAKURA_SCRIPT" dest 2>/dev/null || true)"
    if printf '%s' "$dest_out" | grep -q 'owner_binding='; then
      bind="$(printf '%s\n' "$dest_out" | sed -n 's/^owner_binding=//p' | head -1 | tr -d '[:space:]')"
      dest="$(printf '%s\n' "$dest_out" | sed -n 's/^dest_display=//p' | head -1 | tr -d '[:space:]')"
      if printf '%s' "$dest_out" | grep -q 'rpc_ready=false'; then
        rpc_ready_flag="false"
      elif printf '%s' "$dest_out" | grep -q 'rpc_validated=true'; then
        rpc_ready_flag="true"
        source="live_rpc"
      else
        rpc_ready_flag="false"
      fi
    else
      bind=""
      rpc_ready_flag="false"
    fi
  else
    bind=""
    rpc_ready_flag="false"
  fi
  if [ -z "${bind:-}" ]; then
    # Pure offline fallback (same preimage as zakura_local / UI).
    if command -v sha256sum >/dev/null 2>&1; then
      bind="$(printf 'terp-dest-binding-v0|%s' "$dest" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      bind="$(printf 'terp-dest-binding-v0|%s' "$dest" | shasum -a 256 | awk '{print $1}')"
    else
      bind="$(python3 -c "import hashlib,sys; print(hashlib.sha256(('terp-dest-binding-v0|'+sys.argv[1]).encode()).hexdigest())" "$dest")"
    fi
  fi
  bind="$(printf '%s' "$bind" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if is_placeholder_binding_hex "$bind"; then
    fail "dest seal is placeholder (refused): $bind"
  fi
  if [ "${#bind}" -ne 64 ]; then
    fail "dest seal hex width ${#bind} want 64"
  fi
  if [ -n "${CORRIDOR_DEST_OWNER_BINDING:-}" ]; then
    local pin
    pin="$(printf '%s' "$CORRIDOR_DEST_OWNER_BINDING" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if is_placeholder_binding_hex "$pin"; then
      fail "CORRIDOR_DEST_OWNER_BINDING is placeholder"
    fi
    if [ "$pin" != "$bind" ]; then
      fail "CORRIDOR_DEST_OWNER_BINDING mismatch pin=$pin sealed=$bind"
    fi
  fi
  if [ "${CORRIDOR_REQUIRE_ZAKURA_RPC:-0}" = "1" ] || [ "${CORRIDOR_REQUIRE_ZAKURA_RPC:-}" = "true" ]; then
    if [ "${rpc_ready_flag:-false}" != "true" ]; then
      fail "CORRIDOR_REQUIRE_ZAKURA_RPC=1 but Zakura RPC not ready"
    fi
  fi
  export ZAKURA_DEST_DISPLAY="$dest"
  export CORRIDOR_DEST_OWNER_BINDING="$bind"
  export CORRIDOR_DEST_SEAL_SOURCE="$source"
  export CORRIDOR_DEST_RPC_READY="${rpc_ready_flag:-false}"
  echo "  dest_seal=$CORRIDOR_DEST_OWNER_BINDING source=$CORRIDOR_DEST_SEAL_SOURCE dest_display=$ZAKURA_DEST_DISPLAY rpc_ready=$CORRIDOR_DEST_RPC_READY"
}

STARTED_HM=0
HM_PID=""
STARTED_REGTEST=0
INTENT_ID="intent-ict-funded-$(date +%s)"
# regtest bech32-looking placeholder; harness overwrites with bitcoind getnewaddress
DEPOSIT_ADDR=""
MIN_SATS=10000

cleanup() {
  local code=$?
  if [ "${KEEP_SERVER:-0}" != "1" ] && [ "$STARTED_HM" = "1" ] && [ -n "$HM_PID" ]; then
    kill "$HM_PID" 2>/dev/null || true
    wait "$HM_PID" 2>/dev/null || true
  fi
  if [ "${KEEP_REGTEST:-0}" != "1" ] && [ "$STARTED_REGTEST" = "1" ]; then
    (cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" down 2>/dev/null) || true
  fi
  exit "$code"
}
trap cleanup EXIT

btc_cli() {
  docker exec corridor-bitcoind-regtest \
    bitcoin-cli -regtest -rpcuser=corridor -rpcpassword=corridor -rpcport=18443 "$@"
}

log "preflight"
command -v docker >/dev/null || fail "docker required for ict_local_funded"
command -v curl >/dev/null || fail "curl required"
command -v cargo >/dev/null || fail "cargo required"
docker info >/dev/null 2>&1 || fail "dockerd not reachable"
# P2: ports / wasm surface / optional Zakura (fail-closed if CORRIDOR_REQUIRE_ZAKURA_RPC=1)
if [ -f "$SCRIPT_DIR/preflight-corridor-local.sh" ]; then
  chmod +x "$SCRIPT_DIR/preflight-corridor-local.sh" 2>/dev/null || true
  bash "$SCRIPT_DIR/preflight-corridor-local.sh" \
    || fail "preflight-corridor-local failed"
fi

# Zakura preflight: reuse RPC or best-effort start; soft-skip labeled (P0).
ZAKURA_RPC_URL="${ZAKURA_RPC:-http://127.0.0.1:18232}"
zakura_rpc_ready() {
  curl -sf --max-time 3 -X POST "${ZAKURA_RPC_URL}/" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}' 2>/dev/null \
    | grep -q '"result"'
}
log "Zakura preflight (soft-skip unless CORRIDOR_REQUIRE_ZAKURA_RPC=1)"
if zakura_rpc_ready; then
  echo "  Zakura RPC ready at $ZAKURA_RPC_URL (reuse)"
  export CORRIDOR_DEST_RPC_READY=true
elif [ -n "${ZAKURAD_BIN:-}" ] && [ -x "${ZAKURAD_BIN}" ] && [ -f "$ZAKURA_SCRIPT" ]; then
  echo "  starting Zakura via zakura-local.sh up (ZAKURAD_BIN set)"
  if bash "$ZAKURA_SCRIPT" up; then
    for _ in $(seq 1 30); do
      zakura_rpc_ready && break
      sleep 1
    done
    if zakura_rpc_ready; then
      echo "  Zakura RPC ready after up"
      export CORRIDOR_DEST_RPC_READY=true
    else
      echo "WARN: Zakura up attempted but RPC not ready — soft-skip residual (lab_inventory_pay_simulated)"
      export CORRIDOR_DEST_RPC_READY=false
    fi
  else
    echo "WARN: zakura-local.sh up failed — soft-skip residual (lab_inventory_pay_simulated)"
    export CORRIDOR_DEST_RPC_READY=false
  fi
else
  echo "WARN: Zakura soft-skip residual — no RPC at $ZAKURA_RPC_URL and no ZAKURAD_BIN; Option D lab pay may be lab_inventory_pay_simulated"
  export CORRIDOR_DEST_RPC_READY=false
  if [ "${CORRIDOR_REQUIRE_ZAKURA_RPC:-0}" = "1" ] || [ "${CORRIDOR_REQUIRE_ZAKURA_RPC:-}" = "true" ]; then
    fail "CORRIDOR_REQUIRE_ZAKURA_RPC=1 but Zakura not ready (set ZAKURAD_BIN or start node)"
  fi
fi

if [ "${CORRIDOR_CHAIN_SETTLE:-0}" = "1" ] || [ "${CORRIDOR_ZEC_EGRESS_D:-0}" = "1" ]; then
  log "prepare cw_headstash.wasm + cw_private_dex.wasm (settle/egress profile)"
  CORRIDOR_PREPARE_PRIVATE_DEX=1 CORRIDOR_ZEC_EGRESS_D="${CORRIDOR_ZEC_EGRESS_D:-0}" \
    bash "$SCRIPT_DIR/prepare-corridor-ict-wasm.sh"
else
  log "prepare cw_headstash.wasm"
  bash "$SCRIPT_DIR/prepare-corridor-ict-wasm.sh"
fi

# ── hash-market (prefer rebuilt binary with S6 + claim-inputs) ───────────────
log "ensure hash-market-server (S6 gates + claim-inputs)"
HM_BIN="$REPO_ROOT/crates/terp-rs/target/release/hash-market-server"
hm_has_claim_inputs() {
  [ -x "$HM_BIN" ] || return 1
  python3 - "$HM_BIN" <<'PY'
import sys
sys.exit(0 if b"claim-inputs" in open(sys.argv[1], "rb").read() else 1)
PY
}
# Rebuild when missing, forced, or stale bin without G1 claim-inputs bus.
if [ ! -x "$HM_BIN" ] || [ "${FORCE_HM_REBUILD:-0}" = "1" ] || ! hm_has_claim_inputs; then
  echo "  building hash-market-server (release, features=server)…"
  (cd "$HM_DIR" && cargo build --release --bin hash-market-server --features server)
  hm_has_claim_inputs || fail "hash-market-server missing claim-inputs route after build"
fi
if curl -sf "$BASE/health" >/dev/null 2>&1; then
  # If a stale server is already bound, claim-inputs may 404 — probe and refuse reuse.
  if curl -sf "$BASE/corridor/claim-inputs/__corridor_probe__" >/dev/null 2>&1 \
    || curl -sS -o /tmp/hm-claim-probe.json -w '%{http_code}' \
         "$BASE/corridor/claim-inputs/__corridor_probe__" 2>/dev/null | grep -qE '200|404|400'; then
    # 404 with JSON body is fine (missing watch); connection fail is not.
    code="$(curl -sS -o /tmp/hm-claim-probe.json -w '%{http_code}' \
      "$BASE/corridor/claim-inputs/__corridor_probe__" 2>/dev/null || echo 000)"
    if [ "$code" = "000" ]; then
      fail "hash-market health up but claim-inputs unreachable"
    fi
    echo "  reusing existing hash-market at $BASE (claim-inputs HTTP $code)"
  else
    fail "existing hash-market at $BASE lacks claim-inputs — free port or FORCE_HM_REBUILD=1 + restart"
  fi
else
  LAB_RUN="$(mktemp -d -t corridor-ict-hm-XXXXXX)"
  PORT="${BASE##*:}"
  PORT="${PORT%%/*}"
  cat >"$LAB_RUN/config.toml" <<EOF
bind = "127.0.0.1:${PORT}"
chain_id = "corridor-ict-funded"
data_dir = "$LAB_RUN/data"
ve_enabled = false
cors_allow_origin = "*"
EOF
  mkdir -p "$LAB_RUN/data"
  "$HM_BIN" -c "$LAB_RUN/config.toml" >"$LAB_RUN/server.log" 2>&1 &
  HM_PID=$!
  STARTED_HM=1
  for _ in $(seq 1 60); do
    curl -sf "$BASE/health" >/dev/null 2>&1 && break
    sleep 0.15
  done
  curl -sf "$BASE/health" >/dev/null || {
    cat "$LAB_RUN/server.log" >&2 || true
    fail "hash-market did not start"
  }
fi
echo "  HASH_MARKET_URL=$BASE"

# ── BTC regtest + observe (S2) ───────────────────────────────────────────────
if [ "${SKIP_REGTEST:-0}" = "1" ]; then
  if [ "${CORRIDOR_ALLOW_MINT_ONLY:-0}" = "1" ]; then
    echo "WARN: SKIP_REGTEST + CORRIDOR_ALLOW_MINT_ONLY — observe skipped (dev residual)"
  else
    fail "SKIP_REGTEST without CORRIDOR_ALLOW_MINT_ONLY=1 (funded profile requires observe)"
  fi
else
  log "BTC regtest (bitcoind) up"
  if ! docker ps --format '{{.Names}}' | grep -q '^corridor-bitcoind-regtest$'; then
    (cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" up -d bitcoind)
    STARTED_REGTEST=1
  fi
  for i in $(seq 1 40); do
    if btc_cli getblockchaininfo >/dev/null 2>&1; then
      break
    fi
    sleep 1
    if [ "$i" -eq 40 ]; then
      fail "bitcoind regtest not ready"
    fi
  done

  # wallet + deposit address
  btc_cli createwallet "corridor" >/dev/null 2>&1 || btc_cli loadwallet "corridor" >/dev/null 2>&1 || true
  MINE_ADDR="$(btc_cli getnewaddress)"
  DEPOSIT_ADDR="$(btc_cli getnewaddress)"
  # mature coinbase
  btc_cli generatetoaddress 101 "$MINE_ADDR" >/dev/null
  # fund deposit (0.0002 BTC = 20_000 sats) above MIN_SATS
  TXID="$(btc_cli sendtoaddress "$DEPOSIT_ADDR" 0.0002)"
  btc_cli generatetoaddress 1 "$MINE_ADDR" >/dev/null
  echo "  deposit_addr=$DEPOSIT_ADDR txid=$TXID amount_sats=20000"

  log "G4 dest seal (golden primary / ZAKURA_DEST_ADDR)"
  seal_funded_dest_shell
  case "$CORRIDOR_DEST_OWNER_BINDING" in
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
      fail "funded watch dest must not be all-b placeholder"
      ;;
  esac

  log "open watch (min_amount_sats=$MIN_SATS dest_seal=${CORRIDOR_DEST_OWNER_BINDING:0:16}…)"
  WATCH_PAYLOAD="$(INTENT="$INTENT_ID" ADDR="$DEPOSIT_ADDR" MIN="$MIN_SATS" DEST_BIND="$CORRIDOR_DEST_OWNER_BINDING" python3 - <<'PY'
import json, os
dest = os.environ["DEST_BIND"].strip().lower()
if not dest or dest == "b" * 64 or len(dest) != 64:
    raise SystemExit(f"bad dest seal for watch: {dest!r}")
print(json.dumps({
  "intent_id": os.environ["INTENT"],
  "corridor_id": "cashapp-btc-zec-v0",
  "btc_deposit_addr": os.environ["ADDR"],
  "domain_bind": "a" * 64,
  "dest_owner_binding": dest,
  "client_proof_digest": "c" * 64,
  "client_pubkey_hex": "02ab",
  "ttl_secs": 3600,
  "min_amount_sats": int(os.environ["MIN"]),
}))
PY
)"
  code="$(curl -sS -o /tmp/corr-watch.json -w '%{http_code}' -X POST \
    "$BASE/corridor/watches" -H 'Content-Type: application/json' -d "$WATCH_PAYLOAD" || echo 000)"
  [ "$code" = "201" ] || [ "$code" = "200" ] || fail "open watch HTTP $code $(cat /tmp/corr-watch.json 2>/dev/null || true)"
  # Evidence: stored watch must echo sealed binding (not placeholder).
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' || fail "watch dest seal mismatch / placeholder"
import json, os
want = os.environ["CORRIDOR_DEST_OWNER_BINDING"].strip().lower()
with open("/tmp/corr-watch.json") as f:
    body = json.load(f)
got = (body.get("dest_owner_binding") or "").strip().lower()
if got != want:
    raise SystemExit(f"watch dest_owner_binding={got} want={want}")
if got == "b" * 64:
    raise SystemExit("placeholder dest on watch")
print(f"  watch dest_owner_binding OK ({got[:16]}…)")
PY
  fi

  # Negative gate evidence: dust / below min must fail
  log "S6 gate: reject below min_amount"
  BAD="$(INTENT="$INTENT_ID" ADDR="$DEPOSIT_ADDR" python3 - <<'PY'
import json, os
print(json.dumps({
  "intent_id": os.environ["INTENT"],
  "btc_deposit_addr": os.environ["ADDR"],
  "txid": "00" * 32,
  "amount_sats": 1,
  "confirmations": 1,
  "observed_at": 0,
  "reporter": "gate-test",
}))
PY
)"
  bad_code="$(curl -sS -o /tmp/corr-bad-obs.json -w '%{http_code}' -X POST \
    "$BASE/corridor/observations" -H 'Content-Type: application/json' -d "$BAD" || echo 000)"
  if [ "$bad_code" = "201" ] || [ "$bad_code" = "200" ]; then
    fail "S6: expected reject for amount below min, got HTTP $bad_code"
  fi
  echo "  below-min rejected HTTP $bad_code ✓"

  log "build/run corridor-btc-reporter (bitcoind backend)"
  REP_BIN="$REPO_ROOT/crates/terp-rs/target/release/corridor-btc-reporter"
  # Rebuild when missing/forced, or stale binary predating DepositObservation.vout posts.
  if [ ! -x "$REP_BIN" ] || [ "${FORCE_HM_REBUILD:-0}" = "1" ]; then
    (cd "$HM_DIR" && cargo build --release --bin corridor-btc-reporter --features server)
  elif ! python3 - "$REP_BIN" <<'PY'
import sys
# crude: source posts "vout" field; rebuild if binary looks older than server with claim-inputs
sys.exit(0 if b"vout" in open(sys.argv[1], "rb").read() else 1)
PY
  then
    (cd "$HM_DIR" && cargo build --release --bin corridor-btc-reporter --features server)
  else
    # Prefer same generation as hash-market-server (avoid vout=null posts from stale reporter).
    if [ "$HM_BIN" -nt "$REP_BIN" ]; then
      echo "  rebuilding corridor-btc-reporter (older than hash-market-server)"
      (cd "$HM_DIR" && cargo build --release --bin corridor-btc-reporter --features server)
    fi
  fi
  REP_CFG="$(mktemp -t reporter-regtest-XXXXXX.toml)"
  cat >"$REP_CFG" <<EOF
hash_market_url = "$BASE"
backend = "bitcoind"
bitcoind_rpc_url = "http://127.0.0.1:18443"
bitcoind_rpc_user = "corridor"
bitcoind_rpc_pass = "corridor"
min_confirmations = 1
min_amount_sats = 1000
poll_interval_secs = 2
reporter_name = "corridor-btc-reporter-regtest"
state_path = "/tmp/corridor-reporter-ict-funded-state.json"
EOF
  # Run reporter briefly in background, wait for deposit_observed
  "$REP_BIN" -c "$REP_CFG" >"/tmp/corridor-reporter-ict.log" 2>&1 &
  REP_PID=$!
  observed=0
  for i in $(seq 1 45); do
    st="$(curl -sf "$BASE/corridor/watches/$INTENT_ID" 2>/dev/null || echo '{}')"
    case "$st" in
      *deposit_observed*) observed=1; break ;;
    esac
    sleep 1
  done
  kill "$REP_PID" 2>/dev/null || true
  wait "$REP_PID" 2>/dev/null || true
  rm -f "$REP_CFG"
  if [ "$observed" != "1" ]; then
    echo "---- reporter log ----" >&2
    tail -50 /tmp/corridor-reporter-ict.log >&2 || true
    fail "timeout waiting for deposit_observed via reporter (S2)"
  fi
  echo "  deposit_observed via corridor-btc-reporter ✓ intent=$INTENT_ID"

  # G1 continuous: claim-inputs → deposit mint env (fail-closed if incomplete).
  log "claim-inputs → CORRIDOR_DEPOSIT_* (deposit-backed mint default)"
  CLAIM_JSON="$(curl -sf "$BASE/corridor/claim-inputs/$INTENT_ID" || true)"
  [ -n "$CLAIM_JSON" ] || fail "GET /corridor/claim-inputs/$INTENT_ID empty (hash-market claim bus)"
  echo "$CLAIM_JSON" > /tmp/corridor-claim-inputs.json
  # If reporter omitted vout (stale bin), recover from bitcoind listunspent / gettxout.
  export DEPOSIT_ADDR INTENT_ID
  VOUT_RECOVER="$(python3 - <<'PY' 2>/dev/null || true
import json
doc=json.load(open("/tmp/corridor-claim-inputs.json"))
obs=doc.get("observation") or {}
vout=obs.get("vout")
if vout is not None:
    print(int(vout)); raise SystemExit(0)
print("", end="")
PY
)"
  if [ -z "${VOUT_RECOVER}" ]; then
    # Prefer listunspent against known deposit address (regtest wallet).
    VOUT_RECOVER="$(btc_cli listunspent 0 9999999 "[\"$DEPOSIT_ADDR\"]" 2>/dev/null \
      | python3 -c 'import json,sys; u=json.load(sys.stdin); print(u[0]["vout"] if u else "")' 2>/dev/null || true)"
  fi
  if [ -n "${VOUT_RECOVER}" ]; then
    export CORRIDOR_DEPOSIT_VOUT_RECOVER="$VOUT_RECOVER"
  fi
  eval "$(python3 - "$CLAIM_JSON" <<'PY' || fail "claim-inputs parse failed"
import json, sys, shlex, os
doc = json.loads(sys.argv[1])
obs = doc.get("observation") or {}
watch = doc.get("watch") or {}
txid = (obs.get("txid") or "").strip()
vout = obs.get("vout")
if vout is None:
    rec = os.environ.get("CORRIDOR_DEPOSIT_VOUT_RECOVER", "").strip()
    if rec != "":
        vout = int(rec)
        print(f"  recovered vout={vout} from bitcoind (reporter omitted vout)", file=sys.stderr)
amount = obs.get("amount_sats")
addr = (obs.get("btc_deposit_addr") or watch.get("btc_deposit_addr") or "").strip()
dest = (doc.get("dest_owner_binding") or watch.get("dest_owner_binding") or "").strip().lower()
st = doc.get("identity_status") or ""
ready = (
    bool(txid)
    and vout is not None
    and amount
    and dest
    and len(dest) == 64
)
if not ready:
    raise SystemExit(
        f"identity_status={st!r} incomplete claim fields txid={txid!r} vout={vout!r} amount={amount!r} dest={dest!r}"
    )
print(f"export CORRIDOR_DEPOSIT_TXID={shlex.quote(txid)}")
print(f"export CORRIDOR_DEPOSIT_VOUT={shlex.quote(str(int(vout)))}")
print(f"export CORRIDOR_DEPOSIT_AMOUNT_SATS={shlex.quote(str(int(amount)))}")
if addr:
    print(f"export CORRIDOR_DEPOSIT_ADDR={shlex.quote(addr)}")
print(f"export CORRIDOR_DEST_OWNER_BINDING={shlex.quote(dest)}")
if doc.get("nullifier_preview_hex"):
    print(f"export CORRIDOR_NULLIFIER_PREVIEW={shlex.quote(doc['nullifier_preview_hex'])}")
print("export CORRIDOR_REQUIRE_DEPOSIT_CLAIM=1")
print(f"# claim-inputs ready amount_sats={amount} vout={vout} dest={dest[:16]}…", file=sys.stderr)
PY
)"
  echo "  CORRIDOR_DEPOSIT_TXID=${CORRIDOR_DEPOSIT_TXID:0:16}… vout=${CORRIDOR_DEPOSIT_VOUT} amount_sats=${CORRIDOR_DEPOSIT_AMOUNT_SATS}"
  echo "  deposit mint env ready (CORRIDOR_REQUIRE_DEPOSIT_CLAIM=1)"
fi

# ── chain BridgeMintNote (+ optional SettleSwap) (S1 hard) ───────────────────
# Ensure dest seal env is set even on mint-only residual (no regtest watch).
if [ -z "${CORRIDOR_DEST_OWNER_BINDING:-}" ]; then
  log "G4 dest seal (mint path; no prior watch)"
  seal_funded_dest_shell
fi
# Mint-only residual: prefer synthetic deposit claim (G4 dest continuous) over hinge happy.
# Labeled residual — not regtest-observed; still deposit-builder ν domain (provisional).
if [ "${SKIP_REGTEST:-0}" = "1" ] && [ "${CORRIDOR_ALLOW_MINT_ONLY:-0}" = "1" ]; then
  if [ -z "${CORRIDOR_DEPOSIT_TXID:-}" ]; then
    export CORRIDOR_DEPOSIT_TXID="${CORRIDOR_DEPOSIT_TXID:-00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff}"
    export CORRIDOR_DEPOSIT_VOUT="${CORRIDOR_DEPOSIT_VOUT:-0}"
    export CORRIDOR_DEPOSIT_AMOUNT_SATS="${CORRIDOR_DEPOSIT_AMOUNT_SATS:-20000}"
    export CORRIDOR_DEPOSIT_ADDR="${CORRIDOR_DEPOSIT_ADDR:-mint-only-lab-residual}"
    echo "WARN: mint-only residual — synthetic CORRIDOR_DEPOSIT_* (labeled; not regtest-observed)"
    echo "  txid=${CORRIDOR_DEPOSIT_TXID:0:16}… vout=$CORRIDOR_DEPOSIT_VOUT amount=$CORRIDOR_DEPOSIT_AMOUNT_SATS"
  fi
  # Happy fixture only if operator opts in without synthetic deposit (fallback).
  export CORRIDOR_ALLOW_HAPPY_FIXTURE="${CORRIDOR_ALLOW_HAPPY_FIXTURE:-0}"
fi
if [ "${CORRIDOR_CHAIN_SETTLE:-0}" = "1" ]; then
  log "ict-rs + Daemon BridgeMintNote + SettleSwap (corridor_ict_funded, CORRIDOR_CHAIN_SETTLE=1)"
else
  log "ict-rs + Daemon BridgeMintNote (corridor_ict_funded)"
fi
export CORRIDOR_INTENT_ID="${CORRIDOR_INTENT_ID:-$INTENT_ID}"
export CORRIDOR_MINT_EVIDENCE_PATH="${CORRIDOR_MINT_EVIDENCE_PATH:-/tmp/corridor-mint-evidence.json}"
export CORRIDOR_SETTLE_RECEIPT_PATH="${CORRIDOR_SETTLE_RECEIPT_PATH:-/tmp/corridor-settle-receipt.json}"
export CORRIDOR_EGRESS_BURN_EVIDENCE_PATH="${CORRIDOR_EGRESS_BURN_EVIDENCE_PATH:-/tmp/corridor-egress-burn-evidence.json}"
export CORRIDOR_ZEC_EGRESS_RECEIPT_PATH="${CORRIDOR_ZEC_EGRESS_RECEIPT_PATH:-/tmp/corridor-zec-egress-receipt.json}"
# Option D implies settle (fail-closed in binary if settle off).
if [ "${CORRIDOR_ZEC_EGRESS_D:-0}" = "1" ] || [ "${CORRIDOR_ZEC_EGRESS_D:-}" = "true" ]; then
  export CORRIDOR_CHAIN_SETTLE=1
  log "Option D enabled (CORRIDOR_ZEC_EGRESS_D=1) → force CORRIDOR_CHAIN_SETTLE=1"
fi
(
  cd "$HEADSTASH"
  # Propagate sealed dest + deposit claim so binary matches watch / golden.
  export ZAKURA_DEST_DISPLAY CORRIDOR_DEST_OWNER_BINDING CORRIDOR_DEST_SEAL_SOURCE CORRIDOR_DEST_RPC_READY
  export ZAKURA_DEST_ADDR="${ZAKURA_DEST_ADDR:-${ZAKURA_DEST_DISPLAY:-}}"
  export CORRIDOR_CHAIN_SETTLE CORRIDOR_ZEC_EGRESS_D CORRIDOR_INTENT_ID CORRIDOR_MINT_EVIDENCE_PATH CORRIDOR_SETTLE_RECEIPT_PATH
  export CORRIDOR_EGRESS_BURN_EVIDENCE_PATH CORRIDOR_ZEC_EGRESS_RECEIPT_PATH
  export CORRIDOR_DEPOSIT_TXID CORRIDOR_DEPOSIT_VOUT CORRIDOR_DEPOSIT_AMOUNT_SATS CORRIDOR_DEPOSIT_ADDR
  export CORRIDOR_REQUIRE_DEPOSIT_CLAIM CORRIDOR_ALLOW_HAPPY_FIXTURE CORRIDOR_NULLIFIER_PREVIEW
  cargo run -p zk-test-press --bin corridor_ict_funded --features 'ict-daemon,l0-seams' --release
) || fail "corridor_ict_funded (chain mint/settle/egress-d) failed — no silent skip"

# Settle receipt assert (G3 fail-closed; never soft-skip when settle profile on)
if [ "${CORRIDOR_CHAIN_SETTLE:-0}" = "1" ]; then
  log "assert SettleReceiptV0"
  [ -f "$CORRIDOR_SETTLE_RECEIPT_PATH" ] || fail "missing settle receipt at $CORRIDOR_SETTLE_RECEIPT_PATH"
  python3 - "$CORRIDOR_SETTLE_RECEIPT_PATH" <<'PY' || fail "settle receipt assert failed"
import json, sys
p = sys.argv[1]
doc = json.load(open(p))
assert doc.get("status") == "complete", doc
assert doc.get("proof_mode") == "mock_verify_lab", doc
assert doc.get("halo2_swap") is False, doc
assert doc.get("skip_ibc_post_swap") is False, doc
assert doc.get("private_dex_contract"), doc
assert doc.get("pool_id") is not None, doc
assert doc.get("mint_cm_public_hex"), doc
assert doc.get("nullifiers_hex"), doc
assert doc.get("cm_out_hex"), doc
print(f"  receipt status=complete proof_mode=mock_verify_lab pool_id={doc.get('pool_id')} ✓")
PY
fi

# Option D dual receipts (fail-closed; pure_record_lab residual OK when CW burn missing)
if [ "${CORRIDOR_ZEC_EGRESS_D:-0}" = "1" ] || [ "${CORRIDOR_ZEC_EGRESS_D:-}" = "true" ]; then
  log "assert EgressBurnEvidenceV0 + ZecEgressReceiptV0"
  [ -f "$CORRIDOR_EGRESS_BURN_EVIDENCE_PATH" ] || fail "missing egress burn evidence at $CORRIDOR_EGRESS_BURN_EVIDENCE_PATH"
  [ -f "$CORRIDOR_ZEC_EGRESS_RECEIPT_PATH" ] || fail "missing zec egress receipt at $CORRIDOR_ZEC_EGRESS_RECEIPT_PATH"
  python3 - "$CORRIDOR_EGRESS_BURN_EVIDENCE_PATH" "$CORRIDOR_ZEC_EGRESS_RECEIPT_PATH" <<'PY' || fail "option d dual receipt assert failed"
import json, sys
ev = json.load(open(sys.argv[1]))
zr = json.load(open(sys.argv[2]))
assert ev.get("status") == "complete", ev
assert ev.get("egress_nf_label") == "egress-nf-v0", ev
assert ev.get("proof_mode") == "mock_verify_lab", ev
assert ev.get("burn_surface") in ("pure_record_lab", "cw_bridge_egress_burn"), ev
assert ev.get("burn", {}).get("nullifier_hex"), ev
assert zr.get("status") == "complete", zr
assert zr.get("burn_nullifier_hex") == ev["burn"]["nullifier_hex"], (zr, ev)
assert zr.get("dest_owner_binding_hex") == ev["burn"]["dest_commitment_hex"], (zr, ev)
assert zr.get("amount_zat") == ev["burn"]["value"], (zr, ev)
assert zr.get("mode") in ("lab_inventory_pay_simulated", "lab_inventory_pay", "lc_mint"), zr
# Single dest seal e2e: zec receipt binding must equal G4 env when set.
import os
want = (os.environ.get("CORRIDOR_DEST_OWNER_BINDING") or "").strip().lower()
if want:
    got = (zr.get("dest_owner_binding_hex") or "").strip().lower()
    assert got == want, (got, want)
    disp = zr.get("dest_display") or ""
    assert not disp.startswith("demo_zec_mint_seal_"), f"invent residual dest_display={disp!r} with G4 set"
print(f"  option_d burn_surface={ev.get('burn_surface')} mode={zr.get('mode')} amount={zr.get('amount_zat')} dest_ok ✓")
PY
fi

# ── automation film for UI poll ──────────────────────────────────────────────
log "automation film (mint-after-observe phases)"
export INTENT_ID
export HASH_MARKET_URL="$BASE"
export HEADSTASH_CONTRACT="${HEADSTASH_CONTRACT:-cw-headstash-ict-local}"
export SKIP_WAIT=1
bash "$SCRIPT_DIR/corridor-lab-mint-after-observe.sh" || fail "mint-after-observe film failed"

echo ""
echo "========================================"
echo "  OK ict_local_funded"
echo "  mock_verify=$CORRIDOR_MOCK_VERIFY"
echo "  intent=$INTENT_ID"
echo "  dest_seal=${CORRIDOR_DEST_OWNER_BINDING:-unset}"
echo "  dest_seal_source=${CORRIDOR_DEST_SEAL_SOURCE:-unset}"
echo "  observe=regtest+reporter (unless mint-only residual)"
echo "  mint=Daemon BridgeMintNote via ict-rs"
if [ "${CORRIDOR_CHAIN_SETTLE:-0}" = "1" ]; then
  echo "  settle=Daemon SettleSwap (cw-private-dex, mock_verify_lab)"
  echo "  receipt=$CORRIDOR_SETTLE_RECEIPT_PATH"
fi
if [ "${CORRIDOR_ZEC_EGRESS_D:-0}" = "1" ] || [ "${CORRIDOR_ZEC_EGRESS_D:-}" = "true" ]; then
  echo "  option_d=settle→burn→lab_pay (CORRIDOR_ZEC_EGRESS_D=1)"
  echo "  egress_evidence=$CORRIDOR_EGRESS_BURN_EVIDENCE_PATH"
  echo "  zec_receipt=$CORRIDOR_ZEC_EGRESS_RECEIPT_PATH"
fi
echo "========================================"
