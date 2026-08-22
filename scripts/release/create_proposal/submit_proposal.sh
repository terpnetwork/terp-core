#!/usr/bin/env bash
# Fill PROPOSAL_TEMPLATE.json for an expedited SoftwareUpgrade (v6 by default).
# Does not broadcast unless --broadcast is passed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

UPGRADE_NAME="${UPGRADE_NAME:-v6}"
UPGRADE_TAG="${UPGRADE_TAG:-v6.0.0}"
UPGRADE_HEIGHT="${UPGRADE_HEIGHT:-}"
DEPOSIT="${DEPOSIT:-5000000000}"
AUTHORITY="${AUTHORITY:-terp10d07y265gmmuvt4z0w9aw880jnsr700jag6fuq}"
CHAIN_ID="${CHAIN_ID:-morocco-1}"
FROM="${FROM:-}"
BROADCAST=0
OUT="${OUT:-$ROOT/build/upgrade-proposal-${UPGRADE_NAME}.json}"

usage() {
  cat <<H
Usage: $0 --height N [--tag v6.0.0] [--name v6] [--deposit N] [--broadcast] [--from KEY]
Generates an expedited MsgSoftwareUpgrade JSON (Cosmos SDK v0.50+).
If --broadcast, submits with terpd (requires --from and a running node).
H
}

while [ $# -gt 0 ]; do
  case "$1" in
    --height) UPGRADE_HEIGHT="$2"; shift 2 ;;
    --tag) UPGRADE_TAG="$2"; shift 2 ;;
    --name) UPGRADE_NAME="$2"; shift 2 ;;
    --deposit) DEPOSIT="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --broadcast) BROADCAST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg $1"; usage; exit 1 ;;
  esac
done

if [ -z "$UPGRADE_HEIGHT" ]; then
  echo "error: --height is required"
  usage
  exit 1
fi

UPGRADE_INFO="${UPGRADE_INFO:-https://github.com/terpnetwork/terp-core/releases/download/${UPGRADE_TAG}/terpd}"
if [ -f "$ROOT/build/binaries.json" ]; then
  UPGRADE_INFO=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))' < "$ROOT/build/binaries.json")
fi

TITLE="${TITLE:-Software Upgrade ${UPGRADE_NAME} (${UPGRADE_TAG})}"
SUMMARY="${SUMMARY:-Expedited upgrade to ${UPGRADE_TAG}. Plan name ${UPGRADE_NAME}. Pre-place Cosmovisor binary at cosmovisor/upgrades/${UPGRADE_NAME}/bin/terpd.}"

export UPGRADE_NAME UPGRADE_HEIGHT UPGRADE_INFO DEPOSIT AUTHORITY TITLE SUMMARY OUT SCRIPT_DIR
python3 - <<'PY'
import json, os
from pathlib import Path
raw = (Path(os.environ["SCRIPT_DIR"]) / "PROPOSAL_TEMPLATE.json").read_text()
for k in ("UPGRADE_NAME", "UPGRADE_HEIGHT", "UPGRADE_INFO", "DEPOSIT", "AUTHORITY", "TITLE", "SUMMARY"):
    raw = raw.replace("${" + k + "}", os.environ[k])
obj = json.loads(raw)
info = os.environ["UPGRADE_INFO"]
if info.startswith("{"):
    obj["messages"][0]["plan"]["info"] = info
out = Path(os.environ["OUT"])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(obj, indent=2) + "\n")
print("wrote", out)
PY

if [ "$BROADCAST" = "1" ]; then
  [ -n "$FROM" ] || { echo "--broadcast requires --from"; exit 1; }
  terpd tx gov submit-proposal "$OUT" --from "$FROM" --chain-id "$CHAIN_ID" --gas auto --gas-adjustment 1.5 -y
else
  echo "Not broadcasting. Review $OUT then:"
  echo "  terpd tx gov submit-proposal $OUT --from <key> --chain-id $CHAIN_ID --gas auto --gas-adjustment 1.5 -y"
fi
