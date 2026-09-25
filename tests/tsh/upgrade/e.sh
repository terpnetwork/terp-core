#!/usr/bin/env bash
# Cosmovisor auto-swap for the hasher two-step (plans v6.3 then v6.4).
# v6.0 Cosmovisor (plan v6) lives in archive/v6.0/e.sh.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/v63.sh" "$@"
