#!/usr/bin/env bash
# One-button stable local multi-net e2e (P1 LAB-ZEC).
#
# Flow:
#   1. prepare wasm (headstash + private-dex settle surfaces)
#   2. Zakura up best-effort (soft residual labeled — does not fail the button)
#   3. just demo-corridor-ict-egress-d equivalent (observe → mint → settle → Option D)
#   4. Print receipt paths; fail-closed if dest mismatch / missing burn / incomplete zec
#
# Soft-skip only Zakura *start*. Burn evidence + dual receipts still mandatory.
# Option D only: no product host-pay without Terp burn.
#
# Usage:
#   bash demo-corridor-full-local.sh
#   just demo-corridor-full-local   # from crates/headstash
#
# Env: same as corridor-ict-funded.sh + ZAKURAD_BIN / ZAKURA_RPC for Zakura.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HEADSTASH="$REPO_ROOT/crates/headstash"
ZAKURA_SCRIPT="$SCRIPT_DIR/zakura/zakura-local.sh"

export CORRIDOR_SETTLE_RECEIPT_PATH="${CORRIDOR_SETTLE_RECEIPT_PATH:-/tmp/corridor-settle-receipt.json}"
export CORRIDOR_EGRESS_BURN_EVIDENCE_PATH="${CORRIDOR_EGRESS_BURN_EVIDENCE_PATH:-/tmp/corridor-egress-burn-evidence.json}"
export CORRIDOR_ZEC_EGRESS_RECEIPT_PATH="${CORRIDOR_ZEC_EGRESS_RECEIPT_PATH:-/tmp/corridor-zec-egress-receipt.json}"
export CORRIDOR_MINT_EVIDENCE_PATH="${CORRIDOR_MINT_EVIDENCE_PATH:-/tmp/corridor-mint-evidence.json}"

fail() { echo "FAIL demo-corridor-full-local: $*" >&2; exit 1; }
log() { echo "== full-local: $* =="; }

log "prepare wasm (settle + Option D surfaces)"
chmod +x "$SCRIPT_DIR/prepare-corridor-ict-wasm.sh"
CORRIDOR_PREPARE_PRIVATE_DEX=1 bash "$SCRIPT_DIR/prepare-corridor-ict-wasm.sh" \
  || fail "prepare-corridor-ict-wasm failed"

log "Zakura up (best effort — soft residual if bin/docker missing)"
chmod +x "$ZAKURA_SCRIPT" 2>/dev/null || true
ZAKURA_STATE="down"
if bash "$ZAKURA_SCRIPT" status 2>/dev/null; then
  ZAKURA_STATE="already_up"
  log "Zakura RPC already ready"
else
  if bash "$ZAKURA_SCRIPT" up 2>/dev/null; then
    ZAKURA_STATE="started"
    log "Zakura started"
    bash "$ZAKURA_SCRIPT" rpc-smoke 2>/dev/null || true
  else
    ZAKURA_STATE="soft_skip_no_bin_or_docker"
    echo "  WARN: Zakura not started (need ZAKURAD_BIN + docker) — lab pay may be lab_inventory_pay_simulated"
  fi
fi
echo "  zakura_state=$ZAKURA_STATE"

log "run Option D corridor (observe → mint → settle → burn → lab ZEC pay)"
chmod +x "$SCRIPT_DIR/corridor-ict-funded.sh"
export CORRIDOR_CHAIN_SETTLE=1
export CORRIDOR_ZEC_EGRESS_D=1
bash "$SCRIPT_DIR/corridor-ict-funded.sh" || fail "corridor-ict-funded (egress-d) failed"

log "assert dual receipts + dest continuity + burn mandatory"
[ -f "$CORRIDOR_EGRESS_BURN_EVIDENCE_PATH" ] \
  || fail "missing burn evidence at $CORRIDOR_EGRESS_BURN_EVIDENCE_PATH"
[ -f "$CORRIDOR_ZEC_EGRESS_RECEIPT_PATH" ] \
  || fail "missing zec receipt at $CORRIDOR_ZEC_EGRESS_RECEIPT_PATH"
[ -f "$CORRIDOR_SETTLE_RECEIPT_PATH" ] \
  || fail "missing settle receipt at $CORRIDOR_SETTLE_RECEIPT_PATH"

python3 - "$CORRIDOR_EGRESS_BURN_EVIDENCE_PATH" "$CORRIDOR_ZEC_EGRESS_RECEIPT_PATH" \
  "$CORRIDOR_SETTLE_RECEIPT_PATH" <<'PY' || fail "full-local dual receipt / dest assert failed"
import json, sys

ev = json.load(open(sys.argv[1]))
zr = json.load(open(sys.argv[2]))
sr = json.load(open(sys.argv[3]))

assert ev.get("status") == "complete", f"burn status={ev.get('status')}"
assert ev.get("egress_nf_label") == "egress-nf-v0", ev
assert ev.get("proof_mode") == "mock_verify_lab", ev
assert ev.get("burn_surface") in ("pure_record_lab", "cw_bridge_egress_burn"), ev
burn = ev.get("burn") or {}
assert burn.get("nullifier_hex"), "burn nullifier missing"
assert burn.get("dest_commitment_hex"), "burn dest_commitment missing"
assert int(burn.get("value") or 0) > 0, "burn value must be > 0"

assert zr.get("status") == "complete", f"zec status={zr.get('status')}"
assert zr.get("burn_nullifier_hex") == burn["nullifier_hex"], (
    "dest/nullifier continuity: zec.burn_nullifier != burn.nullifier",
    zr.get("burn_nullifier_hex"),
    burn.get("nullifier_hex"),
)
assert zr.get("dest_owner_binding_hex") == burn["dest_commitment_hex"], (
    "DEST MISMATCH: zec.dest_owner_binding != burn.dest_commitment",
    zr.get("dest_owner_binding_hex"),
    burn.get("dest_commitment_hex"),
)
assert zr.get("amount_zat") == burn["value"], (zr.get("amount_zat"), burn.get("value"))
assert zr.get("mode") in (
    "lab_inventory_pay_simulated",
    "lab_inventory_pay",
    "lc_mint",
), zr.get("mode")
assert zr.get("zec_txid"), "zec_txid missing"
# Simulated must stay labeled; live must not use simulated prefix.
txid = zr.get("zec_txid") or ""
mode = zr.get("mode")
if mode == "lab_inventory_pay_simulated":
    assert str(txid).startswith("lab_inventory_pay_simulated"), txid
elif mode == "lab_inventory_pay":
    assert not str(txid).startswith("lab_inventory_pay_simulated"), txid

assert sr.get("status") == "complete", f"settle status={sr.get('status')}"

print(
    f"  OK burn_surface={ev.get('burn_surface')} mode={mode} "
    f"amount_zat={zr.get('amount_zat')} dest={zr.get('dest_owner_binding_hex')[:16]}…"
)
PY

echo ""
echo "========================================"
echo "  OK demo-corridor-full-local"
echo "  zakura_state=$ZAKURA_STATE"
echo "  settle=$CORRIDOR_SETTLE_RECEIPT_PATH"
echo "  burn=$CORRIDOR_EGRESS_BURN_EVIDENCE_PATH"
echo "  zec=$CORRIDOR_ZEC_EGRESS_RECEIPT_PATH"
echo "  mint=${CORRIDOR_MINT_EVIDENCE_PATH}"
echo "  honesty: Option D burn mandatory; simulated ZEC pay labeled if no wallet RPC"
echo "========================================"
