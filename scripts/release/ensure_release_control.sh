#!/usr/bin/env bash
# Split ELF identity (immutable git tag vX.Y.Z) from Cosmovisor pack
# (branch release/vX.Y.Z, which may add guides after the tag).
#
# Same pattern as v6.0.0: tag v6.0.0 = binary_commit; pack_branch release/v6.0.0
# may be ahead. Never retag. Never stamp vX.Y.Z-dev or git-describe into terpd.
#
#   RELEASE_TAG=v6.1.0 ./scripts/release/ensure_release_control.sh
#   RELEASE_TAG=v6.1.0 BINARY_COMMIT=<sha> ./scripts/release/ensure_release_control.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TAG="${RELEASE_TAG:-}"
if ! echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: RELEASE_TAG must be vX.Y.Z (got '${TAG:-<empty>}'). No -dev, -rc, or commit describe." >&2
  exit 1
fi

COMMIT="$(git rev-parse "${BINARY_COMMIT:-HEAD}")"
BRANCH="release/${TAG}"

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  existing="$(git rev-parse "${TAG}^{commit}")"
  if [ "$existing" != "$COMMIT" ]; then
    echo "ERROR: tag $TAG already points at $existing, not $COMMIT (will not move the tag)" >&2
    exit 1
  fi
  echo "ok tag $TAG = $COMMIT"
else
  git tag -a "$TAG" "$COMMIT" -m "terp-core $TAG"
  echo "created tag $TAG = $COMMIT"
fi

if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  tip="$(git rev-parse "$BRANCH")"
  if ! git merge-base --is-ancestor "$COMMIT" "$BRANCH"; then
    echo "ERROR: $BRANCH ($tip) does not contain ELF commit $COMMIT" >&2
    exit 1
  fi
  echo "ok $BRANCH contains $COMMIT (tip $tip; pack files may be ahead of the tag)"
else
  git branch "$BRANCH" "$COMMIT"
  echo "created $BRANCH at $COMMIT"
fi

echo
echo "ELF identity:  git checkout $TAG   # $COMMIT"
echo "pack branch:   git checkout $BRANCH"
echo "build:         RELEASE_TAG=$TAG WASMVM_SOURCE=local make create-binaries"
echo "Do not commit Cosmovisor checksums onto $TAG; commit them on $BRANCH only."
