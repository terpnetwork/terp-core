#!/usr/bin/env bash
set -euo pipefail

# Prepares all release artifacts from reproducible builds:
#   - verifies raw binaries exist
#   - checksums raw binaries
#   - creates versioned tarballs
#   - checksums tarballs
#   - writes everything into a single build/sha256sum.txt
#
# Run `make create-binaries` first.
#
# Usage: ./scripts/release/prep.sh [VERSION]
# VERSION defaults to the current git tag (v-prefix stripped).

VERSION="${1:-$(git describe --tags 2>/dev/null | sed 's/^v//' || echo "unknown")}"
BUILD_DIR="${BUILD_DIR:-build}"
CHECKSUM_FILE="$BUILD_DIR/sha256sum.txt"
ALLOW_PARTIAL="${ALLOW_PARTIAL:-0}"
PLAN="${PLAN:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Tag commit author date. Recurate must pass SOURCE_DATE_EPOCH from binary_commit, not pack HEAD.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  if echo "${TAG:-v$VERSION}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    SOURCE_DATE_EPOCH="$(git log -1 --format=%ct "${TAG}^{commit}" 2>/dev/null || true)"
  fi
  SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
fi
export SOURCE_DATE_EPOCH
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (deterministic Cosmovisor tar.gz)"

echo "Preparing release artifacts for version: $VERSION"
echo ""

# ------------------------------------------------------------------
# Verify binaries
# ------------------------------------------------------------------
present=()
for arch in amd64 arm64; do
    if [[ -f "$BUILD_DIR/terpd-linux-$arch" ]]; then
        present+=("$arch")
    else
        echo "WARN: $BUILD_DIR/terpd-linux-$arch not found."
    fi
done
if [[ ${#present[@]} -eq 0 ]]; then
    echo "Error: no linux ELFs in $BUILD_DIR/. Run 'make create-binaries' first."
    exit 1
fi
if [[ ${#present[@]} -lt 2 && "$ALLOW_PARTIAL" != "1" ]]; then
    echo "Error: both linux amd64 and arm64 are required (set ALLOW_PARTIAL=1 for a single-arch soak pack)."
    exit 1
fi

# ------------------------------------------------------------------
# Checksum raw binaries (only files that exist)
# ------------------------------------------------------------------
echo "Checksumming raw binaries..."
raw=()
for arch in "${present[@]}"; do
    raw+=("terpd-linux-$arch")
done
[[ -f "$BUILD_DIR/terpd-darwin-arm64" ]] && raw+=("terpd-darwin-arm64")
(cd "$BUILD_DIR" && sha256sum "${raw[@]}" > sha256sum.txt)

# ------------------------------------------------------------------
# Create versioned tarballs and append their checksums
# ------------------------------------------------------------------
# Cosmovisor auto-download requires ./terpd in the archive (DAEMON_NAME).
pack_cv_tarball() {
    local src="$1" dest="$2"
    python3 "$ROOT/scripts/release/pack_cv_tarball.py" "$src" "$dest" "$SOURCE_DATE_EPOCH"
}

for arch in "${present[@]}"; do
    tarball="terpd-$VERSION-linux-$arch.tar.gz"
    echo "Creating $BUILD_DIR/$tarball (member terpd)..."
    pack_cv_tarball "$BUILD_DIR/terpd-linux-$arch" "$BUILD_DIR/$tarball"
    members="$(tar tzf "$BUILD_DIR/$tarball")"
    if ! printf '%s\n' "$members" | grep -qx 'terpd' && ! printf '%s\n' "$members" | grep -qx './terpd'; then
        echo "Error: $tarball missing root member terpd" >&2
        exit 1
    fi

    echo "Checksumming $tarball..."
    (cd "$BUILD_DIR" && sha256sum "$tarball" >> sha256sum.txt)
done

if [[ -f "$BUILD_DIR/terpd-darwin-arm64" ]]; then
    echo "Creating $BUILD_DIR/terpd-$VERSION-darwin-arm64.tar.gz (member terpd)..."
    pack_cv_tarball "$BUILD_DIR/terpd-darwin-arm64" "$BUILD_DIR/terpd-$VERSION-darwin-arm64.tar.gz"
    cp "$BUILD_DIR/terpd-$VERSION-darwin-arm64.tar.gz" "$BUILD_DIR/terpd-darwin-arm64.tar.gz"
    (cd "$BUILD_DIR" && sha256sum "terpd-$VERSION-darwin-arm64.tar.gz" "terpd-darwin-arm64.tar.gz" >> sha256sum.txt)
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "Artifacts in $BUILD_DIR/:"
ls -lh "$BUILD_DIR"/*.tar.gz "$BUILD_DIR"/terpd-linux-* 2>/dev/null
echo ""
echo "Checksums written to $CHECKSUM_FILE:"
cat "$CHECKSUM_FILE"

if [[ -n "$PLAN" ]]; then
    echo ""
    echo "Writing Cosmovisor plan $PLAN from local tarballs..."
    PLAN="$PLAN" TAG="${TAG:-v$VERSION}" WRITE=1 ALLOW_PARTIAL="$ALLOW_PARTIAL" \
      bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preflight_upgrade.sh"
fi
