#!/usr/bin/env bash
# Rebuild Cosmovisor linux ELFs from ARTIFACT_LOCK's tag on a clean worktree.
# PLAN=v6.1 ./scripts/release/recurate_upgrade_binaries.sh
# Does not upload, tag, or broadcast.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PLAN="${PLAN:-}"
if [ -z "$PLAN" ]; then
  echo "ERROR: set PLAN=v6.3 or PLAN=v6.4" >&2
  exit 1
fi
LOCK="$ROOT/networks/upgrades/${PLAN}/ARTIFACT_LOCK"
if [ ! -f "$LOCK" ]; then
  echo "ERROR: missing $LOCK (checkout pack branch release/vX.Y.Z)" >&2
  exit 1
fi
COMMIT="$(awk -F': ' '/^binary_commit:/{print $2; exit}' "$LOCK")"
TAG="$(awk -F': ' '/^binary_tag:/{print $2; exit}' "$LOCK")"
if [ -z "$COMMIT" ] || [ -z "$TAG" ]; then
  echo "ERROR: $LOCK missing binary_commit or binary_tag" >&2
  exit 1
fi
if ! echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: binary_tag $TAG is not vX.Y.Z" >&2
  exit 1
fi
if ! git cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
  echo "ERROR: $COMMIT not in this clone; git fetch origin tag $TAG" >&2
  exit 1
fi
tagged="$(git rev-parse "${TAG}^{commit}" 2>/dev/null || true)"
if [ "$tagged" != "$COMMIT" ]; then
  echo "ERROR: tag $TAG is ${tagged:-missing}, lock binary_commit is $COMMIT" >&2
  exit 1
fi
# v6.3.0 and v6.4.0 share one source SHA; git describe --exact-match picks one tag.
if ! git tag --points-at "$COMMIT" | grep -Fxq "$TAG"; then
  echo "ERROR: $COMMIT is not tagged $TAG (points-at: $(git tag --points-at "$COMMIT" | tr '\n' ' '))" >&2
  exit 1
fi

WT="${RECURATE_WORKDIR:-$ROOT/.worktrees/recurate-${PLAN}}"
mkdir -p "$(dirname "$WT")"
if [ -d "$WT" ]; then
  git -C "$WT" checkout -q --detach "$COMMIT"
  git -C "$WT" submodule update --init --checkout crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm
else
  git worktree add --detach "$WT" "$COMMIT"
  git -C "$WT" submodule update --init --checkout crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm
fi
if [ -n "$(git -C "$WT" status --porcelain --untracked-files=no)" ]; then
  echo "ERROR: recurate worktree $WT is dirty after checkout $COMMIT" >&2
  git -C "$WT" status --porcelain >&2
  exit 1
fi
desc="$(git -C "$WT" describe --tags --always --dirty)"
if echo "$desc" | grep -q dirty; then
  echo "ERROR: recurate worktree describes as $desc (must be exact $TAG)" >&2
  exit 1
fi

# Muslc: published STWO archives, checksum-verified. Never parent-tree copy.
bash "$ROOT/scripts/release/fetch_zk_muslc.sh" "$WT/crates/zk-wasmvm/internal/api"

HOOKS_SRC="$ROOT/crates/ibc-hooks-v11"
if [ ! -d "$HOOKS_SRC" ]; then
  echo "ERROR: missing $HOOKS_SRC" >&2
  exit 1
fi
mkdir -p "$WT/crates/ibc-hooks-v11"
rsync -a --delete --exclude='.git/' "$HOOKS_SRC/" "$WT/crates/ibc-hooks-v11/"

EPOCH="$(git log -1 --format=%ct "$COMMIT")"
# Stamp VERSION from the tag, not git describe (dual tags on one SHA).
# v6.4 keepers are -tags v64; docker always adds muslc.
REC_VERSION="${TAG#v}"
REC_BUILD_TAGS="muslc"
if [ "$PLAN" = "v6.4" ] || [ "$TAG" = "v6.4.0" ]; then
  REC_BUILD_TAGS="muslc v64"
fi
# Darwin create-binaries needs the static archive; Cosmovisor packs are linux.
if [ "$(uname -s)" = Darwin ] && [ -f "$ROOT/crates/zk-wasmvm/internal/api/libwasmvmstatic_darwin.a" ]; then
  mkdir -p "$WT/crates/zk-wasmvm/internal/api"
  cp -f "$ROOT/crates/zk-wasmvm/internal/api/libwasmvmstatic_darwin.a" \
    "$WT/crates/zk-wasmvm/internal/api/libwasmvmstatic_darwin.a"
fi
echo "==> recurate PLAN=$PLAN TAG=$TAG COMMIT=$COMMIT VERSION=$REC_VERSION BUILD_TAGS='$REC_BUILD_TAGS' EPOCH=$EPOCH worktree=$WT (clean $desc)"
( cd "$WT" && RELEASE_TAG="$TAG" VERSION="$REC_VERSION" BUILD_TAGS="$REC_BUILD_TAGS" WASMVM_SOURCE=local make create-binaries )
SOURCE_DATE_EPOCH="$EPOCH" BUILD_DIR="$WT/build" ALLOW_PARTIAL=0 PLAN="$PLAN" \
  TAG="$TAG" RELEASE_TAG="$TAG" bash "$ROOT/scripts/release/prep.sh" "${TAG#v}"

fail=0
while read -r want name; do
  [ -n "${want:-}" ] || continue
  case "$name" in
    terpd-linux-amd64|terpd-linux-arm64|terpd-*-linux-amd64.tar.gz|terpd-*-linux-arm64.tar.gz) ;;
    *) continue ;;
  esac
  got="$(shasum -a 256 "$WT/build/$name" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "MISMATCH $name lock=$want rebuilt=$got" >&2
    fail=1
  else
    echo "OK $name $got"
  fi
done < <(awk '/^[0-9a-f]{64}  /{print $1, $2}' "$LOCK")
if [ "$fail" != 0 ]; then
  echo "recurate FAILED — rebuilt ELF does not match communicated ARTIFACT_LOCK" >&2
  exit 1
fi
echo "recurate OK PLAN=$PLAN COMMIT=$COMMIT (no muslc hand-curation, no dirty tag)"
