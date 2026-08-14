#!/usr/bin/env bash
# Create a deterministic release bundle under build/release/<tag>/:
#   source.tar.gz (+ .sha256)   — git archive of the commit tree
#   SOURCE_COMMIT               — commit + tree + dirty flag
#   docker-images.txt           — image refs + local ids / digests
#   manifest.json               — machine-readable verifiability record
#   sha256sum.txt               — optional binary/tarball checksums if present
#
# Determinism: git archive uses SOURCE_DATE_EPOCH from commit author date and
# fixed tar owner/mtime options when available. Same clean commit → same
# source.tar.gz sha256.
#
# Usage:
#   ./scripts/release/make_release_bundle.sh
#   RELEASE_TAG=v5.3.0-dev NETWORK=testnet CHAIN_ID=120u-1 ./scripts/release/make_release_bundle.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

RELEASE_TAG="${RELEASE_TAG:-v5.3.0-dev}"
IMAGE_REPO="${IMAGE_REPO:-containers.terp.network/terp-core}"
LOCAL_REPO="${LOCAL_REPO:-terpnetwork/terp-core}"
NETWORK="${NETWORK:-testnet}"
CHAIN_ID="${CHAIN_ID:-120u-1}"
LINEAGE="${LINEAGE:-}"
OUT_DIR="${OUT_DIR:-build/release/${RELEASE_TAG}}"

if [ -z "$LINEAGE" ]; then
  case "$NETWORK" in
    mainnet) LINEAGE="mainnet-stock" ;;
    testnet) LINEAGE="testnet-zk" ;;
    *) LINEAGE="unknown" ;;
  esac
fi

GIT_COMMIT="$(git rev-parse HEAD)"
GIT_TREE="$(git rev-parse HEAD^{tree})"
GIT_DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || echo "$GIT_COMMIT")"
DIRTY=false
if ! git diff-index --quiet HEAD -- 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  DIRTY=true
fi

# Commit author date as SOURCE_DATE_EPOCH (portable)
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct "$GIT_COMMIT")"
export SOURCE_DATE_EPOCH

mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"

echo "=== make_release_bundle ==="
echo "  RELEASE_TAG        = $RELEASE_TAG"
echo "  OUT_DIR            = $OUT_DIR_ABS"
echo "  GIT_COMMIT         = $GIT_COMMIT"
echo "  GIT_TREE           = $GIT_TREE"
echo "  DIRTY              = $DIRTY"
echo "  SOURCE_DATE_EPOCH  = $SOURCE_DATE_EPOCH"
echo "  NETWORK / CHAIN    = $NETWORK / $CHAIN_ID"
echo "  LINEAGE            = $LINEAGE"
echo ""

if [ "$DIRTY" = true ]; then
  echo "WARN: working tree is dirty — source.tar.gz is the clean commit tree only;"
  echo "      uncommitted changes are NOT in the archive. manifest.dirty=true"
  echo ""
fi

# ---------------------------------------------------------------------------
# Deterministic source archive from git tree (not working directory)
# ---------------------------------------------------------------------------
SOURCE_TAR="$OUT_DIR_ABS/source.tar.gz"
PREFIX="terp-core-${RELEASE_TAG}/"

echo "==> git archive → source.tar.gz"
# git archive produces stable content for a given tree; gzip -n for deterministic
# header (no mtime/name). Prefer pigz if present for speed; still -n.
if command -v pigz >/dev/null 2>&1; then
  git archive --format=tar --prefix="$PREFIX" "$GIT_COMMIT" | pigz -n -9 >"$SOURCE_TAR"
else
  git archive --format=tar --prefix="$PREFIX" "$GIT_COMMIT" | gzip -n -9 >"$SOURCE_TAR"
fi

SOURCE_SHA="$(shasum -a 256 "$SOURCE_TAR" | awk '{print $1}')"
echo "$SOURCE_SHA  source.tar.gz" >"$OUT_DIR_ABS/source.tar.gz.sha256"
echo "  sha256 = $SOURCE_SHA"

# ---------------------------------------------------------------------------
# SOURCE_COMMIT
# ---------------------------------------------------------------------------
{
  echo "commit=${GIT_COMMIT}"
  echo "tree=${GIT_TREE}"
  echo "describe=${GIT_DESCRIBE}"
  echo "dirty=${DIRTY}"
  echo "source_date_epoch=${SOURCE_DATE_EPOCH}"
  echo "release_tag=${RELEASE_TAG}"
  echo "lineage=${LINEAGE}"
  echo "network=${NETWORK}"
  echo "chain_id=${CHAIN_ID}"
} >"$OUT_DIR_ABS/SOURCE_COMMIT"

# ---------------------------------------------------------------------------
# Docker image inventory
# ---------------------------------------------------------------------------
DOCKER_TXT="$OUT_DIR_ABS/docker-images.txt"
: >"$DOCKER_TXT"
IMAGE_JSON_PARTS=()

record_image() {
  local ref="$1"
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    echo "  (missing) $ref" | tee -a "$DOCKER_TXT"
    return 0
  fi
  local id digests created
  id="$(docker image inspect "$ref" --format '{{.Id}}')"
  digests="$(docker image inspect "$ref" --format '{{json .RepoDigests}}')"
  created="$(docker image inspect "$ref" --format '{{.Created}}')"
  {
    echo "ref=${ref}"
    echo "  id=${id}"
    echo "  created=${created}"
    echo "  repo_digests=${digests}"
  } >>"$DOCKER_TXT"
  # shellcheck disable=SC2086
  IMAGE_JSON_PARTS+=("$(printf '{"ref":"%s","id":"%s","created":"%s","repo_digests":%s}' \
    "$ref" "$id" "$created" "$digests")")
}

echo "==> Recording docker images"
for ref in \
  "${LOCAL_REPO}:local-zk" \
  "${LOCAL_REPO}:${RELEASE_TAG}" \
  "${IMAGE_REPO}:${RELEASE_TAG}"; do
  record_image "$ref"
done

# ---------------------------------------------------------------------------
# Optional binary checksums from build/
# ---------------------------------------------------------------------------
if [ -f build/sha256sum.txt ]; then
  cp build/sha256sum.txt "$OUT_DIR_ABS/sha256sum.txt"
  echo "==> Copied build/sha256sum.txt"
fi

# ---------------------------------------------------------------------------
# manifest.json
# ---------------------------------------------------------------------------
IMAGES_JSON="[]"
if [ ${#IMAGE_JSON_PARTS[@]} -gt 0 ]; then
  IMAGES_JSON="[$(IFS=,; echo "${IMAGE_JSON_PARTS[*]}")]"
fi

# Prefer python for safe JSON; fall back to hand-rolled minimal JSON
MANIFEST="$OUT_DIR_ABS/manifest.json"
if command -v python3 >/dev/null 2>&1; then
  SOURCE_SHA="$SOURCE_SHA" GIT_COMMIT="$GIT_COMMIT" GIT_TREE="$GIT_TREE" \
  GIT_DESCRIBE="$GIT_DESCRIBE" DIRTY="$DIRTY" SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  RELEASE_TAG="$RELEASE_TAG" LINEAGE="$LINEAGE" NETWORK="$NETWORK" CHAIN_ID="$CHAIN_ID" \
  IMAGE_REPO="$IMAGE_REPO" IMAGES_JSON="$IMAGES_JSON" MANIFEST="$MANIFEST" \
  python3 - <<'PY'
import json, os
from datetime import datetime, timezone

images = json.loads(os.environ["IMAGES_JSON"])
manifest = {
    "schema_version": 1,
    "release_tag": os.environ["RELEASE_TAG"],
    "lineage": os.environ["LINEAGE"],
    "network": os.environ["NETWORK"],
    "chain_id": os.environ["CHAIN_ID"],
    "git_commit": os.environ["GIT_COMMIT"],
    "git_tree": os.environ["GIT_TREE"],
    "git_describe": os.environ["GIT_DESCRIBE"],
    "dirty": os.environ["DIRTY"].lower() == "true",
    "source_date_epoch": int(os.environ["SOURCE_DATE_EPOCH"]),
    "created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": {
        "file": "source.tar.gz",
        "sha256": os.environ["SOURCE_SHA"],
        "method": "git archive + gzip -n",
        "note": "Archive is the clean commit tree; uncommitted files are excluded.",
    },
    "image_repo": os.environ["IMAGE_REPO"],
    "images": images,
    "verify": {
        "source": "shasum -a 256 -c source.tar.gz.sha256",
        "rebuild_hint": "git checkout $git_commit && make docker-publish-dev RELEASE_TAG=$release_tag WASMVM_SOURCE=local",
    },
}
with open(os.environ["MANIFEST"], "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"Wrote {os.environ['MANIFEST']}")
PY
else
  cat >"$MANIFEST" <<EOF
{
  "schema_version": 1,
  "release_tag": "${RELEASE_TAG}",
  "lineage": "${LINEAGE}",
  "network": "${NETWORK}",
  "chain_id": "${CHAIN_ID}",
  "git_commit": "${GIT_COMMIT}",
  "git_tree": "${GIT_TREE}",
  "git_describe": "${GIT_DESCRIBE}",
  "dirty": ${DIRTY},
  "source_date_epoch": ${SOURCE_DATE_EPOCH},
  "source": {
    "file": "source.tar.gz",
    "sha256": "${SOURCE_SHA}",
    "method": "git archive + gzip -n"
  },
  "image_repo": "${IMAGE_REPO}",
  "images": ${IMAGES_JSON}
}
EOF
  echo "Wrote $MANIFEST (no python3 — minimal JSON)"
fi

echo ""
echo "Bundle contents:"
ls -lh "$OUT_DIR_ABS"
echo ""
echo "Done. Publish with:"
echo "  make release-s3 RELEASE_TAG=${RELEASE_TAG} NETWORK=${NETWORK} CHAIN_ID=${CHAIN_ID}"
echo "  make release-s3 RELEASE_TAG=${RELEASE_TAG} DRY_RUN=1   # print only"
