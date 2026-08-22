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
import json, sys
suites = [ln.strip() for ln in sys.stdin if ln.strip()]
if not suites:
    sys.stderr.write("ERROR: ict-ci list produced no suites\n")
    sys.exit(1)
print(json.dumps(suites))
'
