#!/usr/bin/env bash
# P2 preflight — ports, Docker, wasm surfaces, optional Zakura for stable local multi-net.
#
# Usage:
#   bash preflight-corridor-local.sh              # soft Zakura
#   CORRIDOR_REQUIRE_ZAKURA_RPC=1 bash preflight-corridor-local.sh
#   CORRIDOR_CHAIN_SETTLE=1 CORRIDOR_ZEC_EGRESS_D=1 bash preflight-corridor-local.sh
#
# Exit 0 if machine can run ict_local_funded (+ optional settle/egress).
# Does not start long-lived services except optional Zakura when requested.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HEADSTASH="$REPO_ROOT/crates/headstash"
ART="$HEADSTASH/artifacts"
ZAKURA_SCRIPT="$SCRIPT_DIR/zakura/zakura-local.sh"

HASH_MARKET_URL="${HASH_MARKET_URL:-http://127.0.0.1:19090}"
ZAKURA_RPC="${ZAKURA_RPC:-http://127.0.0.1:18232}"
# Default Terp image used by corridor_ict_funded / ict-rs (pin for stability).
TERP_IMAGE="${CORRIDOR_TERP_IMAGE:-terpnetwork/terp-core:local-zk}"

fail() { echo "FAIL preflight: $*" >&2; exit 1; }
warn() { echo "WARN preflight: $*" >&2; }
ok() { echo "  OK $*"; }
log() { echo "== preflight-corridor-local: $* =="; }

port_listening() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:Listen >/dev/null 2>&1
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
  else
    return 1
  fi
}

wasm_has() {
  local f="$1" needle="$2"
  [ -f "$f" ] || return 1
  python3 - "$f" "$needle" <<'PY'
import sys
sys.exit(0 if sys.argv[2].encode() in open(sys.argv[1], "rb").read() else 1)
PY
}

log "tools"
command -v docker >/dev/null || fail "docker required"
command -v curl >/dev/null || fail "curl required"
command -v cargo >/dev/null || fail "cargo required"
command -v python3 >/dev/null || fail "python3 required"
docker info >/dev/null 2>&1 || fail "dockerd not reachable"
ok "docker + curl + cargo"

if command -v wasm-opt >/dev/null 2>&1; then
  ver="$(wasm-opt --version 2>/dev/null | head -1 || true)"
  ok "wasm-opt present ($ver) — prefer binaryen ≥120 for bulk-memory lowering"
else
  warn "wasm-opt missing — prepare-corridor-ict-wasm may use optimizer image"
fi

log "pinned stack (document / env overrides)"
echo "  TERP_IMAGE=${TERP_IMAGE}  (override CORRIDOR_TERP_IMAGE)"
echo "  HASH_MARKET_URL=${HASH_MARKET_URL}"
echo "  ZAKURA_RPC=${ZAKURA_RPC}"
echo "  profile labels: lab_simulated | ict_local_funded | production — do not collapse"

log "host ports (conflict awareness)"
# 19090 hash-market, 18232 Zakura, common bitcoind regtest 18443
for p in 19090 18232 18443 26657; do
  if port_listening "$p"; then
    echo "  port $p: LISTEN (will reuse or fail if wrong process)"
  else
    echo "  port $p: free"
  fi
done

log "wasm artifacts (optional check; prepare script rebuilds)"
HS_WASM="$ART/cw_headstash.wasm"
DEX_WASM="$ART/cw_private_dex.wasm"
if [ -f "$HS_WASM" ]; then
  if wasm_has "$HS_WASM" "BridgeMint" || wasm_has "$HS_WASM" "BridgeEgress"; then
    ok "cw_headstash.wasm present ($(wc -c <"$HS_WASM" | tr -d ' ') B)"
  else
    warn "cw_headstash.wasm missing BridgeMint/BridgeEgress strings — re-run prepare"
  fi
  if [ "${CORRIDOR_ZEC_EGRESS_D:-0}" = "1" ]; then
    if wasm_has "$HS_WASM" "BridgeEgress" || wasm_has "$HS_WASM" "bridge_egress" || wasm_has "$HS_WASM" "IsEgressSpent"; then
      ok "BridgeEgress surface in headstash wasm"
    else
      warn "Option D: BridgeEgress missing — prepare will FAIL closed (FORCE_WASM_REBUILD=1)"
    fi
  fi
else
  warn "no $HS_WASM yet — funded script will prepare"
fi

if [ "${CORRIDOR_CHAIN_SETTLE:-0}" = "1" ] || [ "${CORRIDOR_ZEC_EGRESS_D:-0}" = "1" ]; then
  if [ -f "$DEX_WASM" ] && (wasm_has "$DEX_WASM" "SettleSwap" || wasm_has "$DEX_WASM" "CreatePool"); then
    ok "cw_private_dex.wasm SettleSwap surface ($(wc -c <"$DEX_WASM" | tr -d ' ') B)"
  else
    warn "settle/egress: prepare with CORRIDOR_PREPARE_PRIVATE_DEX=1 (will FAIL closed if missing after prepare)"
  fi
fi

log "Zakura RPC (optional unless CORRIDOR_REQUIRE_ZAKURA_RPC=1)"
if curl -sf --max-time 3 -X POST "${ZAKURA_RPC}/" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}' 2>/dev/null \
  | grep -q '"result"'; then
  ok "Zakura RPC ready at $ZAKURA_RPC"
else
  if [ "${CORRIDOR_REQUIRE_ZAKURA_RPC:-0}" = "1" ] || [ "${CORRIDOR_REQUIRE_ZAKURA_RPC:-}" = "true" ]; then
    fail "Zakura RPC down at $ZAKURA_RPC (start: bash $ZAKURA_SCRIPT up with ZAKURAD_BIN)"
  else
    warn "Zakura RPC not ready — Option D lab pay may be lab_inventory_pay_simulated"
    if [ -n "${ZAKURAD_BIN:-}" ] && [ -x "${ZAKURAD_BIN}" ]; then
      echo "  ZAKURAD_BIN set; can: bash \"$ZAKURA_SCRIPT\" up"
    else
      echo "  set ZAKURAD_BIN to Linux zakurad for Docker spawn (ict-rs feature=zakura or zakura-local.sh)"
    fi
  fi
fi

log "image presence (best-effort)"
if docker image inspect "$TERP_IMAGE" >/dev/null 2>&1; then
  ok "local image $TERP_IMAGE"
else
  warn "image $TERP_IMAGE not local — ict-rs may pull/fail; build/tag before full e2e"
fi

echo ""
echo "OK preflight-corridor-local"
echo "  next: cd crates/headstash && just prepare-corridor-ict-wasm-settle"
echo "  full:  just demo-corridor-ict-egress-d   (or demo-corridor-full-local when landed)"
echo "  labels: mock_verify lab OK; local ≠ mainnet money"
exit 0
