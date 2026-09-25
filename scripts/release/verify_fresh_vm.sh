#!/usr/bin/env bash
# Wrapper — standard path is scripts/release/fresh-vm/run.sh
# Version extras: scripts/release/fresh-vm/releases/<tag>.sh
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fresh-vm/run.sh" "$@"
