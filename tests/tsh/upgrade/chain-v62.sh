#!/usr/bin/env bash
# After v6.1 is applied on this home, halt the v6.1 binary on plan v6.2 and
# start V62_BIND (feat/6.2.0-dev worktree). feat/6.1.0-dev must not register
# v6.2 — StoreUpgrades.Added already ran in this binary.
#
#   V62_BIND=terpd-v62  # install from .worktrees/terp-core-v6.2
#   CHAIN_V62=1         # default 1 when V62_BIND is on PATH
#
# Requires: VAL1HOME, VAL1ADDR, VAL1_RPC_PORT, NEW_BIND, NEW_PID, CHAINID
# from a.sh / v61.sh. Do not use pruned 22807932 or archive 22749033.
set -euo pipefail

V62_BIND="${V62_BIND:-terpd-v62}"
CHAIN_V62="${CHAIN_V62:-}"
V62_LOG="${V62_LOG:-/tmp/tsh-v62.log}"
V62_PLAN="${V62_PLAN:-v6.2}"

if [ -z "$CHAIN_V62" ]; then
  if command -v "$V62_BIND" >/dev/null; then
    CHAIN_V62=1
  else
    CHAIN_V62=0
  fi
fi
if [ "$CHAIN_V62" != "1" ]; then
  echo "v6.2: skip (CHAIN_V62=$CHAIN_V62 V62_BIND=$V62_BIND not on PATH)"
  echo "      install feat/6.2.0-dev as $V62_BIND from .worktrees/terp-core-v6.2"
  return 0 2>/dev/null || exit 0
fi
command -v "$V62_BIND" >/dev/null || { echo "V62_BIND=$V62_BIND not on PATH"; exit 1; }
command -v "$NEW_BIND" >/dev/null || { echo "NEW_BIND=$NEW_BIND missing"; exit 1; }
: "${VAL1HOME:?}" "${VAL1ADDR:?}" "${VAL1_RPC_PORT:?}" "${CHAINID:?}" "${NEW_PID:?}"

echo "v6.2: chaining on same home with $V62_BIND (plan $V62_PLAN)"
if [ "${USE_COSMOVISOR:-0}" = "1" ]; then
  echo "v6.2: Cosmovisor auto-swap — wait for applied $V62_PLAN (do not retrigger in-place-testnet)"
  applied=""
  for i in $(seq 1 180); do
    applied=$("$V62_BIND" q upgrade applied "$V62_PLAN" \
      --home "$VAL1HOME" --node "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
      -o json 2>/dev/null | jq -r '.height // empty' || true)
    h=$(rpc_height || echo 0)
    echo "  post-v6.2 h=$h applied=${applied:-none} try=$i"
    if [ -n "${applied:-}" ] && [ "$applied" != "0" ]; then
      break
    fi
    if ! kill -0 "$NEW_PID" 2>/dev/null; then
      echo "v6.2: Cosmovisor pid=$NEW_PID died"
      tail -80 "$NEW_LOG"
      exit 1
    fi
    sleep 2
  done
  if [ -z "${applied:-}" ] || [ "$applied" = "0" ]; then
    echo "v6.2: $V62_PLAN not applied (Cosmovisor did not swap)"
    tail -80 "$NEW_LOG"
    exit 1
  fi
  echo "v6.2 TSH ok (applied=$V62_PLAN at $applied) current=$(readlink "$VAL1HOME/cosmovisor/current" 2>/dev/null || echo no-cv)"
  export NEW_BIND="$V62_BIND"
  return 0 2>/dev/null || exit 0
fi
echo "v6.2: stopping v6.1 pid=$NEW_PID to reschedule via in-place-testnet"
kill "$NEW_PID" 2>/dev/null || true
wait "$NEW_PID" 2>/dev/null || true
sleep 2
rm -f "$VAL1HOME/data/upgrade-info.json"

# v6.1 binary has no v6.2 handler → panics at last+10 (InitTerpAppForTestnet).
: > "$OLD_LOG"
"$NEW_BIND" in-place-testnet "$CHAINID" "$VAL1ADDR" \
  --trigger-testnet-upgrade "$V62_PLAN" \
  --home "$VAL1HOME" --skip-confirmation \
  --rpc.laddr "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
  ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$OLD_LOG" 2>&1 &
V61_PID=$!

ok=0
for i in $(seq 1 180); do
  if grep -q "UPGRADE \"${V62_PLAN}\" NEEDED" "$OLD_LOG" 2>/dev/null; then
    echo "v6.2: halt signal from v6.1 binary"
    ok=1
    kill "$V61_PID" 2>/dev/null || true
    wait "$V61_PID" 2>/dev/null || true
    break
  fi
  if ! kill -0 "$V61_PID" 2>/dev/null; then
    echo "v6.2: v6.1 binary exited"
    break
  fi
  echo "  pre-v6.2 h=$(rpc_height || echo ?) try=$i"
  sleep 2
done
wait "$V61_PID" 2>/dev/null || true
sleep 2

if [ ! -f "$VAL1HOME/data/upgrade-info.json" ]; then
  echo "v6.2: missing upgrade-info.json"
  tail -40 "$OLD_LOG"
  exit 1
fi
if [ "$ok" != "1" ] && ! grep -q "UPGRADE \"${V62_PLAN}\" NEEDED" "$OLD_LOG"; then
  echo "v6.2: v6.1 binary did not halt on $V62_PLAN (is v6.2 registered on feat/6.1.0-dev? it must not be)"
  tail -40 "$OLD_LOG"
  exit 1
fi
echo "v6.2: upgrade-info.json=$(cat "$VAL1HOME/data/upgrade-info.json")"

: > "$V62_LOG"
"$V62_BIND" start --home "$VAL1HOME" \
  --rpc.laddr "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
  ${WASMVM_SKIP:+--wasm.skip_wasmvm_version_check} >>"$V62_LOG" 2>&1 &
NEW_PID=$!
export NEW_PID
wait_rpc

applied=""
for i in $(seq 1 120); do
  applied=$("$V62_BIND" q upgrade applied "$V62_PLAN" \
    --home "$VAL1HOME" --node "tcp://127.0.0.1:${VAL1_RPC_PORT}" \
    -o json 2>/dev/null | jq -r '.height // empty' || true)
  h=$(rpc_height || echo 0)
  echo "  post-v6.2 h=$h applied=${applied:-none} try=$i"
  if [ -n "${applied:-}" ] && [ "$applied" != "0" ]; then
    break
  fi
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "v6.2: $V62_BIND died"
    tail -50 "$V62_LOG"
    exit 1
  fi
  sleep 2
done
if [ -z "${applied:-}" ] || [ "$applied" = "0" ]; then
  echo "v6.2: $V62_PLAN not applied"
  tail -50 "$V62_LOG"
  exit 1
fi
if grep -q "refusing to rehash IBC-facing store" "$V62_LOG"; then
  echo "v6.2 handler refused an IBC store — fail closed"
  exit 1
fi
echo "v6.2 TSH ok (applied=$V62_PLAN at $applied) current=$(readlink "$VAL1HOME/cosmovisor/current" 2>/dev/null || echo no-cv)"
export NEW_BIND="$V62_BIND"
export NEW_LOG="$V62_LOG"
