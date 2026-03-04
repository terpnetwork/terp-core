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
BUILD_DIR="build"
CHECKSUM_FILE="$BUILD_DIR/sha256sum.txt"

echo "Preparing release artifacts for version: $VERSION"
echo ""

# ------------------------------------------------------------------
# Verify binaries
# ------------------------------------------------------------------
for arch in amd64 arm64; do
    if [[ ! -f "$BUILD_DIR/terpd-linux-$arch" ]]; then
        echo "Error: $BUILD_DIR/terpd-linux-$arch not found."
        echo "Run 'make create-binaries' first."
        exit 1
    fi
done

# ------------------------------------------------------------------
# Checksum raw binaries
# ------------------------------------------------------------------
echo "Checksumming raw binaries..."
(cd "$BUILD_DIR" && sha256sum terpd-linux-amd64 terpd-linux-arm64 > sha256sum.txt)

# ------------------------------------------------------------------
# Create versioned tarballs and append their checksums
# ------------------------------------------------------------------
for arch in amd64 arm64; do
    tarball="terpd-$VERSION-linux-$arch.tar.gz"
    echo "Creating $BUILD_DIR/$tarball..."
    tar -czf "$BUILD_DIR/$tarball" -C "$BUILD_DIR" "terpd-linux-$arch"

    echo "Checksumming $tarball..."
    (cd "$BUILD_DIR" && sha256sum "$tarball" >> sha256sum.txt)
done

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "Artifacts in $BUILD_DIR/:"
ls -lh "$BUILD_DIR"/*.tar.gz "$BUILD_DIR"/terpd-linux-* 2>/dev/null
echo ""
echo "Checksums written to $CHECKSUM_FILE:"
cat "$CHECKSUM_FILE"
