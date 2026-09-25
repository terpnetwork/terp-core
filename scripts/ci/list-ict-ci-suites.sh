#!/usr/bin/env bash
# Print ict-ci suite names as a JSON array for GHA matrix / act.
# Requires unpacked bins from fetch-ict-rs-bins.sh.
set -euo pipefail
BINS="${1:-/tmp/ict-bins}"
export ICT_CI_BIN_DIR="${ICT_CI_BIN_DIR:-$BINS/examples}"
if [ ! -x "$BINS/ict-ci" ]; then
  echo "ERROR: missing $BINS/ict-ci" >&2
  exit 1
fi
"$BINS/ict-ci" list | python3 -c '
import json, os, sys
suites = [ln.strip() for ln in sys.stdin if ln.strip()]
allow = [x.strip() for x in os.environ.get("ICT_CI_ALLOWLIST", "aa,pfm,ibchooks,hashmerchant,staking-hooks").split(",") if x.strip()]
deny = [x.strip() for x in os.environ.get("ICT_CI_DENYLIST", "marketplace,bridge,lean,pir,private-dex,private-bridge").split(",") if x.strip()]
picked = [s for s in suites if s in allow and not any(d in s for d in deny)]
if not picked:
    sys.stderr.write("ERROR: no suites after allowlist %s (have %s)\n" % (allow, suites))
    sys.exit(1)
print(json.dumps(picked))
'
