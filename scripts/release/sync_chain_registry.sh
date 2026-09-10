#!/usr/bin/env bash
# Copy terp-core chain-registry SoT into a cosmos/chain-registry checkout.
#
# GitHub cannot follow a symlink from cosmos/chain-registry into terp-core.
# Tune files only under networks/chain-registry/terpnetwork/, then run this
# before opening a chain-registry PR (materialized JSON, not a symlink).
#
#   ./scripts/release/sync_chain_registry.sh
#   DEST=/path/to/chain-registry ./scripts/release/sync_chain_registry.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/networks/chain-registry/terpnetwork"
DEST="${DEST:-$ROOT/crates/chain-registry}"
if [ ! -f "$SRC/chain.json" ] || [ ! -f "$SRC/versions.json" ]; then
  echo "ERROR: missing SoT at $SRC" >&2
  exit 1
fi
if [ ! -d "$DEST/terpnetwork" ]; then
  echo "ERROR: $DEST/terpnetwork not found (clone cosmos/chain-registry or the permissionlessweb fork)" >&2
  exit 1
fi
python3 - "$SRC" "$DEST/terpnetwork" <<'PY'
import json, sys
from pathlib import Path
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
for name in ("chain.json", "versions.json"):
    data = json.loads((src / name).read_text())
    def drop_null(o):
        if isinstance(o, dict):
            return {k: drop_null(v) for k, v in o.items() if v is not None}
        if isinstance(o, list):
            return [drop_null(x) for x in o]
        return o
    out = dest / name
    out.write_text(json.dumps(drop_null(data), indent=2) + "\n")
    print(f"copied {name} -> {out}")
PY
echo "SoT: $SRC"
echo "Dest: $DEST/terpnetwork"
echo "Open a PR from that clone onto cosmos/chain-registry. Do not commit a symlink."
