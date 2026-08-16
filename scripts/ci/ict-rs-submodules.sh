#!/usr/bin/env bash
# Fetch ict-rs and its path-deps by URL.
# terp-core gitignores crates/* and does not store gitlinks, so
# `git submodule update` on a fresh clone has nothing to init.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ensure() {
  local path="$1" url="$2" branch="$3"
  if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
    echo "ict-rs-deps: present $path"
    return 0
  fi
  echo "ict-rs-deps: clone --depth 1 --branch $branch $url -> $path"
  mkdir -p "$(dirname "$path")"
  rm -rf "$path"
  git clone --depth 1 --branch "$branch" "$url" "$path"
}

ensure crates/ict-rs          https://github.com/permissionlessweb/ict-rs.git          main
ensure crates/cosmos-rust     https://github.com/permissionlessweb/cosmos-rust.git     main
ensure crates/tendermint-rs   https://github.com/permissionlessweb/tendermint-rs.git   main
ensure crates/cw-orchestrator https://github.com/permissionlessweb/cw-orchestrator.git cw3
ensure crates/terp-rs         https://github.com/permissionlessweb/terp-rs.git         feat/zk-wasmvm
ensure crates/ibc-proto-rs    https://github.com/permissionlessweb/ibc-proto-rs.git    main
