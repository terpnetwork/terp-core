#!/usr/bin/env bash
# Clone CosmWasm path deps (zakura-common, flock) if missing.
# GitHub checkout of terp-core gitignores crates/* except a few; CosmWasm
# Cargo.toml points at ../../../zakura-common and ../../../flock.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

clone_if() {
  local dest="$1" url="$2" rev="${3:-}"
  if [ -d "$ROOT/$dest/crates" ] || [ -f "$ROOT/$dest/Cargo.toml" ]; then
    echo "OK $dest already present"
    return 0
  fi
  echo "==> clone $url -> $dest"
  git clone --filter=blob:none "$url" "$ROOT/$dest"
  if [ -n "$rev" ]; then
    git -C "$ROOT/$dest" fetch --depth 1 origin "$rev" || git -C "$ROOT/$dest" fetch origin "$rev"
    git -C "$ROOT/$dest" checkout "$rev"
  fi
}

clone_if crates/zakura-common https://github.com/permissionlessweb/common.git a64b90a804615cc88e5c4e39b6ade3afa68bc2b0
clone_if crates/flock https://github.com/succinctlabs/flock.git
echo "OK zk path deps"
