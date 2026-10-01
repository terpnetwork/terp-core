#!/usr/bin/env bash
# Fail-fast watcher for hasher_wasm_smoke. Prints only DONE/FAILED.
#   watch_hasher_smoke.sh <log> <pid>
set -euo pipefail
LOG="${1:?log}"
PID="${2:?pid}"

fail_line() {
  grep -E 'HASHER_FAIL|wasm contract call failed|thread .+ panicked' "$LOG" 2>/dev/null | tail -1 | tr '\n' ' '
}

while :; do
  if grep -q 'HASHER_FAIL' "$LOG" 2>/dev/null; then
    echo "FAILED: $(fail_line)"
    exit 1
  fi
  if grep -E -q 'wasm contract call failed|thread .+ panicked' "$LOG" 2>/dev/null; then
    echo "FAILED: $(fail_line)"
    exit 1
  fi
  if grep -q 'HASHER_PHASE done' "$LOG" 2>/dev/null; then
    echo "DONE"
    exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    if grep -q 'HASHER_PHASE done' "$LOG" 2>/dev/null; then
      echo "DONE"
      exit 0
    fi
    echo "FAILED: pid $PID exited without HASHER_PHASE done: $(tail -c 400 "$LOG" | tr '\n' ' ')"
    exit 1
  fi
  sleep 2
done
