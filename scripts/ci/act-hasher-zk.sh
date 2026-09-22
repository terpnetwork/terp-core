#!/usr/bin/env bash
# Run hasher-zk.yml via act on a *copy* of the tree with cargo/go build
# caches stripped, so host target/ and dylibs cannot mask CI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v act >/dev/null || { echo "ERROR: install act (nektos/act)"; exit 2; }
command -v docker >/dev/null || { echo "ERROR: docker required for act"; exit 2; }

FRESH="${ACT_FRESH:-/tmp/terp-act-hasher-zk}"
ARCH="${ACT_ARCH:-linux/amd64}"
IMAGE="${ACT_IMAGE:-catthehacker/ubuntu:act-latest}"

if [ "${ACT_SKIP_RSYNC:-0}" = "1" ] && [ -f "$FRESH/.github/workflows/hasher-zk.yml" ]; then
  echo "==> reuse $FRESH"
else
echo "==> fresh tree $FRESH (Go + hasher + CosmWasm path deps; no cargo target)"
rm -rf "$FRESH"
mkdir -p "$FRESH/crates"
# Do not copy crates/terp-rs (120G) or other unrelated crates.
rsync -a \
  --exclude '/crates/' \
  --exclude '/build/' \
  --exclude '/websites/' \
  --exclude '/optimizer/' \
  --exclude '/.grok/' \
  --exclude '/_review/' \
  --exclude '**/target/' \
  --exclude '**/*.dylib' \
  --exclude '**/node_modules/' \
  "$ROOT/" "$FRESH/"
for c in zk-wasmd zk-wasmvm cosmwasm cosmos zakura-common flock zcash ibc-hooks-v11 ics23; do
  if [ -d "$ROOT/crates/$c" ]; then
    rsync -a --exclude '**/target/' --exclude '**/*.dylib' --exclude '**/*.rlib' \
      "$ROOT/crates/$c" "$FRESH/crates/"
  fi
done
fi

cd "$FRESH"
chmod +x scripts/ci/fetch-zk-path-deps.sh scripts/release/curate_v63.sh
echo "==> act hasher-zk ($ARCH $IMAGE)"
# No --bind: act copies into the container. Host GOPATH/CARGO_HOME are not used.
exec act workflow_dispatch \
  -W .github/workflows/hasher-zk.yml \
  -P "ubuntu-latest=$IMAGE" \
  --container-architecture "$ARCH" \
  --action-offline-mode=false \
  --reuse=false \
  --use-gitignore=false \
  "$@"
