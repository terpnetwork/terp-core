#!/usr/bin/env bash
# Prepare optimized cw_headstash.wasm (+ optional cw_private_dex.wasm) for Daemon upload.
#
# Primary path (reliable for this monorepo):
#   1. Host `cargo build -p <pkg> --target wasm32-unknown-unknown --release`
#      with guest feature graph (no host-crypto / multicore / secp C-sys)
#   2. Optimize with host wasm-opt (binaryen ≥120) or optimizer image
#
# Env:
#   FORCE_WASM_REBUILD=1
#   SKIP_OPTIMIZER=1               copy only (no rebuild / no wasm-opt)
#   CORRIDOR_PREPARE_PRIVATE_DEX=1 also build cw_private_dex.wasm (G3 settle)
#   CORRIDOR_CHAIN_SETTLE=1        implies CORRIDOR_PREPARE_PRIVATE_DEX=1
#   CORRIDOR_OPTIMIZER_IMAGE       default terpnetwork/workspace-optimizer-arm64:0.17.0
#   DOCKER_PLATFORM                default auto
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CRATES="$ROOT/crates"
HS="$CRATES/headstash"
ART="$HS/artifacts"
CONTRACT_ART="$HS/contracts/cw-headstash/artifacts"
DEX_CONTRACT_ART="$HS/contracts/cw-private-dex/artifacts"
DEST="$ART/cw_headstash.wasm"
DEST2="$CONTRACT_ART/cw_headstash.wasm"
DEX_DEST="$ART/cw_private_dex.wasm"
DEX_DEST2="$DEX_CONTRACT_ART/cw_private_dex.wasm"
mkdir -p "$ART" "$CONTRACT_ART" "$DEX_CONTRACT_ART"

log() { echo "  $*"; }
fail() { echo "FAIL closed: $*" >&2; exit 1; }

PREPARE_DEX=0
if [ "${CORRIDOR_PREPARE_PRIVATE_DEX:-0}" = "1" ] \
  || [ "${CORRIDOR_CHAIN_SETTLE:-0}" = "1" ] \
  || [ "${CORRIDOR_PREPARE_PRIVATE_DEX:-}" = "true" ]; then
  PREPARE_DEX=1
fi

arch_default() {
  case "$(uname -m)" in
    arm64|aarch64) echo "linux/arm64" ;;
    *) echo "linux/amd64" ;;
  esac
}

image_default() {
  echo "${CORRIDOR_OPTIMIZER_IMAGE:-terpnetwork/workspace-optimizer-arm64:0.17.0}"
}

install_dest() {
  local src="$1"
  local dest="$2"
  local dest2="$3"
  if [ "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" != "$(cd "$(dirname "$dest")" && pwd)/$(basename "$dest")" ]; then
    cp -f "$src" "$dest"
  fi
  if [ "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" != "$(cd "$(dirname "$dest2")" && pwd)/$(basename "$dest2")" ]; then
    cp -f "$src" "$dest2"
  fi
  [ -f "$dest" ] || cp -f "$src" "$dest"
  [ -f "$dest2" ] || cp -f "$src" "$dest2"
  log "installed $dest and $dest2 ($(wc -c <"$dest2" | tr -d ' ') bytes)"
}

# Prefer python byte search — macOS `strings` can miss export names in large wasms.
_wasm_contains() {
  local f="$1" needle="$2"
  python3 - "$f" "$needle" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
sys.exit(0 if sys.argv[2].encode() in data else 1)
PY
}

has_bridge_surface() {
  local f="$1"
  [ -f "$f" ] || return 1
  _wasm_contains "$f" "BridgeMint" || _wasm_contains "$f" "bridge_mint_note" || _wasm_contains "$f" "SetBridgeCfg"
}

has_egress_surface() {
  local f="$1"
  [ -f "$f" ] || return 1
  _wasm_contains "$f" "BridgeEgress" || _wasm_contains "$f" "bridge_egress" \
    || _wasm_contains "$f" "IsEgressSpent" || _wasm_contains "$f" "egress_nf"
}

has_settle_surface() {
  local f="$1"
  [ -f "$f" ] || return 1
  _wasm_contains "$f" "SettleSwap" || _wasm_contains "$f" "settle_swap" || _wasm_contains "$f" "CreatePool"
}

has_cw_exports() {
  local f="$1"
  [ -f "$f" ] || return 1
  _wasm_contains "$f" "interface_version" || return 1
  _wasm_contains "$f" "allocate" || return 1
  _wasm_contains "$f" "instantiate" || return 1
  return 0
}

wasm_ok_headstash() {
  local f="$1"
  has_cw_exports "$f" && has_bridge_surface "$f"
}

wasm_ok_dex() {
  local f="$1"
  has_cw_exports "$f" && has_settle_surface "$f"
}

opt_wasm() {
  local raw="$1"
  local out="$2"
  local name="$3"
  PLATFORM="${DOCKER_PLATFORM:-$(arch_default)}"
  IMAGE="$(image_default)"

  if command -v wasm-opt >/dev/null 2>&1; then
    log "wasm-opt (host $(wasm-opt --version 2>/dev/null | head -1)) -Os + bulk-memory lowering ($name)"
    if wasm-opt -Os --enable-bulk-memory --llvm-memory-copy-fill-lowering --signext-lowering \
        "$raw" -o "$out" 2>/dev/null; then
      :
    elif wasm-opt -Os --enable-bulk-memory --llvm-memory-copy-fill-lowering \
        "$raw" -o "$out" 2>/dev/null; then
      :
    else
      fail "host wasm-opt failed for $name (install binaryen ≥120: brew install binaryen)"
    fi
  else
    log "WARN: no host wasm-opt — using $IMAGE for $name (may leave bulk-memory; install binaryen)"
    docker run --rm --entrypoint wasm-opt \
      --platform "$PLATFORM" \
      -v "$(dirname "$raw")":/in:ro \
      -v "$(dirname "$out")":/out \
      "$IMAGE" \
      -Os --disable-bulk-memory \
      "/in/$(basename "$raw")" -o "/out/$(basename "$out")" \
      || fail "wasm-opt failed in optimizer image for $name"
  fi

  # Exit 0 when clean (no memory.copy/fill). Fail-closed if any remain.
  if ! python3 - "$out" <<'PY'
import sys
d=open(sys.argv[1],"rb").read()
n=sum(1 for i in range(len(d)-1) if d[i]==0xfc and d[i+1] in (0x0a,0x0b))
sys.exit(0 if n == 0 else 1)
PY
  then
    fail "wasm still contains bulk-memory ops after wasm-opt ($name) — need binaryen ≥120 lowering"
  fi
  [ -f "$out" ] || fail "wasm-opt did not write $out"
}

# ── Headstash ───────────────────────────────────────────────────────────────
prepare_headstash() {
  if [ "${SKIP_OPTIMIZER:-0}" = "1" ]; then
    for cand in "$DEST2" "$DEST"; do
      if [ -f "$cand" ] && wasm_ok_headstash "$cand"; then
        install_dest "$cand" "$DEST" "$DEST2"
        return 0
      fi
    done
    fail "SKIP_OPTIMIZER=1 but no valid bridge wasm"
  fi

  if [ "${FORCE_WASM_REBUILD:-0}" != "1" ] && wasm_ok_headstash "$DEST2"; then
    log "wasm ok (bridge + exports): $DEST2 ($(wc -c <"$DEST2" | tr -d ' ') bytes)"
    cp -f "$DEST2" "$DEST" 2>/dev/null || true
    return 0
  fi

  if [ "${FORCE_WASM_REBUILD:-0}" != "1" ] && wasm_ok_headstash "$DEST"; then
    install_dest "$DEST" "$DEST" "$DEST2"
    return 0
  fi

  command -v cargo >/dev/null || fail "cargo required"
  command -v docker >/dev/null || fail "docker required for wasm-opt step"
  docker info >/dev/null 2>&1 || fail "dockerd not reachable"

  log "cargo build -p cw-headstash --target wasm32-unknown-unknown --release (guest graph)"
  (
    cd "$HS"
    cargo build -p cw-headstash --target wasm32-unknown-unknown --release
  )

  RAW="$HS/target/wasm32-unknown-unknown/release/cw_headstash.wasm"
  [ -f "$RAW" ] || fail "missing raw wasm after cargo build: $RAW"
  has_cw_exports "$RAW" || fail "raw wasm missing CosmWasm exports"
  has_bridge_surface "$RAW" || fail "raw wasm missing BridgeMint surface"

  opt_wasm "$RAW" "$DEST" "cw_headstash"
  install_dest "$DEST" "$DEST" "$DEST2"
  wasm_ok_headstash "$DEST2" || fail "optimized wasm failed bridge/export checks"
  log "OK optimized cw_headstash.wasm"
}

# ── Private dex (G3) ────────────────────────────────────────────────────────
prepare_private_dex() {
  if [ "${SKIP_OPTIMIZER:-0}" = "1" ]; then
    for cand in "$DEX_DEST2" "$DEX_DEST"; do
      if [ -f "$cand" ] && wasm_ok_dex "$cand"; then
        install_dest "$cand" "$DEX_DEST" "$DEX_DEST2"
        return 0
      fi
    done
    fail "SKIP_OPTIMIZER=1 but no valid private-dex wasm"
  fi

  if [ "${FORCE_WASM_REBUILD:-0}" != "1" ] && wasm_ok_dex "$DEX_DEST2"; then
    log "wasm ok (settle + exports): $DEX_DEST2 ($(wc -c <"$DEX_DEST2" | tr -d ' ') bytes)"
    cp -f "$DEX_DEST2" "$DEX_DEST" 2>/dev/null || true
    return 0
  fi

  if [ "${FORCE_WASM_REBUILD:-0}" != "1" ] && wasm_ok_dex "$DEX_DEST"; then
    install_dest "$DEX_DEST" "$DEX_DEST" "$DEX_DEST2"
    return 0
  fi

  command -v cargo >/dev/null || fail "cargo required"
  command -v docker >/dev/null || fail "docker required for wasm-opt step"
  docker info >/dev/null 2>&1 || fail "dockerd not reachable"

  log "cargo build -p cw-private-dex --target wasm32-unknown-unknown --release (guest graph, no zk-api)"
  (
    cd "$HS"
    # Default features: no zk-api → stock wasmd compatible (mock_verify lab)
    cargo build -p cw-private-dex --target wasm32-unknown-unknown --release
  )

  RAW="$HS/target/wasm32-unknown-unknown/release/cw_private_dex.wasm"
  [ -f "$RAW" ] || fail "missing raw wasm after cargo build: $RAW"
  has_cw_exports "$RAW" || fail "raw private-dex wasm missing CosmWasm exports"
  has_settle_surface "$RAW" || fail "raw private-dex wasm missing SettleSwap surface"

  opt_wasm "$RAW" "$DEX_DEST" "cw_private_dex"
  install_dest "$DEX_DEST" "$DEX_DEST" "$DEX_DEST2"
  wasm_ok_dex "$DEX_DEST2" || fail "optimized private-dex wasm failed settle/export checks"
  log "OK optimized cw_private_dex.wasm"
}

prepare_headstash
if [ "$PREPARE_DEX" = "1" ]; then
  prepare_private_dex
  log "OK dual wasm ready (cw_headstash + cw_private_dex) for settle profile"
else
  log "OK cw_headstash.wasm ready (set CORRIDOR_PREPARE_PRIVATE_DEX=1 or CORRIDOR_CHAIN_SETTLE=1 for dex)"
fi

# Option D / settle gates: fail closed before Daemon if surfaces missing (P0).
if [ "${CORRIDOR_CHAIN_SETTLE:-0}" = "1" ] || [ "${CORRIDOR_ZEC_EGRESS_D:-0}" = "1" ] \
  || [ "${CORRIDOR_ZEC_EGRESS_D:-}" = "true" ]; then
  has_settle_surface "$DEX_DEST" || has_settle_surface "$DEX_DEST2" \
    || fail "SettleSwap surface missing in cw_private_dex.wasm — set CORRIDOR_PREPARE_PRIVATE_DEX=1 / FORCE_WASM_REBUILD=1"
  log "gate: SettleSwap surface OK"
fi
if [ "${CORRIDOR_ZEC_EGRESS_D:-0}" = "1" ] || [ "${CORRIDOR_ZEC_EGRESS_D:-}" = "true" ] \
  || [ "${CORRIDOR_REQUIRE_EGRESS_WASM:-0}" = "1" ]; then
  if has_egress_surface "$DEST" || has_egress_surface "$DEST2"; then
    log "gate: BridgeEgress surface OK (Option D)"
  else
    fail "BridgeEgress surface missing in cw_headstash.wasm before Daemon — FORCE_WASM_REBUILD=1 prepare-corridor-ict-wasm"
  fi
fi
exit 0
