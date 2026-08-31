#!/usr/bin/env bash
####################################################################
# IAVL v2 exercise (off CommitMultiStore).
#
# Live terpd still commits IAVL v1. This proves the v2 ingest path:
#   - same KV, SHA-256 vs BLAKE3 roots differ (unsound if equal)
#   - deterministic BLAKE3
# When VAL1HOME/data exists (TSH snapshot / statesync), print that
# application.db is still v1 and must not be treated as v2 sqlite.
#
# Sourced from v61.sh or:
#   CGO_ENABLED=1 sh tests/tsh/upgrade/iavl-v2.sh
####################################################################
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"

echo "iavl-v2: hash-soundness tests (ingest SHA-256 ≠ BLAKE3)"
(
  cd "$REPO"
  CGO_ENABLED=1 go test -count=1 -timeout 120s ./app/iavlv2/
)

if [ -n "${VAL1HOME:-}" ] && [ -d "$VAL1HOME/data" ]; then
  echo "iavl-v2: snapshot/statesync home $VAL1HOME"
  if [ -d "$VAL1HOME/data/application.db" ] || ls "$VAL1HOME/data"/application.* >/dev/null 2>&1; then
    echo "iavl-v2: application.db present — CMS is IAVL v1. sqlite ingest is experimental (app/iavlv2). Do not treat this as a CMS cutover."
  fi
fi
echo "iavl-v2: ok"
