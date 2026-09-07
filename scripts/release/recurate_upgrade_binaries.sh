#!/usr/bin/env bash
# Rebuild Cosmovisor linux ELFs from the commit pinned in ARTIFACT_LOCK and
# compare sha256 to that lock. Bit-for-bit check against communicated source.
#
#   PLAN=v6.1 ./scripts/release/recurate_upgrade_binaries.sh
#   PLAN=v6.2 ./scripts/release/recurate_upgrade_binaries.sh
#
# Does not upload, tag, or broadcast. Requires WASMVM_SOURCE=local STWO muslc
# in crates/zk-wasmvm/internal/api/libwasmvm_muslc.{aarch64,x86_64}.a.
# ibc-hooks-v11 is git-locked on the pack branch (tree + scripts/ci/ibc-hooks-v11.tar.gz).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PLAN="${PLAN:-}"
if [ -z "$PLAN" ]; then
  echo "ERROR: set PLAN=v6.1 or PLAN=v6.2" >&2
  exit 1
fi
LOCK="$ROOT/networks/upgrades/${PLAN}/ARTIFACT_LOCK"
if [ ! -f "$LOCK" ]; then
  echo "ERROR: missing $LOCK" >&2
  exit 1
fi
COMMIT="$(awk -F': ' '/^binary_commit:/{print $2; exit}' "$LOCK")"
TAG="$(awk -F': ' '/^binary_tag:/{print $2; exit}' "$LOCK")"
if [ -z "$COMMIT" ] || [ -z "$TAG" ]; then
  echo "ERROR: $LOCK missing binary_commit or binary_tag" >&2
  exit 1
fi
if ! git cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
  echo "ERROR: $COMMIT not in this clone; git fetch origin first" >&2
  exit 1
fi
MUSLC_SRC="${MUSLC_SRC:-$ROOT/crates/zk-wasmvm/internal/api}"
for arch in aarch64 x86_64; do
  f="$MUSLC_SRC/libwasmvm_muslc.${arch}.a"
  if [ ! -f "$f" ]; then
    echo "ERROR: missing $f (STWO muslc, not git)" >&2
    exit 1
  fi
  if ! grep -a -q -F 'stwo: Dummy DSTW rejected' "$f"; then
    echo "ERROR: $f has no Path A STWO host (proof_instance_verify)" >&2
    exit 1
  fi
done
WT="${RECURATE_WORKDIR:-$ROOT/.worktrees/recurate-${PLAN}}"
mkdir -p "$(dirname "$WT")"
if [ -d "$WT" ]; then
  git -C "$WT" checkout -q --detach "$COMMIT"
  git -C "$WT" submodule update --init crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm
else
  git worktree add --detach "$WT" "$COMMIT"
  git -C "$WT" submodule update --init crates/zk-wasmd crates/zk-wasmvm crates/cosmwasm
fi
HOOKS_SRC="$(bash "$ROOT/scripts/ci/resolve-ibc-hooks.sh")"
mkdir -p "$WT/crates/zk-wasmvm/internal/api" "$WT/crates/ibc-hooks-v11"
cp -f "$MUSLC_SRC"/libwasmvm_muslc.aarch64.a "$MUSLC_SRC"/libwasmvm_muslc.x86_64.a "$WT/crates/zk-wasmvm/internal/api/"
rsync -a --delete --exclude='.git/' "$HOOKS_SRC/" "$WT/crates/ibc-hooks-v11/"
if ! echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: binary_tag $TAG is not vX.Y.Z — recurate the tagged ELF, not a -dev describe" >&2
  exit 1
fi
EPOCH="$(git log -1 --format=%ct "$COMMIT")"
echo "==> recurate PLAN=$PLAN TAG=$TAG COMMIT=$COMMIT EPOCH=$EPOCH worktree=$WT"
( cd "$WT" && RELEASE_TAG="$TAG" WASMVM_SOURCE=local make create-binaries )
# Pack with this (pack-branch) prep.sh so tarballs are SOURCE_DATE_EPOCH-stable.
# Do not run the tagged worktree's tar -czf packer — that cannot reproduce.
SOURCE_DATE_EPOCH="$EPOCH" BUILD_DIR="$WT/build" ALLOW_PARTIAL=1 PLAN="$PLAN" \
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
echo "recurate OK PLAN=$PLAN COMMIT=$COMMIT"
