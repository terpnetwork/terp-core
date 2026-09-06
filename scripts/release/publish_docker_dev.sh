#!/usr/bin/env bash
# Build (or retag) the testnet ZK alpine image and apply version-aligned tags.
#
# Tags applied:
#   <IMAGE_REPO>:<RELEASE_TAG>   (default registry.terp.network/terp-core)
#
# Usage:
#   RELEASE_TAG=v6.1.0-dev ./scripts/release/publish_docker_dev.sh
#   make docker-publish-dev RELEASE_TAG=v6.1.0-dev
#
# Env:
#   RELEASE_TAG     (default: v5.3.0-dev)
#   IMAGE_REPO      (default: registry.terp.network/terp-core)
#   WASMVM_SOURCE   (default: local) — must be local for ZK monorepo build
#   SKIP_BUILD      (default: 0) — if 1, retag existing IMAGE_REPO:RELEASE_TAG
#   DOCKER_PLATFORM optional e.g. linux/amd64
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

RELEASE_TAG="${RELEASE_TAG:-v5.3.0-dev}"
IMAGE_REPO="${IMAGE_REPO:-registry.terp.network/terp-core}"
WASMVM_SOURCE="${WASMVM_SOURCE:-local}"
SKIP_BUILD="${SKIP_BUILD:-0}"
TAGGED="${IMAGE_REPO}:${RELEASE_TAG}"

GIT_COMMIT="$(git rev-parse HEAD)"
GIT_TREE="$(git rev-parse HEAD^{tree})"
DIRTY=0
if ! git diff-index --quiet HEAD -- 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  DIRTY=1
fi

echo "=== docker-publish-dev ==="
echo "  RELEASE_TAG    = $RELEASE_TAG"
echo "  IMAGE_REPO     = $IMAGE_REPO"
echo "  WASMVM_SOURCE  = $WASMVM_SOURCE"
echo "  GIT_COMMIT     = $GIT_COMMIT"
echo "  GIT_TREE       = $GIT_TREE"
echo "  DIRTY          = $DIRTY"
echo "  SKIP_BUILD     = $SKIP_BUILD"
echo ""

if [ "$WASMVM_SOURCE" != "local" ]; then
  echo "ERROR: testnet ZK images require WASMVM_SOURCE=local (got: $WASMVM_SOURCE)" >&2
  exit 1
fi

if [ ! -d "./crates/zk-wasmvm" ]; then
  echo "ERROR: crates/zk-wasmvm not found — monorepo ZK build requires it" >&2
  exit 1
fi

if [ "$SKIP_BUILD" = "1" ]; then
  if ! docker image inspect "$TAGGED" >/dev/null 2>&1; then
    echo "ERROR: SKIP_BUILD=1 but image $TAGGED not found. Build first." >&2
    exit 1
  fi
  echo "==> SKIP_BUILD=1 — reusing existing $TAGGED"
else
  echo "==> Building ZK alpine image via make build-zk-local TERP_IMAGE_VERSION=$RELEASE_TAG"
  # shellcheck disable=SC2086
  make build-zk-local WASMVM_SOURCE=local TERP_IMAGE_VERSION="$RELEASE_TAG" IMAGE_REPO="$IMAGE_REPO" \
    ${DOCKER_PLATFORM:+DOCKER_DEFAULT_PLATFORM=$DOCKER_PLATFORM}
fi

echo ""
echo "Images:"
for ref in "$TAGGED"; do
  id="$(docker image inspect "$ref" --format '{{.Id}}' 2>/dev/null || echo missing)"
  created="$(docker image inspect "$ref" --format '{{.Created}}' 2>/dev/null || true)"
  echo "  $ref"
  echo "    id=$id"
  echo "    created=$created"
done

# OCI-ish labels as a local record (docker build already embeds GIT_*; this is audit trail)
LABEL_DIR="build/release/${RELEASE_TAG}"
mkdir -p "$LABEL_DIR"
{
  echo "release_tag=${RELEASE_TAG}"
  echo "git_commit=${GIT_COMMIT}"
  echo "git_tree=${GIT_TREE}"
  echo "dirty=${DIRTY}"
  echo "wasmvm_source=${WASMVM_SOURCE}"
  echo "image=${TAGGED}"
  echo "image_id=$(docker image inspect "$LOCAL_ZK" --format '{{.Id}}')"
  echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$LABEL_DIR/docker-build.env"

echo ""
echo "Wrote $LABEL_DIR/docker-build.env"
echo ""
echo "Next:"
echo "  make docker-push-dev RELEASE_TAG=${RELEASE_TAG}"
echo "  make release-bundle RELEASE_TAG=${RELEASE_TAG}"
echo "  make release-s3 RELEASE_TAG=${RELEASE_TAG} NETWORK=testnet CHAIN_ID=120u-1"
