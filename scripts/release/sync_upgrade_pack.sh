#!/usr/bin/env bash
# Single writer for a Cosmovisor upgrade pack.
#
#   PLAN=v6.1 ./scripts/release/sync_upgrade_pack.sh
#     ARTIFACT_LOCK is source of truth. Rewrites binaries.json, cosmovisor.json,
#     draft/dual proposal plan.info, and SOURCE_DEPS from gitlinks at binary_commit.
#
#   WRITE=1 PLAN=v6.1 TAG=v6.1.0 ./scripts/release/sync_upgrade_pack.sh
#     Local linux tarballs (and ELFs if present) are source of truth. Rewrites
#     ARTIFACT_LOCK too. Does not upload, tag, or broadcast.
#
# Cosmovisor linux-only. Darwin leftovers in build/ are ignored.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=upgrade_pack_lib.sh
source "$ROOT/scripts/release/upgrade_pack_lib.sh"

require_cmd python3
require_cmd jq

PLAN="${PLAN:-}"
if [ -z "$PLAN" ]; then
  echo "ERROR: set PLAN=v6.1 or PLAN=v6.2" >&2
  exit 1
fi
WRITE="${WRITE:-0}"
PACK="$(pack_dir)"
LOCK="$(lock_path)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
mkdir -p "$PACK"

TAG="${TAG:-${RELEASE_TAG:-}}"
if [ -z "$TAG" ] && [ -f "$LOCK" ]; then
  TAG="$(lock_field "$LOCK" binary_tag)"
fi
require_exact_tag "$TAG"
VER="${TAG#v}"
S3_BASE="${S3_BASE:-https://s3.terp.network/releases/terp-core/${TAG}}"

COMMIT="${BINARY_COMMIT:-}"
if [ -z "$COMMIT" ] && [ -f "$LOCK" ]; then
  COMMIT="$(lock_field "$LOCK" binary_commit)"
fi
if [ -z "$COMMIT" ]; then
  if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    COMMIT="$(git rev-parse "${TAG}^{commit}")"
  else
    echo "ERROR: no binary_commit and tag $TAG is missing. Run make release-control or set BINARY_COMMIT." >&2
    exit 1
  fi
fi
COMMIT="$(git rev-parse "$COMMIT")"

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  tagged="$(git rev-parse "${TAG}^{commit}")"
  if [ "$tagged" != "$COMMIT" ]; then
    echo "ERROR: tag $TAG is $tagged, lock/BINARY_COMMIT is $COMMIT (will not move the tag)" >&2
    exit 1
  fi
fi

sums_tmp="$(mktemp)"
trap 'rm -f "$sums_tmp"' EXIT

write_linux_sums_from_build() {
  local arch tar name sum
  : > "$sums_tmp"
  for arch in amd64 arm64; do
    name="terpd-${VER}-linux-${arch}.tar.gz"
    tar="$BUILD_DIR/$name"
    if [ ! -f "$tar" ]; then
      echo "ERROR: WRITE=1 missing $tar" >&2
      exit 1
    fi
    members="$(tar tzf "$tar")"
    if ! printf '%s\n' "$members" | grep -qx 'terpd' && ! printf '%s\n' "$members" | grep -qx './terpd'; then
      echo "ERROR: $tar has no root member terpd" >&2
      exit 1
    fi
    sum="$(sha256_file "$tar")"
    echo "$sum  $name" >> "$sums_tmp"
  done
}

write_linux_sums_from_lock() {
  local arch name sum
  : > "$sums_tmp"
  if ! has_checksum_lock "$LOCK"; then
    echo "ERROR: $LOCK has no terpd-<tag>-linux-*.tar.gz checksum lines" >&2
    exit 1
  fi
  for arch in amd64 arm64; do
    name="terpd-${VER}-linux-${arch}.tar.gz"
    sum="$(lock_sum_for "$LOCK" "$name")"
    if [ -z "$sum" ]; then
      echo "ERROR: $LOCK missing $name" >&2
      exit 1
    fi
    echo "$sum  $name" >> "$sums_tmp"
  done
}

if [ "$WRITE" = "1" ]; then
  write_linux_sums_from_build
  EPOCH="$(git log -1 --format=%ct "$COMMIT")"
  PUBLISHED="${PUBLISHED:-false}"
  {
    echo "plan: $PLAN"
    echo "binary_tag: $TAG"
    echo "binary_commit: $COMMIT"
    echo "pack_branch: release/$TAG"
    # Exact tag on BINARY_COMMIT only. Never --dirty from the pack worktree.
    _desc="$(git describe --tags --exact-match "$COMMIT" 2>/dev/null || true)"
    if [ "$_desc" != "$TAG" ]; then
      echo "ERROR: $COMMIT is not exact tag $TAG (git describe='${_desc:-<none>}'). Refuse dirty lock." >&2
      exit 1
    fi
    echo "dirty: $TAG"
    echo "s3_binaries_intended: $S3_BASE/"
    echo "published: $PUBLISHED"
    echo "source_date_epoch: $EPOCH"
    echo "note: ELF identity is git tag $TAG. Pack files belong on release/$TAG and must not move the tag. Tarballs are pack_cv_tarball.py (SOURCE_DATE_EPOCH=tag %ct); ELF sha256 is the consensus identity."
    echo
    cat "$sums_tmp"
    for arch in amd64 arm64; do
      elf="$BUILD_DIR/terpd-linux-$arch"
      if [ -f "$elf" ]; then
        echo "$(sha256_file "$elf")  terpd-linux-$arch"
      fi
    done
    echo
    echo "wasmvm_muslc_base: ${WASMVM_MUSLC_BASE:-https://minio.terp.network/releases/zk-wasmvm/v3.0.7-zk/}"
    echo "${WASMVM_MUSLC_AARCH64_SHA:-0687e59140c967a752b0b0ede98e71a3c859fb4f6b94fc26883792d381eb4716}  libwasmvm_muslc.aarch64.a"
    echo "${WASMVM_MUSLC_X86_SHA:-4f4880e1655d34c098729df52db22c9253bec87d2b3185669ff015a340b76d49}  libwasmvm_muslc.x86_64.a"
  } > "$LOCK"
  echo "sync: wrote $LOCK (WRITE=1 from $BUILD_DIR)"
else
  if [ ! -f "$LOCK" ]; then
    echo "ERROR: missing $LOCK (WRITE=1 to create from tarballs)" >&2
    exit 1
  fi
  lock_plan="$(lock_field "$LOCK" plan)"
  lock_tag="$(lock_field "$LOCK" binary_tag)"
  lock_commit="$(lock_field "$LOCK" binary_commit)"
  if [ "$lock_plan" != "$PLAN" ]; then
    echo "ERROR: lock plan='$lock_plan' != PLAN='$PLAN'" >&2
    exit 1
  fi
  if [ "$lock_tag" != "$TAG" ]; then
    echo "ERROR: lock binary_tag='$lock_tag' != TAG='$TAG'" >&2
    exit 1
  fi
  if [ "$lock_commit" != "$COMMIT" ]; then
    echo "ERROR: lock binary_commit='$lock_commit' != $COMMIT" >&2
    exit 1
  fi
  write_linux_sums_from_lock
  echo "sync: ARTIFACT_LOCK is source of truth PLAN=$PLAN TAG=$TAG COMMIT=$COMMIT"
fi

cvj="$PACK/cosmovisor.json"
write_binaries_json "$TAG" "$sums_tmp" "$cvj" "$S3_BASE"
cp "$cvj" "$PACK/binaries.json"
echo "sync: wrote $cvj"
echo "sync: wrote $PACK/binaries.json (byte-identical to cosmovisor.json)"

compact="$(compact_json_file "$cvj")"
# Proposals in this pack. Sibling dual_proposal.json only when PACK is the
# in-repo plan dir (do not rewrite the repo from a temp PACK= in tests).
find_proposals() {
  {
    local f
    for f in "$PACK/draft_proposal.json" "$PACK/dual_proposal.json"; do
      [ -f "$f" ] || continue
      echo "$f"
    done
    if [ "$PACK" = "$ROOT/networks/upgrades/$PLAN" ]; then
      for f in "$ROOT/networks/upgrades/"*/dual_proposal.json; do
        [ -f "$f" ] || continue
        echo "$f"
      done
    fi
  } | sort -u
}

while IFS= read -r prop; do
  [ -n "$prop" ] || continue
  if jq -e --arg name "$PLAN" '.messages[] | select(.plan.name == $name)' "$prop" >/dev/null; then
    set_plan_info "$prop" "$PLAN" "$compact"
    echo "sync: $prop plan.info ($PLAN) = compact cosmovisor.json"
  fi
done < <(find_proposals)

write_source_deps "$PACK" "$COMMIT" "$TAG" "$PLAN"
echo "sync: wrote $PACK/SOURCE_DEPS.txt from gitlinks at $COMMIT"

PLAN="$PLAN" TAG="$TAG" PACK="$PACK" bash "$ROOT/scripts/release/verify_upgrade_pack.sh"
echo "sync: OK PLAN=$PLAN TAG=$TAG COMMIT=$COMMIT"
