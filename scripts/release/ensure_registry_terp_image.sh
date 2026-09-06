#!/usr/bin/env bash
# Ensure IMAGE_REPO:TERP_IMAGE_VERSION is on this machine, from registry.terp.network.
# Build + push (groot2 :5050) only when missing. Never uses a tag named local / local-zk.
#
# Usage:
#   TERP_IMAGE_VERSION=<tag> ./scripts/release/ensure_registry_terp_image.sh
#   TERP_IMAGE_VERSION=v5.2.0 BUILD=0 ./scripts/release/ensure_registry_terp_image.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

IMAGE_REPO="${IMAGE_REPO:-registry.terp.network/terp-core}"
TAG="${1:-${TAG:-${TERP_IMAGE_VERSION:-}}}"
BUILD="${BUILD:-1}"
PUSH="${PUSH:-0}"
GROOT2_HOST="${GROOT2_HOST:-groot2}"

if [ -z "$TAG" ]; then
  echo "ERROR: set TERP_IMAGE_VERSION (or pass the tag as argv). local / local-zk are retired." >&2
  exit 1
fi
if [ "$TAG" = "local" ] || [ "$TAG" = "local-zk" ]; then
  echo "ERROR: tag $TAG is retired. Set TERP_IMAGE_VERSION to a real tag." >&2
  exit 1
fi

REF="${IMAGE_REPO}:${TAG}"

have() { docker image inspect "$1" >/dev/null 2>&1; }

if have "$REF"; then
  echo "ok $REF"
elif docker pull "$REF"; then
  echo "pulled $REF"
elif [ "$BUILD" = 1 ]; then
  echo "==> not in registry; building $REF"
  make build-zk-local TERP_IMAGE_VERSION="$TAG" IMAGE_REPO="$IMAGE_REPO"
else
  echo "ERROR: missing $REF (not on disk, pull failed, BUILD=$BUILD)" >&2
  exit 1
fi

if [ "$PUSH" != 1 ]; then
  exit 0
fi

local_id="$(docker image inspect "$REF" --format '{{.Id}}')"
remote_digest="$(curl -fsSI -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  "https://registry.terp.network/v2/terp-core/manifests/${TAG}" 2>/dev/null \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2; exit}' || true)"

if [ -n "$remote_digest" ]; then
  # RepoDigests entries look like registry.terp.network/terp-core@sha256:...
  if docker image inspect "$REF" --format '{{json .RepoDigests}}' | grep -q "$remote_digest"; then
    echo "ok registry $REF $remote_digest"
    exit 0
  fi
  echo "registry $TAG digest $remote_digest differs from local $local_id — pushing"
else
  echo "registry missing $TAG — pushing $local_id"
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=12 "$GROOT2_HOST" 'test -f /opt/lab/registry/auth/password'; then
  echo "ERROR: cannot push; groot2 $GROOT2_HOST missing registry auth file" >&2
  exit 1
fi

docker save "$REF" | ssh -o BatchMode=yes "$GROOT2_HOST" "set -euo pipefail
  docker load
  docker tag ${REF} 127.0.0.1:5050/terp-core:${TAG}
  docker tag ${REF} registry.terp.network/terp-core:${TAG}
  cat /opt/lab/registry/auth/password | docker login 127.0.0.1:5050 -u oline --password-stdin >/dev/null
  cat /opt/lab/registry/auth/password | docker login registry.terp.network -u oline --password-stdin >/dev/null 2>&1 || true
  docker push 127.0.0.1:5050/terp-core:${TAG}
  docker push registry.terp.network/terp-core:${TAG}
"
echo "pushed 127.0.0.1:5050/terp-core:${TAG} and registry.terp.network/terp-core:${TAG}"
