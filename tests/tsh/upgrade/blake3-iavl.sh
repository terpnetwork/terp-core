#!/usr/bin/env bash
# Compat wrapper: blake3-iavl plan was renamed to v6.1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export UPGRADE_VERSION="${UPGRADE_VERSION:-v6.1}"
# shellcheck disable=SC1091
source "$ROOT/v61.sh"
