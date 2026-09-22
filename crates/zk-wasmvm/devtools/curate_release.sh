#!/bin/bash
set -euo pipefail

# create artifacts folder for release
ARTIFACTS_DIR="artifacts"
rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

echo "=== Creating source archives ==="
# Zip source code (excluding .git, artifacts, etc.)
git archive --format=zip HEAD -o "$ARTIFACTS_DIR/wasmvm-source.zip"

# Tar source code
git archive --format=tar.gz --prefix=wasmvm/ HEAD -o "$ARTIFACTS_DIR/wasmvm-source.tar.gz"

echo "=== Copying compiled libraries ==="
# Copy the libraries (they should be in internal/api after running the release builds)
cp internal/api/libwasmvm.aarch64.so          "$ARTIFACTS_DIR/" 2>/dev/null || echo "Warning: libwasmvm.aarch64.so not found"
cp internal/api/libwasmvm.dylib               "$ARTIFACTS_DIR/" 2>/dev/null || echo "Warning: libwasmvm.dylib not found"
cp internal/api/libwasmvm.x86_64.so           "$ARTIFACTS_DIR/" 2>/dev/null || echo "Warning: libwasmvm.x86_64.so not found"
cp internal/api/libwasmvm_muslc.aarch64.a     "$ARTIFACTS_DIR/" 2>/dev/null || echo "Warning: libwasmvm_muslc.aarch64.a not found"
cp internal/api/libwasmvm_muslc.x86_64.a      "$ARTIFACTS_DIR/" 2>/dev/null || echo "Warning: libwasmvm_muslc.x86_64.a not found"
if [ -f internal/api/libwasmvmstatic_darwin.a ]; then
  cp internal/api/libwasmvmstatic_darwin.a "$ARTIFACTS_DIR/"
else
  echo "ERROR: libwasmvmstatic_darwin.a missing (run make release-build-macos-static-arm64)" >&2
  exit 1
fi

echo "=== Generating checksums ==="
cd "$ARTIFACTS_DIR"
sha256sum * > checksums.txt 2>/dev/null || echo "Warning: No files to checksum"
cat checksums.txt
cd - > /dev/null

echo "=== Done! Artifacts ready in ./${ARTIFACTS_DIR}/ ==="
ls -lh "$ARTIFACTS_DIR"