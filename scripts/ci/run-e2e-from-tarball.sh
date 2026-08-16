#!/usr/bin/env bash
# Local stand-in for the E2E "download bins + exec suite" job.
# Does not talk to GitHub. Uses a tarball from ict-rs/scripts/ci/pack-bins.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARBALL="${1:-}"
SUITE="${2:-}"
if [ -z "$TARBALL" ] || [ -z "$SUITE" ]; then
  echo "usage: $0 <ict-ci-*.tar.gz> <ibc_transfer|polytone>" >&2
  exit 2
fi
test -f "$TARBALL"
STAGE="$(mktemp -d)"
trap "rm -rf $STAGE" EXIT
tar -C "$STAGE" -xzf "$TARBALL"
chmod +x "$STAGE/ict-ci" "$STAGE/examples/"*
test -x "$STAGE/examples/ibc_transfer"
test -x "$STAGE/examples/polytone"
export TERP_CORE="$ROOT"
export TERP_IMAGE_REPO="${TERP_IMAGE_REPO:-terpnetwork/terp-core}"
export TERP_IMAGE_VERSION="${TERP_IMAGE_VERSION:-local}"
export ICT_CI_BIN_DIR="$STAGE/examples"
if [ "$SUITE" = polytone ]; then
  test -f "$ROOT/tests/interchaintest/contracts/polytone_note.wasm"
  test -f "$ROOT/tests/interchaintest/contracts/polytone_voice.wasm"
  test -f "$ROOT/tests/interchaintest/contracts/polytone_proxy.wasm"
  test -f "$ROOT/tests/interchaintest/contracts/polytone_tester.wasm"
fi
docker image inspect "${TERP_IMAGE_REPO}:${TERP_IMAGE_VERSION}" >/dev/null
"$STAGE/ict-ci" run "$SUITE"
