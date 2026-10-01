#!/usr/bin/env bash
# Current upgrade gate: Cosmovisor dual-halt v6.3 then v6.4.
# v6.0 morocco-1 → plan v6 lives in archive/v6.0/a.sh.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/v63.sh" "$@"
